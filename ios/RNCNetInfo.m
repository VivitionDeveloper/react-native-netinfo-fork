/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "RNCNetInfo.h"
#import "RNCConnectionStateWatcher.h"

#include <ifaddrs.h>
#include <arpa/inet.h>

#if !TARGET_OS_TV && !TARGET_OS_MACCATALYST && !TARGET_OS_VISION
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <NetworkExtension/NetworkExtension.h>
#endif
@import SystemConfiguration.CaptiveNetwork;

#import <React/RCTAssert.h>
#import <React/RCTBridge.h>
#import <React/RCTEventDispatcher.h>

@interface RNCNetInfo () <RNCConnectionStateWatcherDelegate>

@property (nonatomic, strong) RNCConnectionStateWatcher *connectionStateWatcher;
@property (nonatomic) BOOL isObserving;
@property (nonatomic) NSDictionary *config;

@property (atomic, copy, nullable) NSString *cachedSSID;
@property (atomic, copy, nullable) NSString *cachedBSSID;
@property (atomic, assign) BOOL isFetchingWiFiIdentifiers;
@property (atomic, assign) NSTimeInterval lastWiFiIdentifiersFetchTime;

@end

@implementation RNCNetInfo

#pragma mark - Module setup

RCT_EXPORT_MODULE()

// We need RNCReachabilityCallback's and module methods to be called on the same thread so that we can have
// guarantees about when we mess with the reachability callbacks.
- (dispatch_queue_t)methodQueue
{
  return dispatch_get_main_queue();
}

+ (BOOL)requiresMainQueueSetup
{
  return YES;
}

#pragma mark - Lifecycle

- (NSArray *)supportedEvents
{
  return @[@"netInfo.networkStatusDidChange"];
}

- (void)startObserving
{
  self.isObserving = YES;
}

- (void)stopObserving
{
  self.isObserving = NO;
}

- (instancetype)init
{
  self = [super init];
  if (self) {
    _connectionStateWatcher = [[RNCConnectionStateWatcher alloc] initWithDelegate:self];
  }
  return self;
}

- (void)dealloc
{
  self.connectionStateWatcher = nil;
}

#pragma mark - RNCConnectionStateWatcherDelegate

- (void)connectionStateWatcher:(RNCConnectionStateWatcher *)connectionStateWatcher didUpdateState:(RNCConnectionState *)state
{
  if (self.isObserving) {
    NSDictionary *dictionary = [self currentDictionaryFromUpdateState:state withInterface:NULL];
    [self sendEventWithName:@"netInfo.networkStatusDidChange" body:dictionary];
  }
}

#pragma mark - Public API

RCT_EXPORT_METHOD(getCurrentState:(nullable NSString *)requestedInterface resolve:(RCTPromiseResolveBlock)resolve
                  reject:(__unused RCTPromiseRejectBlock)reject)
{
  RNCConnectionState *state = [self.connectionStateWatcher currentState];
  resolve([self currentDictionaryFromUpdateState:state withInterface:requestedInterface]);
}

RCT_EXPORT_METHOD(configure:(NSDictionary *)config)
{
    self.config = config;
}

#pragma mark - Utilities

