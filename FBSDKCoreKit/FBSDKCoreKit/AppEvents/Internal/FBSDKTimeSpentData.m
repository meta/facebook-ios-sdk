/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <FBSDKCoreKit/FBSDKCoreKit.h>
#import <FBSDKCoreKit_Basics/FBSDKCoreKit_Basics.h>

#import "FBSDKAppEventName+Internal.h"
#import "FBSDKAppEventParameterName+Internal.h"
#import <FBSDKCoreKit/FBSDKAppEventsFlushReason.h>
#import "FBSDKEventLogging.h"
#import "FBSDKInternalUtility+Internal.h"
#import "FBSDKLogger.h"
#import "FBSDKServerConfiguration.h"

// Filename and keys for session length
NSString *const FBSDKTimeSpentFilename = @"com-facebook-sdk-AppEventsTimeSpent.json";
static NSString *const FBSDKTimeSpentPersistKeySessionSecondsSpent = @"secondsSpentInCurrentSession";
static NSString *const FBSDKTimeSpentPersistKeySessionNumInterruptions = @"numInterruptions";
static NSString *const FBSDKTimeSpentPersistKeyLastSuspendTime = @"lastSuspendTime";
static NSString *const FBSDKTimeSpentPersistKeySessionID = @"sessionID";

static const int SECS_PER_MIN = 60;
static const int SECS_PER_HOUR = 60 * SECS_PER_MIN;
static const int SECS_PER_DAY = 24 * SECS_PER_HOUR;

// Will be translated and displayed in App Insights.  Need to maintain same number and value of quanta on the server.
static const long INACTIVE_SECONDS_QUANTA[] =
{
  5 * SECS_PER_MIN,
  15 * SECS_PER_MIN,
  30 * SECS_PER_MIN,
  1 * SECS_PER_HOUR,
  6 * SECS_PER_HOUR,
  12 * SECS_PER_HOUR,
  1 * SECS_PER_DAY,
  2 * SECS_PER_DAY,
  3 * SECS_PER_DAY,
  7 * SECS_PER_DAY,
  14 * SECS_PER_DAY,
  21 * SECS_PER_DAY,
  28 * SECS_PER_DAY,
  60 * SECS_PER_DAY,
  90 * SECS_PER_DAY,
  120 * SECS_PER_DAY,
  150 * SECS_PER_DAY,
  180 * SECS_PER_DAY,
  365 * SECS_PER_DAY,
  LONG_MAX, // keep as LONG_MAX to guarantee loop will terminate
};

static dispatch_queue_t FBSDKTimeSpentDataWriteQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    queue = dispatch_queue_create("com.facebook.sdk.TimeSpentData.write", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

@interface FBSDKTimeSpentData ()

@property (nonatomic, weak) id<FBSDKEventLogging> eventLogger;
@property (nonnull, nonatomic) id<FBSDKServerConfigurationProviding> serverConfigurationProvider;
@property (nonatomic) NSString *sourceApplication;
@property (nonatomic) BOOL isOpenedFromAppLink;
@property (nonatomic) BOOL isCurrentlyLoaded;
@property (nonatomic) NSTimeInterval lastRestoreTime;
@property (nonatomic) NSTimeInterval secondsSpentInCurrentSession;
@property (nonatomic) NSTimeInterval timeSinceLastSuspend;
@property (nonatomic) int numInterruptionsInCurrentSession;
@property (nonatomic) NSString *sessionID;
@property (nonatomic) NSTimeInterval lastSuspendTime;
@property (nonatomic) BOOL shouldLogActivateEvent;
@property (nonatomic) BOOL shouldLogDeactivateEvent;
@property (nonatomic, copy) NSString *suspendedSessionData;

@end

/**
 * This class encapsulates the notion of an app 'session' - the length of time that the user has
 * spent in the app that can be considered a single usage of the app.  Apps may be frequently interrupted
 * do to other device activity, like a text message, so this class allows those interruptions to be smoothed
 * out and the time actually spent in the app excluding this interruption time to be accumulated.  Also,
 * once a certain amount of time has gone by where the app is not in the foreground, we consider the
 * session to be complete, and a new session beginning.  When this occurs, we log a 'deactivate app' event
 * with the duration of the previous session as the 'value' of this event, along with the number of
 * interruptions from that previous session as an event parameter.
 */
@implementation FBSDKTimeSpentData

- (instancetype)initWithEventLogger:(id<FBSDKEventLogging>)eventLogger
        serverConfigurationProvider:(id<FBSDKServerConfigurationProviding>)serverConfigurationProvider
{
  if ((self = [super init])) {
    _eventLogger = eventLogger;
    _serverConfigurationProvider = serverConfigurationProvider;
  }

  return self;
}

// Calculate and persist time spent data for this instance of the app activation.
- (void)suspend
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [self suspendTimeSpentData];
  });
}

- (void)suspendTimeSpentData
{
  if (!self.isCurrentlyLoaded) {
    return;
  }

  NSTimeInterval now = round([NSDate date].timeIntervalSince1970);
  NSTimeInterval timeSinceRestore = now - self.lastRestoreTime;

  // Can happen if the clock on the device is changed
  if (timeSinceRestore < 0) {
    [FBSDKLogger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                           logEntry:@"Clock skew detected"];
    timeSinceRestore = 0;
  }

  self.secondsSpentInCurrentSession += timeSinceRestore;

  NSDictionary<NSString *, id> *timeSpentData =
  @{
    FBSDKTimeSpentPersistKeySessionSecondsSpent : @(self.secondsSpentInCurrentSession),
    FBSDKTimeSpentPersistKeySessionNumInterruptions : @(self.numInterruptionsInCurrentSession),
    FBSDKTimeSpentPersistKeyLastSuspendTime : @(now),
    FBSDKTimeSpentPersistKeySessionID : self.sessionID,
  };

  NSString *content = [FBSDKBasicUtility JSONStringForObject:timeSpentData error:NULL invalidObjectHandler:NULL];
  // Complete the lifecycle transition before dispatching persistence work.
  self.suspendedSessionData = content;
  self.isCurrentlyLoaded = NO;

  __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
  bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
    [UIApplication.sharedApplication endBackgroundTask:bgTask];
    bgTask = UIBackgroundTaskInvalid;
  }];
  dispatch_async(FBSDKTimeSpentDataWriteQueue(), ^{
    [content writeToFile:[FBSDKBasicUtility persistenceFilePath:FBSDKTimeSpentFilename]
              atomically:YES
                encoding:NSASCIIStringEncoding
                   error:nil];

    NSString *msg = [NSString stringWithFormat:@"FBSDKTimeSpentData Persist: %@", content];
    [FBSDKLogger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                           logEntry:msg];

    if (bgTask != UIBackgroundTaskInvalid) {
      [UIApplication.sharedApplication endBackgroundTask:bgTask];
      bgTask = UIBackgroundTaskInvalid;
    }
  });
}

// Called during activation - either through an explicit 'activateApp' call or implicitly when the app is foregrounded.
// In both cases, we restore the persisted event data.  In the case of the activateApp, we log an 'app activated'
// event if there's been enough time between the last deactivation and now.
- (void)restore:(BOOL)calledFromActivateApp
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [self restoreTimeSpendDataWithCalledFromActivateApp:calledFromActivateApp];
  });
}