#if !TARGET_OS_TV && !TARGET_OS_OSX && !TARGET_OS_MACCATALYST
- (void)refreshWiFiIdentifiersIfNeeded
{
  // Only iOS 14+ supports NEHotspotNetwork.fetchCurrent.
  if (@available(iOS 14.0, *)) {
    // Throttle to avoid spamming fetchCurrent. (e.g. once per 2 seconds)
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (self.isFetchingWiFiIdentifiers) {
      return;
    }
    if (self.lastWiFiIdentifiersFetchTime > 0 && (now - self.lastWiFiIdentifiersFetchTime) < 2.0) {
      return;
    }

    self.isFetchingWiFiIdentifiers = YES;
    self.lastWiFiIdentifiersFetchTime = now;

    [NEHotspotNetwork fetchCurrentWithCompletionHandler:^(NEHotspotNetwork * _Nullable currentNetwork) {
      NSString *newSSID = currentNetwork.SSID;
      NSString *newBSSID = currentNetwork.BSSID;

      // Filter out some generic labels (optional)
      if (newSSID != nil && ([newSSID isEqualToString:@"Wi-Fi"] || [newSSID isEqualToString:@"WLAN"])) {
        newSSID = nil;
      }

      BOOL changed = NO;
      BOOL ssidChanged =
        (self.cachedSSID == nil && newSSID != nil) ||
        (self.cachedSSID != nil && newSSID == nil) ||
        (self.cachedSSID != nil && newSSID != nil && ![self.cachedSSID isEqualToString:newSSID]);

      if (ssidChanged) {
        self.cachedSSID = newSSID;
        changed = YES;
      }

      BOOL bssidChanged =
        (self.cachedBSSID == nil && newBSSID != nil) ||
        (self.cachedBSSID != nil && newBSSID == nil) ||
        (self.cachedBSSID != nil && newBSSID != nil && ![self.cachedBSSID isEqualToString:newBSSID]);

      if (bssidChanged) {
        self.cachedBSSID = newBSSID;
        changed = YES;
      }

      self.isFetchingWiFiIdentifiers = NO;

      // If identifiers changed, emit an updated event to JS.
      // We do NOT block state building; we just push a refresh.
      if (changed) {
        dispatch_async(dispatch_get_main_queue(), ^{
          RNCConnectionState *state = self.connectionStateWatcher.currentState;
          if (state != nil) {
            [self connectionStateWatcher:self.connectionStateWatcher didUpdateState:state];
          }
        });
      }
    }];

    return;
  }

  // iOS < 14: do nothing (or keep old behavior if you care).
}
#endif

// Converts the state into a dictionary to send over the bridge
- (NSDictionary *)currentDictionaryFromUpdateState:(RNCConnectionState *)state withInterface:(nullable NSString *)requestedInterface
{
  NSString *selectedInterface = requestedInterface ?: state.type;
  NSMutableDictionary *details = [self detailsFromInterface:selectedInterface withState:state];
  bool connected = [state.type isEqualToString:selectedInterface] && state.connected;
  if (connected) {
    details[@"isConnectionExpensive"] = @(state.expensive);
  }

  return @{
    @"type": selectedInterface,
    @"isConnected": @(connected),
    @"details": details ?: NSNull.null
  };
}

- (NSMutableDictionary *)detailsFromInterface:(nonnull NSString *)requestedInterface withState:(RNCConnectionState *)state
{
  NSMutableDictionary *details = [NSMutableDictionary new];
  if ([requestedInterface isEqualToString: RNCConnectionTypeCellular]) {
    details[@"cellularGeneration"] = state.cellularGeneration ?: NSNull.null;
    details[@"carrier"] = [self carrier] ?: NSNull.null;
  } else if ([requestedInterface isEqualToString: RNCConnectionTypeWifi] || [requestedInterface isEqualToString: RNCConnectionTypeEthernet]) {
    details[@"ipAddress"] = [self ipAddress] ?: NSNull.null;
    details[@"subnet"] = [self subnet] ?: NSNull.null;
    #if !TARGET_OS_TV && !TARGET_OS_OSX && !TARGET_OS_MACCATALYST && !TARGET_OS_VISION
      BOOL shouldFetch = [requestedInterface isEqualToString:RNCConnectionTypeWifi] &&
                          self.config != nil &&
                          [self.config[@"shouldFetchWiFiSSID"] boolValue];
      /*
        Without one of the conditions needed to use CNCopyCurrentNetworkInfo, it will leak memory.
        Clients should only set the shouldFetchWiFiSSID to true after ensuring requirements are met to get (B)SSID.
      */
      if (shouldFetch) {
        // Only when state indicates WiFi and connected
        if (state != nil &&
            [state.type isEqualToString:RNCConnectionTypeWifi] &&
            state.connected) {
          [self refreshWiFiIdentifiersIfNeeded];
        } else {
          // Not on WiFi: clear cache so you don't keep old SSID
          self.cachedSSID = nil;
          self.cachedBSSID = nil;
        }
        details[@"ssid"] = [self cachedSSID] ?: NSNull.null;
        details[@"bssid"] = [self cachedBSSID] ?: NSNull.null;
      }
    #endif
  }
  return details;
}