- (void)restoreTimeSpendDataWithCalledFromActivateApp:(BOOL)isCalledFromActivateApp
{
  // It's possible to call this multiple times during the time the app is in the foreground.  If this is the case,
  // just restore persisted data the first time.
  if (!self.isCurrentlyLoaded) {
    NSTimeInterval now = round([NSDate date].timeIntervalSince1970);
    // A foreground transition may arrive before the asynchronous write finishes.
    // Use the latest snapshot in this process instead of re-reading an older file.
    NSString *content = self.suspendedSessionData;
    if (!content) {
      content = [[NSString alloc] initWithContentsOfFile:[FBSDKBasicUtility persistenceFilePath:FBSDKTimeSpentFilename]
                                          usedEncoding:nil
                                                 error:nil];
    }

    if (!content) {
      // Nothing persisted, so this is the first launch.
      self.sessionID = [NSUUID UUID].UUIDString;
      self.secondsSpentInCurrentSession = 0;
      self.numInterruptionsInCurrentSession = 0;
      self.lastSuspendTime = 0;

      // We want to log the app activation event on the first launch, but not the deactivate event
      self.shouldLogActivateEvent = YES;
      self.shouldLogDeactivateEvent = NO;
    } else {
      NSDictionary<id, id> *results = [FBSDKBasicUtility objectForJSONString:content error:NULL];

      self.lastSuspendTime = [results[FBSDKTimeSpentPersistKeyLastSuspendTime] longValue];

      self.timeSinceLastSuspend = now - self.lastSuspendTime;
      self.secondsSpentInCurrentSession = [results[FBSDKTimeSpentPersistKeySessionSecondsSpent] intValue];
      self.sessionID = results[FBSDKTimeSpentPersistKeySessionID] ?: [NSUUID UUID].UUIDString;
      self.numInterruptionsInCurrentSession = [results[FBSDKTimeSpentPersistKeySessionNumInterruptions] intValue];
      self.shouldLogActivateEvent = (self.timeSinceLastSuspend > [[self.serverConfigurationProvider cachedServerConfiguration] sessionTimeoutInterval]);

      // Other than the first launch, we always log the last session's deactivate with this session's activate.
      self.shouldLogDeactivateEvent = self.shouldLogActivateEvent;

      if (!self.shouldLogDeactivateEvent) {
        // If we're not logging, then the time we spent deactivated is considered another interruption.  But cap it
        // so errant or test uses doesn't blow out the cardinality on the backend processing
        self.numInterruptionsInCurrentSession = MIN(self.numInterruptionsInCurrentSession + 1, 200);
      }
    }

    self.lastRestoreTime = now;
    self.isCurrentlyLoaded = YES;

    if (isCalledFromActivateApp) {
      // It's important to log deactivate first to reset sessionID
      if (self.shouldLogDeactivateEvent) {
        [self.eventLogger logEvent:FBSDKAppEventNameDeactivatedApp
                        valueToSum:self.secondsSpentInCurrentSession
                        parameters:[self appEventsParametersForDeactivate]];

        // We've logged the session stats, now reset.
        self.secondsSpentInCurrentSession = 0;
        self.numInterruptionsInCurrentSession = 0;
        self.sessionID = [NSUUID UUID].UUIDString;
      }

      if (self.shouldLogActivateEvent) {
        [self.eventLogger logEvent:FBSDKAppEventNameActivatedApp
                        parameters:[self appEventsParametersForActivate]];
        // Unless the behavior is set to only allow explicit flushing, we go ahead and flush. App launch
        // events are critical to Analytics so we don't want to lose them.
        if (self.eventLogger.flushBehavior != FBSDKAppEventsFlushBehaviorExplicitOnly) {
          [self.eventLogger flushForReason:FBSDKAppEventsFlushReasonEagerlyFlushingEvent];
        }
      }
    }
  }
}

- (NSDictionary<FBSDKAppEventParameterName, id> *)appEventsParametersForActivate
{
  return @{
    FBSDKAppEventParameterNameLaunchSource : [self getSourceApplication],
    FBSDKAppEventParameterNameSessionID : self.sessionID,
  };
}

- (NSDictionary<FBSDKAppEventParameterName, id> *)appEventsParametersForDeactivate
{
  int quantaIndex = 0;
  while (_timeSinceLastSuspend > INACTIVE_SECONDS_QUANTA[quantaIndex]) {
    quantaIndex++;
  }

  NSMutableDictionary<FBSDKAppEventParameterName, id> *params = [@{ FBSDKAppEventParameterNameSessionInterruptions : @(self.numInterruptionsInCurrentSession),
                                                                    FBSDKAppEventParameterNameTimeBetweenSessions : [NSString stringWithFormat:@"session_quanta_%d", quantaIndex],
                                                                    FBSDKAppEventParameterNameLaunchSource : [self getSourceApplication],
                                                                    FBSDKAppEventParameterNameSessionID : self.sessionID ?: @"", } mutableCopy];
  if (_lastSuspendTime) {
    [FBSDKTypeUtility dictionary:params setObject:@(_lastSuspendTime) forKey:@"_logTime"];
  }
  return [params copy];
}

- (void)setSourceApplication:(nullable NSString *)sourceApplication openURL:(nullable NSURL *)url
{
  [self setSourceApplication:sourceApplication
               isFromAppLink:[FBSDKInternalUtility.sharedUtility parametersFromFBURL:url][@"al_applink_data"] != nil];
}

- (void)setSourceApplication:(nullable NSString *)sourceApplication isFromAppLink:(BOOL)isFromAppLink
{
  self.isOpenedFromAppLink = isFromAppLink;
  self.sourceApplication = sourceApplication;
}

- (NSString *)getSourceApplication
{
  NSString *openType = @"Unclassified";
  if (self.isOpenedFromAppLink) {
    openType = @"AppLink";
  }
  return (self.sourceApplication
    ? [NSString stringWithFormat:@"%@(%@)", openType, self.sourceApplication]
    : openType);
}

- (void)resetSourceApplication
{
  self.sourceApplication = nil;
  self.isOpenedFromAppLink = NO;
}

- (void)registerAutoResetSourceApplication
{
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(resetSourceApplication)
                                             name:UIApplicationDidEnterBackgroundNotification
                                           object:nil];
}

@end