- (NSString *)carrier
{
#if (TARGET_OS_TV || TARGET_OS_OSX || TARGET_OS_MACCATALYST || TARGET_OS_VISION)
  return nil;
#else
  CTTelephonyNetworkInfo *netinfo = [[CTTelephonyNetworkInfo alloc] init];
  CTCarrier *carrier = [netinfo subscriberCellularProvider];
  return carrier.carrierName;
#endif
}

- (NSString *)ipAddress
{
  NSString *address = @"0.0.0.0";
  struct ifaddrs *interfaces = NULL;
  struct ifaddrs *temp_addr = NULL;
  int success = 0;
  // retrieve the current interfaces - returns 0 on success
  success = getifaddrs(&interfaces);
  if (success == 0) {
    // Loop through linked list of interfaces
    temp_addr = interfaces;
    while (temp_addr != NULL) {
      if (temp_addr->ifa_addr->sa_family == AF_INET) {
        NSString* ifname = [NSString stringWithUTF8String:temp_addr->ifa_name];
        if (
          // Check if interface is en0 which is the wifi connection on the iPhone
          // and the ethernet connection on the Apple TV
          [ifname isEqualToString:@"en0"] ||
          // Check if interface is en1 which is the wifi connection on the Apple TV
          [ifname isEqualToString:@"en1"]
        ) {
          // Get NSString from C String
          char str[INET_ADDRSTRLEN];
          inet_ntop(AF_INET, &((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr, str, INET_ADDRSTRLEN);
          address = [NSString stringWithUTF8String:str];
        }
      }

      temp_addr = temp_addr->ifa_next;
    }
  }
  // Free memory
  freeifaddrs(interfaces);
  return address;
}

- (NSString *)subnet
{
  NSString *subnet = @"0.0.0.0";
  struct ifaddrs *interfaces = NULL;
  struct ifaddrs *temp_addr = NULL;
  int success = 0;
  // retrieve the current interfaces - returns 0 on success
  success = getifaddrs(&interfaces);
  if (success == 0) {
    // Loop through linked list of interfaces
    temp_addr = interfaces;
    while (temp_addr != NULL) {
      if (temp_addr->ifa_addr->sa_family == AF_INET) {
        NSString* ifname = [NSString stringWithUTF8String:temp_addr->ifa_name];
        if (
          // Check if interface is en0 which is the wifi connection on the iPhone
          // and the ethernet connection on the Apple TV
          [ifname isEqualToString:@"en0"] ||
          // Check if interface is en1 which is the wifi connection on the Apple TV
          [ifname isEqualToString:@"en1"]
        ) {
          // Get NSString from C String
          char str[INET_ADDRSTRLEN];
          inet_ntop(AF_INET, &((struct sockaddr_in *)temp_addr->ifa_netmask)->sin_addr, str, INET_ADDRSTRLEN);
          subnet = [NSString stringWithUTF8String:str];
        }
      }

      temp_addr = temp_addr->ifa_next;
    }
  }
  // Free memory
  freeifaddrs(interfaces);
  return subnet;
}

#if !TARGET_OS_TV && !TARGET_OS_OSX && !TARGET_OS_MACCATALYST
- (NSString *)ssid
{
  return [self cachedSSID];
}

- (NSString *)bssid
{
  return [self cachedBSSID];
}
#endif

@end
