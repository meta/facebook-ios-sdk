/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSDKAppEvents+Internal.h"

#import <FBSDKCoreKit_Basics/FBSDKCoreKit_Basics.h>
#import <objc/runtime.h>
#import <StoreKit/StoreKit.h>
#import <UIKit/UIApplication.h>

#import <FBSDKCoreKit/FBSDKCoreKit.h>
#import <FBSDKCoreKit/FBSDKCoreKit-Swift.h>

#import "FBSDKATEPublishing.h"
#import "FBSDKAccessToken.h"
#import "FBSDKAppEventName.h"
#import "FBSDKAppEventName+Internal.h"
#import "FBSDKAppEventParameterName+Internal.h"
#import "FBSDKAppEventParameterProduct.h"
#import "FBSDKAppEventParameterProduct+Internal.h"
#import "FBSDKAppEventUserDataType.h"
#import "FBSDKAppEventsWKWebViewKeys.h"
#import "FBSDKAppLinkURLCache.h"
#import "FBSDKAtePublishing.h"
#import "FBSDKConstants.h"
#import "FBSDKDynamicFrameworkLoader.h"
#import "FBSDKFeatureChecking.h"
#import "FBSDKGraphRequestFactoryProtocol.h"
#import "FBSDKInternalUtility+Internal.h"
#import "FBSDKLogger.h"
#import "FBSDKLogging.h"
#import "FBSDKScreenTitleObserver.h"
#import "FBSDKServerConfiguration.h"
#import "FBSDKUtility.h"

#if !TARGET_OS_TV

 #import "FBSDKEventBindingManager.h"
 #import "FBSDKHybridAppEventsScriptMessageHandler.h"

#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@protocol FBSDKCAPIReporter;

// Event parameter values internal to this file

NSString *const FBSDKGateKeeperAppEventsKillSwitch = @"app_events_killswitch";

NSString *const FBSDKAppEventsOverrideAppIDBundleKey = @"FacebookLoggingOverrideAppID";

//
// Push Notifications
//
// Activities Endpoint Parameter
static NSString *const FBSDKActivitesParameterPushDeviceToken = @"device_token";
// Event Parameter
// Payload Keys
static NSString *const FBSDKAppEventsPushPayloadKey = @"fb_push_payload";
static NSString *const FBSDKAppEventsPushPayloadCampaignKey = @"campaign";

#define NUM_LOG_EVENTS_TO_TRY_TO_FLUSH_AFTER 100
#define FLUSH_PERIOD_IN_SECONDS 15
#define USER_ID_USER_DEFAULTS_KEY @"com.facebook.sdk.appevents.userid"

#define FBUnityUtilityClassName "FBUnityUtility"
#define FBUnityUtilityUpdateBindingsSelector @"triggerUpdateBindings:"

static FBSDKAppEvents *_shared = nil;
static NSString *g_overrideAppID = nil;
static BOOL g_explicitEventsLoggedYet = NO;
#if DEBUG
static BOOL g_hasLoggedManualImplicitLoggingWarning = NO;
#endif

@interface FBSDKAppEvents ()

@property (nonatomic) UIApplicationState applicationState;
@property (nullable, nonatomic, copy) NSString *pushNotificationsDeviceTokenString;
@property (nonatomic) dispatch_source_t flushTimer;
@property (nonatomic) BOOL isConfigured;

@property (nonatomic) FBSDKServerConfiguration *serverConfiguration;
@property (nonatomic) FBSDKAppEventsState *appEventsState;
@property (nonatomic) BOOL _isUnityInitialized; // not publicly readable
@property (nonatomic) BOOL isObservingApplicationStatePersistence;

// Dependencies

@property (nullable, nonatomic) Class<FBSDKGateKeeperManaging> gateKeeperManager;
@property (nullable, nonatomic) id<FBSDKAppEventsConfigurationProviding> appEventsConfigurationProvider;
@property (nullable, nonatomic) id<FBSDKServerConfigurationProviding> serverConfigurationProvider;
@property (nullable, nonatomic) id<FBSDKGraphRequestFactory> graphRequestFactory;
@property (nullable, nonatomic) id<FBSDKFeatureChecking> featureChecker;
@property (nullable, nonatomic) id<FBSDKDataPersisting> primaryDataStore;
@property (nullable, nonatomic) Class<FBSDKLogging> logger;
@property (nullable, nonatomic) id<FBSDKSettings> settings;
@property (nullable, nonatomic) id<FBSDKPaymentObserving> paymentObserver;
@property (nullable, nonatomic) id<FBSDKSourceApplicationTracking, FBSDKTimeSpentRecording> timeSpentRecorder;
@property (nullable, nonatomic) id<FBSDKAppEventsStatePersisting> appEventsStateStore;
@property (nullable, nonatomic) id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing> eventDeactivationParameterProcessor;
@property (nullable, nonatomic) id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing> restrictiveDataFilterParameterProcessor;
@property (nullable, nonatomic) id<FBSDKAppEventsParameterProcessing> protectedModeManager;
@property (nullable, nonatomic) id<FBSDKMACARuleMatching> bannedParamsManager;
@property (nullable, nonatomic) id<FBSDKMACARuleMatching> stdParamEnforcementManager;
@property (nullable, nonatomic) id<FBSDKMACARuleMatching> macaRuleMatchingManager;
@property (nullable, nonatomic) id<FBSDKMACARuleMatching> vvpConfigManager;
@property (nullable, nonatomic) id<FBSDKEventsProcessing> blocklistEventsManager;
@property (nullable, nonatomic) id<FBSDKEventsProcessing> redactedEventsManager;
@property (nullable, nonatomic) id<FBSDKAppEventsParameterProcessing> sensitiveParamsManager;
@property (nullable, nonatomic) id<FBSDKATEPublisherCreating> atePublisherFactory;
@property (nullable, nonatomic) id<FBSDKATEPublishing> atePublisher;
@property (nullable, nonatomic) id<FBSDKAppEventsStateProviding> appEventsStateProvider;
@property (nullable, nonatomic) id<FBSDKAdvertiserIDProviding> advertiserIDProvider;
@property (nullable, nonatomic) id<FBSDKUserDataPersisting> userDataStore;
@property (nullable, nonatomic) id<FBSDKAppEventDropDetermining, FBSDKAppEventParametersExtracting, FBSDKAppEventsUtility, FBSDKLoggingNotifying> appEventsUtility;
@property (nullable, nonatomic) id<FBSDKInternalUtility> internalUtility;
@property (nullable, nonatomic) id<FBSDKCAPIReporter> capiReporter;
@property (nullable, nonatomic) id<FBSDKTransactionObserving> transactionObserver;
@property (nullable, nonatomic) id<FBSDKIAPFailedTransactionLoggingCreating> failedTransactionLoggingFactory;
@property (nullable, nonatomic) id<FBSDKIAPDedupeProcessing> iapDedupeProcessor;
@property (nullable, nonatomic) id<FBSDKIAPTransactionCaching> iapTransactionCache;

#if !TARGET_OS_TV
@property (nullable, nonatomic) id<FBSDKEventProcessing, FBSDKIntegrityParametersProcessorProvider> onDeviceMLModelManager;
@property (nullable, nonatomic) id<FBSDKMetadataIndexing> metadataIndexer;
@property (nullable, nonatomic) id<FBSDKAppEventsReporter> skAdNetworkReporter;
@property (nullable, nonatomic) id<FBSDKAppEventsReporter> skAdNetworkReporterV2;
@property (nullable, nonatomic) Class<FBSDKCodelessIndexing> codelessIndexer;
@property (nullable, nonatomic) Class<FBSDKSwizzling> swizzler;
@property (nullable, nonatomic) FBSDKEventBindingManager *eventBindingManager;
@property (nullable, nonatomic) Class<FBSDKAEMReporter> aemReporter;
#endif

@end

@implementation FBSDKAppEvents
{
  NSString *_userID;
}

#pragma mark - Object Lifecycle

+ (void)initialize
{
  if (self == FBSDKAppEvents.class) {
    g_overrideAppID = [[NSBundle.mainBundle objectForInfoDictionaryKey:FBSDKAppEventsOverrideAppIDBundleKey] copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^(void) {
      // Forces reading or creating of `anonymousID` used by this type
      [FBSDKBasicUtility anonymousID];
    });
  }
}

- (instancetype)init
{
  return [self initWithFlushBehavior:FBSDKAppEventsFlushBehaviorAuto
                flushPeriodInSeconds:FLUSH_PERIOD_IN_SECONDS];
}

- (instancetype)initWithFlushBehavior:(FBSDKAppEventsFlushBehavior)flushBehavior
                 flushPeriodInSeconds:(int)flushPeriodInSeconds
{
  self = [super init];
  if (self) {
    _flushBehavior = flushBehavior;

    __weak FBSDKAppEvents *weakSelf = self;
    self.flushTimer = [FBSDKUtility startGCDTimerWithInterval:flushPeriodInSeconds
                                                        block:^{
                                                          [weakSelf flushTimerFired:nil];
                                                        }];

    self.applicationState = UIApplicationStateInactive;
  }

  return self;
}

- (void)startObservingApplicationStatePersistenceNotifications
{
  // Idempotent: this may be called during synchronous init and again from
  // startObservingApplicationLifecycleNotifications; register the persist observers only once.
  if (self.isObservingApplicationStatePersistence) {
    return;
  }
  self.isObservingApplicationStatePersistence = YES;

  [NSNotificationCenter.defaultCenter
   addObserver:self
   selector:@selector(applicationMovingFromActiveState)
   name:UIApplicationWillResignActiveNotification
   object:NULL];

  [NSNotificationCenter.defaultCenter
   addObserver:self
   selector:@selector(applicationTerminating)
   name:UIApplicationWillTerminateNotification
   object:NULL];
}

- (void)startObservingApplicationLifecycleNotifications
{
  // The persist-on-close observers are armed here too (idempotently) so a lone call still
  // registers the full set; when init arms them earlier this is a no-op.
  [self startObservingApplicationStatePersistenceNotifications];

  [NSNotificationCenter.defaultCenter
   addObserver:self
   selector:@selector(applicationDidBecomeActive)
   name:UIApplicationDidBecomeActiveNotification
   object:NULL];
}

- (void)dealloc
{
  [FBSDKUtility stopGCDTimer:self.flushTimer];
}

#pragma mark - Public Methods

- (void)logEvent:(FBSDKAppEventName)eventName
{
  [self logEvent:eventName parameters:@{}];
}

- (void)logEvent:(FBSDKAppEventName)eventName
      valueToSum:(double)valueToSum
{
  [self logEvent:eventName
      valueToSum:valueToSum
      parameters:@{}];
}

- (void)logEvent:(FBSDKAppEventName)eventName
      parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
{
  [self logEvent:eventName
      valueToSum:nil
      parameters:parameters
     accessToken:nil];
}

- (void)logEvent:(FBSDKAppEventName)eventName
      valueToSum:(double)valueToSum
      parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
{
  [self logEvent:eventName
      valueToSum:@(valueToSum)
      parameters:parameters
     accessToken:nil];
}

- (void)logEvent:(FBSDKAppEventName)eventName
      valueToSum:(NSNumber *)valueToSum
      parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
     accessToken:(FBSDKAccessToken *)accessToken
{
  [self logEvent:eventName
           valueToSum:valueToSum
           parameters:parameters
   isImplicitlyLogged:[parameters[FBSDKAppEventParameterNameImplicitlyLogged] boolValue]
          accessToken:accessToken];
}

- (void)logPurchase:(double)purchaseAmount
           currency:(NSString *)currency
{
  [self logPurchase:purchaseAmount
           currency:currency
         parameters:@{}];
}

- (void)logPurchase:(double)purchaseAmount
           currency:(NSString *)currency
         parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
{
  [self logPurchase:purchaseAmount
           currency:currency
         parameters:parameters
        accessToken:nil];
}

-(void)logFailedStoreKit2Purchase:(NSString *)productID
{
  [[self.failedTransactionLoggingFactory createIAPFailedTransactionLogging] logFailedStoreKit2Purchase:productID];
}

- (void)logPurchase:(double)purchaseAmount
           currency:(NSString *)currency
         parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
        accessToken:(nullable FBSDKAccessToken *)accessToken
{
  [self validateConfiguration];
  [self checkForAutologgedPurchases];

  // A purchase event is just a regular logged event with a given event name
  // and treating the currency value as going into the parameters dictionary.
  NSDictionary<FBSDKAppEventParameterName, id> *newParameters;
  if (!parameters) {
    newParameters = @{ FBSDKAppEventParameterNameCurrency : currency };
  } else {
    newParameters = [NSMutableDictionary dictionaryWithDictionary:parameters];
    [newParameters setValue:currency forKey:FBSDKAppEventParameterNameCurrency];
  }

  [self logEvent:FBSDKAppEventNamePurchased
      valueToSum:@(purchaseAmount)
      parameters:newParameters
     accessToken:accessToken];
}

/*
 * Push Notifications Logging
 */

- (void)logPushNotificationOpen:(NSDictionary<NSString *, id> *)payload
{
  [self logPushNotificationOpen:payload action:@""];
}

- (void)logPushNotificationOpen:(NSDictionary<NSString *, id> *)payload action:(NSString *)action
{
  [self validateConfiguration];

  NSDictionary<NSString *, id> *facebookPayload = payload[FBSDKAppEventsPushPayloadKey];
  if (!facebookPayload) {
    return;
  }
  NSString *campaign = facebookPayload[FBSDKAppEventsPushPayloadCampaignKey];
  if (campaign.length == 0) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"Malformed payload specified for logging a push notification open."];
    return;
  }

  NSMutableDictionary<FBSDKAppEventParameterName, id> *parameters = [@{FBSDKAppEventParameterNamePushCampaign : campaign} mutableCopy];
  if (action && action.length > 0) {
    [FBSDKTypeUtility dictionary:parameters setObject:action forKey:FBSDKAppEventParameterNamePushAction];
  }

  [self logEvent:FBSDKAppEventNamePushOpened parameters:parameters];
}

- (void)logProductItem:(NSString *)itemID
          availability:(FBSDKProductAvailability)availability
             condition:(FBSDKProductCondition)condition
           description:(NSString *)description
             imageLink:(NSString *)imageLink
                  link:(NSString *)link
                 title:(NSString *)title
           priceAmount:(double)priceAmount
              currency:(NSString *)currency
                  gtin:(nullable NSString *)gtin
                   mpn:(nullable NSString *)mpn
                 brand:(nullable NSString *)brand
            parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
{
  [self validateConfiguration];

  if (itemID == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"itemID cannot be null"];
    return;
  } else if (description == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"description cannot be null"];
    return;
  } else if (imageLink == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"imageLink cannot be null"];
    return;
  } else if (link == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"link cannot be null"];
    return;
  } else if (title == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"title cannot be null"];
    return;
  } else if (currency == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"currency cannot be null"];
    return;
  } else if (gtin == nil && mpn == nil && brand == nil) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                           logEntry:@"Either gtin, mpn or brand is required"];
    return;
  }

  NSMutableDictionary<FBSDKAppEventParameterName, id> *dict = [NSMutableDictionary dictionary];
  if (nil != parameters) {
    dict.valuesForKeysWithDictionary = parameters;
  }

  [FBSDKTypeUtility dictionary:dict setObject:itemID forKey:FBSDKAppEventParameterProductItemID];

  NSString *avail = nil;
  switch (availability) {
    case FBSDKProductAvailabilityInStock:
      avail = @"IN_STOCK"; break;
    case FBSDKProductAvailabilityOutOfStock:
      avail = @"OUT_OF_STOCK"; break;
    case FBSDKProductAvailabilityPreOrder:
      avail = @"PREORDER"; break;
    case FBSDKProductAvailabilityAvailableForOrder:
      avail = @"AVALIABLE_FOR_ORDER"; break;
    case FBSDKProductAvailabilityDiscontinued:
      avail = @"DISCONTINUED"; break;
  }
  if (avail) {
    [FBSDKTypeUtility dictionary:dict setObject:avail forKey:FBSDKAppEventParameterProductAvailability];
  }

  NSString *cond = nil;
  switch (condition) {
    case FBSDKProductConditionNew:
      cond = @"NEW"; break;
    case FBSDKProductConditionRefurbished:
      cond = @"REFURBISHED"; break;
    case FBSDKProductConditionUsed:
      cond = @"USED"; break;
  }
  if (cond) {
    [FBSDKTypeUtility dictionary:dict setObject:cond forKey:FBSDKAppEventParameterProductCondition];
  }

  [FBSDKTypeUtility dictionary:dict setObject:description forKey:FBSDKAppEventParameterProductDescription];
  [FBSDKTypeUtility dictionary:dict setObject:imageLink forKey:FBSDKAppEventParameterProductImageLink];
  [FBSDKTypeUtility dictionary:dict setObject:link forKey:FBSDKAppEventParameterProductLink];
  [FBSDKTypeUtility dictionary:dict setObject:title forKey:FBSDKAppEventParameterProductTitle];
  [FBSDKTypeUtility dictionary:dict setObject:[NSString stringWithFormat:@"%.3lf", priceAmount] forKey:FBSDKAppEventParameterProductPriceAmount];
  [FBSDKTypeUtility dictionary:dict setObject:currency forKey:FBSDKAppEventParameterProductPriceCurrency];
  if (gtin) {
    [FBSDKTypeUtility dictionary:dict setObject:gtin forKey:FBSDKAppEventParameterProductGTIN];
  }
  if (mpn) {
    [FBSDKTypeUtility dictionary:dict setObject:mpn forKey:FBSDKAppEventParameterProductMPN];
  }
  if (brand) {
    [FBSDKTypeUtility dictionary:dict setObject:brand forKey:FBSDKAppEventParameterProductBrand];
  }

  [self logEvent:FBSDKAppEventNameProductCatalogUpdate
      parameters:dict];
}

- (void)activateApp
{
  [self validateConfiguration];

  [self.appEventsUtility ensureOnMainThread:NSStringFromSelector(_cmd) className:NSStringFromClass(self.class)];

  // Fetch app settings and register for transaction notifications only if app supports implicit purchase events
  [self publishInstall];
  [self fetchServerConfiguration:NULL];

  // Restore time spent data, indicating that we're being called from "activateApp", which will,
  // when appropriate, result in logging an "activated app" and "deactivated app" (for the
  // previous session) App Event.
  [self.timeSpentRecorder restore:YES];
}

- (void)setPushNotificationsDeviceToken:(nullable NSData *)deviceToken
{
  [self validateConfiguration];

  NSString *deviceTokenString = [self.internalUtility hexadecimalStringFromData:deviceToken];
  if (deviceTokenString) {
    self.pushNotificationsDeviceTokenString = deviceTokenString;
  }
}

- (void)setPushNotificationsDeviceTokenString:(nullable NSString *)deviceTokenString
{
  [self validateConfiguration];

  if (deviceTokenString == nil) {
    _pushNotificationsDeviceTokenString = nil;
    return;
  }

  NSString *currentToken = self.pushNotificationsDeviceTokenString ?: @"";

  if (![deviceTokenString isEqualToString:currentToken]) {
    _pushNotificationsDeviceTokenString = deviceTokenString;

    [self logEvent:FBSDKAppEventNamePushTokenObtained];

    // Unless the behavior is set to only allow explicit flushing, we go ahead and flush the event
    if (self.flushBehavior != FBSDKAppEventsFlushBehaviorExplicitOnly) {
      [self flushForReason:FBSDKAppEventsFlushReasonEagerlyFlushingEvent];
    }
  }
}

- (nullable NSString *)loggingOverrideAppID
{
  @synchronized (self) {
    return g_overrideAppID;
  }
}

- (void)setLoggingOverrideAppID:(nullable NSString *)appID
{
  [self validateConfiguration];


  if (![[self loggingOverrideAppID] isEqualToString:appID]) {
    if (g_explicitEventsLoggedYet) {
      [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                             logEntry:@"AppEvents.shared.loggingOverrideAppID should only be set prior to any events being logged."];
    }
    @synchronized (self) {
      g_overrideAppID = appID;
    }
  }
}

- (void)flush
{
  [self validateConfiguration];
  [self flushForReason:FBSDKAppEventsFlushReasonExplicit];
}

- (nullable NSString *)userID
{
  [self validateConfiguration];
  return [_userID copy];
}

- (void)setUserID:(nullable NSString *)userID
{
  [self validateConfiguration];
  _userID = [userID copy];
  [self.primaryDataStore fb_setObject:userID forKey:USER_ID_USER_DEFAULTS_KEY];
}

- (void)setUserEmail:(nullable NSString *)email
           firstName:(nullable NSString *)firstName
            lastName:(nullable NSString *)lastName
               phone:(nullable NSString *)phone
         dateOfBirth:(nullable NSString *)dateOfBirth
              gender:(nullable NSString *)gender
                city:(nullable NSString *)city
               state:(nullable NSString *)state
                 zip:(nullable NSString *)zip
             country:(nullable NSString *)country
{
  [self.userDataStore setUserEmail:email
           firstName:firstName
            lastName:lastName
               phone:phone
         dateOfBirth:dateOfBirth
              gender:gender
                city:city
               state:state
                 zip:zip
             country:country];
}

- (nullable NSString *)getUserData
{
  return [self.userDataStore getUserData];
}

- (void)clearUserData
{
  [self.userDataStore clearUserData];
}

- (void)setUserData:(nullable NSString *)data
            forType:(FBSDKAppEventUserDataType)type
{
  [self.userDataStore setUserData:data forType:type];
}

- (void)clearUserDataForType:(FBSDKAppEventUserDataType)type
{
  [self.userDataStore clearUserDataForType:type];
}

- (NSString *)anonymousID
{
  return [FBSDKBasicUtility anonymousID];
}

#if !TARGET_OS_TV

- (void)augmentHybridWebView:(WKWebView *)webView
{
  [self validateConfiguration];

  if ([webView isKindOfClass:WKWebView.class]) {
    if (WKUserScript.class != nil) {
      WKUserContentController *controller = webView.configuration.userContentController;
      FBSDKHybridAppEventsScriptMessageHandler *scriptHandler = [[FBSDKHybridAppEventsScriptMessageHandler alloc] initWithEventLogger:self
                                                                                                                      loggingNotifier:self.appEventsUtility];
      [controller addScriptMessageHandler:scriptHandler name:FBSDKAppEventsWKWebViewMessagesHandlerKey];

      NSString *js = [NSString stringWithFormat:@"window.fbmq_%@={'sendEvent': function(pixel_id,event_name,custom_data){var msg={\"%@\":pixel_id, \"%@\":event_name,\"%@\":custom_data};window.webkit.messageHandlers[\"%@\"].postMessage(msg);}, 'getProtocol':function(){return \"%@\";}}",
                      self.appID,
                      FBSDKAppEventsWKWebViewMessagesPixelIDKey,
                      FBSDKAppEventsWKWebViewMessagesEventKey,
                      FBSDKAppEventsWKWebViewMessagesParamsKey,
                      FBSDKAppEventsWKWebViewMessagesHandlerKey,
                      FBSDKAppEventsWKWebViewMessagesProtocolKey
      ];

      [controller addUserScript:[[WKUserScript.class alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
  } else {
    [self.appEventsUtility logAndNotify:@"You must call augmentHybridWebView with WebKit linked to your project and a WKWebView instance"];
  }
}

#endif

- (void)setIsUnityInitialized:(BOOL)isUnityInitialized
{
  self._isUnityInitialized = isUnityInitialized;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
- (void)sendEventBindingsToUnity
{
  [self validateConfiguration];

  // Send event bindings to Unity only Unity is initialized
  if (self._isUnityInitialized
      && self.serverConfiguration
      && [NSJSONSerialization isValidJSONObject:self.serverConfiguration.eventBindings]
  ) {
    NSData *jsonData = [FBSDKTypeUtility dataWithJSONObject:self.serverConfiguration.eventBindings ?: @""
                                                    options:0
                                                      error:nil];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    Class classFBUnityUtility = objc_lookUpClass(FBUnityUtilityClassName);
    SEL updateBindingsSelector = NSSelectorFromString(FBUnityUtilityUpdateBindingsSelector);
    if ([classFBUnityUtility respondsToSelector:updateBindingsSelector]) {
      [classFBUnityUtility performSelector:updateBindingsSelector withObject:jsonString];
    }
  }
}

#pragma clang diagnostic pop

#pragma mark - Internal Methods

- (void)   configureWithGateKeeperManager:(nonnull Class<FBSDKGateKeeperManaging>)gateKeeperManager
           appEventsConfigurationProvider:(nonnull id<FBSDKAppEventsConfigurationProviding>)appEventsConfigurationProvider
              serverConfigurationProvider:(nonnull id<FBSDKServerConfigurationProviding>)serverConfigurationProvider
                      graphRequestFactory:(nonnull id<FBSDKGraphRequestFactory>)graphRequestFactory
                           featureChecker:(nonnull id<FBSDKFeatureChecking>)featureChecker
                         primaryDataStore:(nonnull id<FBSDKDataPersisting>)primaryDataStore
                                   logger:(nonnull Class<FBSDKLogging>)logger
                                 settings:(nonnull id<FBSDKSettings>)settings
                          paymentObserver:(nonnull id<FBSDKPaymentObserving>)paymentObserver
                        timeSpentRecorder:(nonnull id<FBSDKSourceApplicationTracking, FBSDKTimeSpentRecording>)timeSpentRecorder
                      appEventsStateStore:(nonnull id<FBSDKAppEventsStatePersisting>)appEventsStateStore
      eventDeactivationParameterProcessor:(nonnull id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing>)eventDeactivationParameterProcessor
  restrictiveDataFilterParameterProcessor:(nonnull id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing>)restrictiveDataFilterParameterProcessor
                      atePublisherFactory:(nonnull id<FBSDKATEPublisherCreating>)atePublisherFactory
                   appEventsStateProvider:(nonnull id<FBSDKAppEventsStateProviding>)appEventsStateProvider
                     advertiserIDProvider:(nonnull id<FBSDKAdvertiserIDProviding>)advertiserIDProvider
                            userDataStore:(nonnull id<FBSDKUserDataPersisting>)userDataStore
                         appEventsUtility:(nonnull id<FBSDKAppEventDropDetermining, FBSDKAppEventParametersExtracting, FBSDKAppEventsUtility, FBSDKLoggingNotifying>)appEventsUtility
                          internalUtility:(nonnull id<FBSDKInternalUtility>)internalUtility
                             capiReporter:(id<FBSDKCAPIReporter>)capiReporter
                     protectedModeManager:(nonnull id<FBSDKAppEventsParameterProcessing>)protectedModeManager
                      bannedParamsManager:(nonnull id<FBSDKMACARuleMatching>)bannedParamsManager
               stdParamEnforcementManager:(nonnull id<FBSDKMACARuleMatching>)stdParamEnforcementManager
                 macaRuleMatchingManager:(nonnull id<FBSDKMACARuleMatching>)macaRuleMatchingManager
                        vvpConfigManager:(nonnull id<FBSDKMACARuleMatching>)vvpConfigManager
                   blocklistEventsManager:(nonnull id<FBSDKEventsProcessing>)blocklistEventsManager
                    redactedEventsManager:(nonnull id<FBSDKEventsProcessing>)redactedEventsManager
                   sensitiveParamsManager:(nonnull id<FBSDKAppEventsParameterProcessing>)sensitiveParamsManager
                      transactionObserver:(nonnull id<FBSDKTransactionObserving>)transactionObserver
          failedTransactionLoggingFactory:(nonnull id<FBSDKIAPFailedTransactionLoggingCreating>)failedTransactionLoggingFactory
                       iapDedupeProcessor:(nonnull id<FBSDKIAPDedupeProcessing>)iapDedupeProcessor
                      iapTransactionCache:(nonnull id<FBSDKIAPTransactionCaching>)iapTransactionCache
{
  self.gateKeeperManager = gateKeeperManager;
  self.appEventsConfigurationProvider = appEventsConfigurationProvider;
  self.serverConfigurationProvider = serverConfigurationProvider;
  self.graphRequestFactory = graphRequestFactory;
  self.featureChecker = featureChecker;
  self.primaryDataStore = primaryDataStore;
  self.logger = logger;
  self.settings = settings; // This must be set before using/changing `userID`
  self.paymentObserver = paymentObserver;
  self.timeSpentRecorder = timeSpentRecorder;
  self.appEventsStateStore = appEventsStateStore;
  self.eventDeactivationParameterProcessor = eventDeactivationParameterProcessor;
  self.restrictiveDataFilterParameterProcessor = restrictiveDataFilterParameterProcessor;
  self.atePublisherFactory = atePublisherFactory;
  self.appEventsStateProvider = appEventsStateProvider;
  self.advertiserIDProvider = advertiserIDProvider;
  self.userDataStore = userDataStore;
  self.appEventsUtility = appEventsUtility;
  self.internalUtility = internalUtility;
  self.capiReporter = capiReporter;
  self.protectedModeManager = protectedModeManager;
  self.bannedParamsManager = bannedParamsManager;
  self.stdParamEnforcementManager = stdParamEnforcementManager;
  self.macaRuleMatchingManager = macaRuleMatchingManager;
  self.vvpConfigManager = vvpConfigManager;
  self.blocklistEventsManager = blocklistEventsManager;
  self.redactedEventsManager = redactedEventsManager;
  self.sensitiveParamsManager = sensitiveParamsManager;
  self.transactionObserver = transactionObserver;
  self.failedTransactionLoggingFactory = failedTransactionLoggingFactory;
  self.iapDedupeProcessor = iapDedupeProcessor;
  self.iapTransactionCache = iapTransactionCache;

  NSString *appID = self.appID;
  if (appID) {
    self.atePublisher = [atePublisherFactory createPublisherWithAppID:appID];
  }

  self.isConfigured = YES;

  self.userID = [primaryDataStore fb_stringForKey:USER_ID_USER_DEFAULTS_KEY];
}

#if !TARGET_OS_TV

- (void)configureNonTVComponentsWithOnDeviceMLModelManager:(nonnull id<FBSDKEventProcessing, FBSDKIntegrityParametersProcessorProvider>)modelManager
                                           metadataIndexer:(nonnull id<FBSDKMetadataIndexing>)metadataIndexer
                                       skAdNetworkReporter:(nullable id<FBSDKAppEventsReporter>)skAdNetworkReporter
                                       skAdNetworkReporterV2:(nullable id<FBSDKAppEventsReporter>)skAdNetworkReporterV2
                                           codelessIndexer:(nonnull Class<FBSDKCodelessIndexing>)codelessIndexer
                                                  swizzler:(nonnull Class<FBSDKSwizzling>)swizzler
                                               aemReporter:(nonnull Class<FBSDKAEMReporter>)aemReporter
{
  self.onDeviceMLModelManager = modelManager;
  self.metadataIndexer = metadataIndexer;
  self.skAdNetworkReporter = skAdNetworkReporter;
  self.skAdNetworkReporterV2 = skAdNetworkReporterV2;
  self.codelessIndexer = codelessIndexer;
  self.swizzler = swizzler;
  self.aemReporter = aemReporter;
}

#endif

- (void)logInternalEvent:(FBSDKAppEventName)eventName
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
{
  [self logInternalEvent:eventName
              parameters:@{}
      isImplicitlyLogged:isImplicitlyLogged];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              valueToSum:(double)valueToSum
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
{
  [self logInternalEvent:eventName
              valueToSum:valueToSum
              parameters:@{}
      isImplicitlyLogged:isImplicitlyLogged];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
{
  [self logInternalEvent:eventName
              valueToSum:nil
              parameters:parameters
      isImplicitlyLogged:isImplicitlyLogged
             accessToken:nil];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
             accessToken:(FBSDKAccessToken *)accessToken
{
  [self logInternalEvent:eventName
              valueToSum:nil
              parameters:parameters
      isImplicitlyLogged:isImplicitlyLogged
             accessToken:accessToken];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              valueToSum:(double)valueToSum
              parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
{
  [self logInternalEvent:eventName
              valueToSum:@(valueToSum)
              parameters:parameters
      isImplicitlyLogged:isImplicitlyLogged
             accessToken:nil];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              valueToSum:(NSNumber *)valueToSum
              parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
             accessToken:(FBSDKAccessToken *)accessToken
{
  if ([self.settings isAutoLogAppEventsEnabled]) {
    [self logEvent:eventName
             valueToSum:valueToSum
             parameters:parameters
     isImplicitlyLogged:isImplicitlyLogged
            accessToken:accessToken];
  }
}

- (void)logImplicitEvent:(FBSDKAppEventName)eventName
              valueToSum:(NSNumber *)valueToSum
              parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
             accessToken:(FBSDKAccessToken *)accessToken
{
  [self logEvent:eventName
           valueToSum:valueToSum
           parameters:parameters
   isImplicitlyLogged:YES
          accessToken:accessToken];
}

+ (FBSDKAppEvents *)shared
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    _shared = [self new];
  });
  return _shared;
}

- (void)flushForReason:(FBSDKAppEventsFlushReason)flushReason
{
  // Always flush asynchronously, even on main thread, for two reasons:
  // - most consistent code path for all threads.
  // - allow locks being held by caller to be released prior to actual flushing work being done.
  @synchronized(self) {
    if (!self.appEventsState) {
      return;
    }
    FBSDKAppEventsState *copy = [self.appEventsState copy];
    self.appEventsState = [self.appEventsStateProvider createStateWithToken:copy.tokenString
                                                                      appID:copy.appID];

    dispatch_block_t block = ^{
      [self flushOnMainQueue:copy forReason:flushReason];
    };

  #if DEBUG
    block();
  #else
    dispatch_async(dispatch_get_main_queue(), block);
  #endif
  }
}

#pragma mark - Source Application Tracking

- (void)setSourceApplication:(NSString *)sourceApplication openURL:(NSURL *)url
{
  [self.timeSpentRecorder setSourceApplication:sourceApplication openURL:url];
}

- (void)setSourceApplication:(NSString *)sourceApplication isFromAppLink:(BOOL)isFromAppLink
{
  [self.timeSpentRecorder setSourceApplication:sourceApplication isFromAppLink:isFromAppLink];
}

- (void)registerAutoResetSourceApplication
{
  [self.timeSpentRecorder registerAutoResetSourceApplication];
}

#pragma mark - Private Methods
- (nullable NSString *)appID
{
  return self.loggingOverrideAppID ?: [self.settings appID];
}

- (void)publishInstall
{
  NSString *appID = [self appID];
  if (appID.length == 0) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors logEntry:@"Missing [FBSDKAppEvents appID] for [FBSDKAppEvents publishInstall:]"];
    return;
  }
  fb_dispatch_on_main_thread(^{
    NSString *lastAttributionPingString = [NSString stringWithFormat:@"com.facebook.sdk:lastAttributionPing%@", appID];
    if ([self.primaryDataStore fb_objectForKey:lastAttributionPingString]) {
      return;
    }
    [self.primaryDataStore fb_setObject:[NSDate date] forKey:lastAttributionPingString];
    [self fetchServerConfiguration:^{
      if ([self.appEventsUtility shouldDropAppEvents] || [self.gateKeeperManager boolForKey:FBSDKGateKeeperAppEventsKillSwitch defaultValue:NO]) {
        return;
      }
      NSMutableDictionary<NSString *, NSString *> *params = [self.appEventsUtility activityParametersDictionaryForEvent:@"MOBILE_APP_INSTALL"
                                                                                              shouldAccessAdvertisingID:self.serverConfiguration.isAdvertisingIDEnabled
                                                                                                                 userID:self.userID
                                                                                                               userData:[self getUserData]];
      [self appendInstallTimestamp:params];
      [self.capiReporter recordEvent:params];
      NSString *path = [NSString stringWithFormat:@"%@/activities", appID];
      id<FBSDKGraphRequest> request = [self.graphRequestFactory createGraphRequestWithGraphPath:path
                                                                                     parameters:params
                                                                                    tokenString:nil
                                                                                     HTTPMethod:FBSDKHTTPMethodPOST
                                                                                          flags:FBSDKGraphRequestFlagDoNotInvalidateTokenOnError | FBSDKGraphRequestFlagDisableErrorRecovery
                                                                                   forAppEvents:YES
                                                              useAlternativeDefaultDomainPrefix:NO];
      __block id<FBSDKDataPersisting> weakStore = self.primaryDataStore;
      [request startWithCompletion:^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *error) {
        if (!error) {
          NSString *lastInstallResponseKey = [NSString stringWithFormat:@"com.facebook.sdk:lastInstallResponse%@", appID];
          [weakStore fb_setObject:result forKey:lastInstallResponseKey];
        } else {
          [weakStore fb_removeObjectForKey:lastAttributionPingString];
        }
      }];
    }];
  });
}

- (void)publishATE
{
  if (self.appID.length == 0) {
    return;
  }

  self.atePublisher = self.atePublisher ?: [self.atePublisherFactory createPublisherWithAppID:self.appID];

#if DEBUG
  [self.atePublisher publishATE];
#else
  __weak FBSDKAppEvents *weakSelf = self;
  fb_dispatch_on_main_thread(^(void) {
    [weakSelf.atePublisher publishATE];
  });
#endif
}

- (void)appendInstallTimestamp:(nonnull NSMutableDictionary<NSString *, NSString *> *)parameters
{
  if (self.settings.isATETimeSufficientlyDelayed) {
    NSDate *ateTimestamp = self.settings.advertiserTrackingEnabledTimestamp;
    [FBSDKTypeUtility dictionary:parameters setObject:@([self.appEventsUtility convertToUnixTime:ateTimestamp]) forKey:@"install_timestamp"];
  } else {
    NSDate *installTimestamp = self.settings.installTimestamp;
    [FBSDKTypeUtility dictionary:parameters setObject:@([self.appEventsUtility convertToUnixTime:installTimestamp]) forKey:@"install_timestamp"];
  }
}

#if !TARGET_OS_TV
- (void)enableCodelessEvents
{
  if (!self.swizzler) {
    return;
  }

  if (self.serverConfiguration.isCodelessEventsEnabled) {
    [self.codelessIndexer enable];

    if (!self.eventBindingManager) {
      self.eventBindingManager = [[FBSDKEventBindingManager alloc] initWithSwizzler:self.swizzler
                                                                        eventLogger:self];
    }

    if (self.internalUtility.isUnity) {
      [self sendEventBindingsToUnity];
    } else {
      FBSDKEventBindingManager *manager = [[FBSDKEventBindingManager alloc] initWithSwizzler:self.swizzler
                                                                                 eventLogger:self];
      [self.eventBindingManager updateBindings:[manager parseArray:self.serverConfiguration.eventBindings]];
    }
  }
}

#endif

// app events can use a server configuration up to 24 hours old to minimize network traffic.
- (void)fetchServerConfiguration:(FBSDKCodeBlock)callback
{
  [self.appEventsConfigurationProvider loadAppEventsConfigurationWithBlock:^{
    [self.serverConfigurationProvider loadServerConfigurationWithCompletionBlock:^(FBSDKServerConfiguration *serverConfiguration, NSError *error) {
      self.serverConfiguration = serverConfiguration;

      if ([self.settings isAutoLogAppEventsEnabled] && self.serverConfiguration.implicitPurchaseLoggingEnabled) {
        [self.featureChecker checkFeature:FBSDKFeatureIAPLoggingSK2 completionBlock:^(BOOL enabled) {
          if (enabled) {
            [self.transactionObserver startObserving];
            [self.featureChecker checkFeature:FBSDKFeatureIOSManualImplicitPurchaseDedupe completionBlock:^(BOOL dedupeEnabled) {
              if (dedupeEnabled) {
                [self.iapDedupeProcessor enable];
                [self.iapDedupeProcessor processSavedEvents];
              } else {
                [self.iapDedupeProcessor disable];
              }
            }];
          } else {
            [self.iapDedupeProcessor disable];
            [self.transactionObserver stopObserving];
            [self.paymentObserver startObservingTransactions];
          }
        }];
      } else {
        [self.iapTransactionCache setHasRestoredPurchases:YES];
        [self.iapTransactionCache setNewCandidatesDate:[NSDate date]];
        [self.iapDedupeProcessor disable];
        [self.paymentObserver stopObservingTransactions];
        [self.transactionObserver stopObserving];
      }
      [self.featureChecker checkFeature:FBSDKFeatureRestrictiveDataFiltering completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self.restrictiveDataFilterParameterProcessor enable];
        }
      }];
      [self.featureChecker checkFeature:FBSDKFeatureEventDeactivation completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self.eventDeactivationParameterProcessor enable];
        }
      }];
      [self.featureChecker checkFeature:FBSDKFeatureProtectedMode completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self.protectedModeManager enable];
        }
      }];
      [self.featureChecker checkFeature:FBSDKFeatureBannedParamFiltering completionBlock:^(BOOL enabled) {
              if (enabled) {
               [self.bannedParamsManager enable];
              }
            }];
      [self.featureChecker checkFeature:FBSDKFeatureStdParamEnforcement completionBlock:^(BOOL enabled) {
              if (enabled) {
               [self.stdParamEnforcementManager enable];
              }
            }];
      [self.featureChecker checkFeature:FBSDKFeatureMACARuleMatching completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self.macaRuleMatchingManager enable];
        }
      }];
      [self.featureChecker checkFeature:FBSDKFeatureVVP completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self.vvpConfigManager enable];
        }
      }];
      [self.featureChecker checkFeature:FBSDKFeatureBlocklistEvents completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self.blocklistEventsManager enable];
        }
      }];
      [self.featureChecker checkFeature:FBSDKFeatureFilterRedactedEvents completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self.redactedEventsManager enable];
        }
      }];
      [self.featureChecker checkFeature:FBSDKFeatureFilterSensitiveParams completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self.sensitiveParamsManager enable];
        }
      }];
      __weak FBSDKAppEvents *weakSelf = self;
      [self.featureChecker checkFeature:FBSDKFeatureATELogging completionBlock:^(BOOL enabled) {
        if (enabled) {
          [weakSelf publishATE];
        }
      }];
      [self.featureChecker checkFeature:FBSDKFeatureAppEventsCloudbridge completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self.capiReporter enable];
        }
      }];
    #if !TARGET_OS_TV
      [self.featureChecker checkFeature:FBSDKFeatureCodelessEvents completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self enableCodelessEvents];
        }
      }];
      [self.featureChecker checkFeature:FBSDKFeatureAAM completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self.metadataIndexer enable];
        }
      }];
      [self.featureChecker checkFeature:FBSDKFeaturePrivacyProtection completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self.onDeviceMLModelManager enable];
        }
      }];
      if ([self.settings isSKAdNetworkReportEnabled]) {
        [self.featureChecker checkFeature:FBSDKFeatureSKAdNetwork completionBlock:^(BOOL SKAdNetworkEnabled) {
          if (SKAdNetworkEnabled) {
            if (![self.primaryDataStore fb_boolForKey:@"com.facebook.sdk:FBSDKIsSkAdNetworkInstallReported"]) {
              if (@available(iOS 15.4, *)) {
                [SKAdNetwork updatePostbackConversionValue:0 completionHandler:nil];
              } else {
                // Fallback on earlier versions
                [SKAdNetwork registerAppForAdNetworkAttribution];
              }
              [self.primaryDataStore fb_setBool:true forKey:@"com.facebook.sdk:FBSDKIsSkAdNetworkInstallReported"];
            }
            [self.featureChecker checkFeature:FBSDKFeatureSKAdNetworkConversionValue completionBlock:^(BOOL SKAdNetworkConversionValueEnabled) {
              if (SKAdNetworkConversionValueEnabled) {
                if ([self.featureChecker isEnabled :FBSDKFeatureSKAdNetworkV4]) {
                                     [self.skAdNetworkReporterV2 enable];
                                   }
                                   else {
                                     [self.skAdNetworkReporter enable];
                                   }
              }
            }];
          }
        }];
      }
      [self.featureChecker checkFeature:FBSDKFeatureAEM completionBlock:^(BOOL AEMEnabled) {
        if (AEMEnabled) {
          [self.aemReporter enable];
          [self.aemReporter setCatalogMatchingEnabled:[self.featureChecker isEnabled:FBSDKFeatureAEMCatalogMatching]];
          [self.aemReporter setConversionFilteringEnabled:[self.featureChecker isEnabled:FBSDKFeatureAEMConversionFiltering]];
          [self.aemReporter setAdvertiserRuleMatchInServerEnabled:[self.featureChecker isEnabled:FBSDKFeatureAEMAdvertiserRuleMatchInServer]];
        }
      }];
    #endif
      if (callback) {
        callback();
      }
    }];
  }];
}

- (nullable NSDictionary<NSString *, id> *)addImplicitPurchaseParameters:(nullable NSDictionary<FBSDKAppOperationalDataType, NSDictionary<NSString *, id> *> *)operationalParameters{
  NSMutableDictionary<FBSDKAppOperationalDataType, NSDictionary<NSString *, id> *> *params = [operationalParameters mutableCopy];
  if (params == nil) {
    params = [[NSMutableDictionary alloc] initWithDictionary:@{}];
  }
  NSMutableDictionary<NSString *, id> *iapParameters = [[params objectForKey:FBSDKAppOperationalDataTypeIAPParameters] mutableCopy];
  if (iapParameters == nil) {
    iapParameters = [[NSMutableDictionary alloc] initWithDictionary:@{}];
  }
  if (self.serverConfiguration) {
    [FBSDKTypeUtility dictionary:iapParameters setObject:self.serverConfiguration.implicitPurchaseLoggingEnabled ? @"1" : @"0" forKey:@"is_implicit_purchase_logging_enabled"];
    [FBSDKTypeUtility dictionary:iapParameters setObject:[self.settings isAutoLogAppEventsEnabled] ? @"1" : @"0" forKey:@"is_autolog_app_events_enabled"];
  }
  if (iapParameters != nil && iapParameters.count > 0) {
    [FBSDKTypeUtility dictionary:params setObject:iapParameters forKey:FBSDKAppOperationalDataTypeIAPParameters];
  }
  return [params copy];
}

- (void)    logEvent:(FBSDKAppEventName)eventName
          valueToSum:(NSNumber *)valueToSum
          parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
  isImplicitlyLogged:(BOOL)isImplicitlyLogged
         accessToken:(FBSDKAccessToken *)accessToken
{
  if (!isImplicitlyLogged && self.iapDedupeProcessor.isEnabled && [self.iapDedupeProcessor shouldDedupeEvent:eventName valueToSum:valueToSum parameters:parameters]) {
    [self.iapDedupeProcessor processManualEvent:eventName
                                     valueToSum:valueToSum
                                     parameters:parameters
                                    accessToken:accessToken
                          operationalParameters:nil];
  } else {
    [self doLogEvent:eventName
          valueToSum:valueToSum
          parameters:parameters
  isImplicitlyLogged:isImplicitlyLogged
         accessToken:accessToken
operationalParameters:nil];
    // Unless the behavior is set to only allow explicit flushing, we go ahead and flush, since purchase events
    // are relatively rare and relatively high value and worth getting across on wire right away.
    if (eventName == FBSDKAppEventNamePurchased && self.flushBehavior != FBSDKAppEventsFlushBehaviorExplicitOnly) {
      [self flushForReason:FBSDKAppEventsFlushReasonEagerlyFlushingEvent];
    }
  }
}

- (void)    doLogEvent:(FBSDKAppEventName)eventName
          valueToSum:(nullable NSNumber *)valueToSum
          parameters:(nullable NSDictionary<FBSDKAppEventParameterName, id> *)parameters
  isImplicitlyLogged:(BOOL)isImplicitlyLogged
         accessToken:(nullable FBSDKAccessToken *)accessToken
 operationalParameters:(nullable NSDictionary<FBSDKAppOperationalDataType, NSDictionary<NSString *, id> *> *)operationalParameters
{
  [self validateConfiguration];

  // Kill events if kill-switch is enabled
  if (!self.gateKeeperManager) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                           logEntry:@"FBSDKAppEvents: Cannot log app events before the SDK is initialized."];
    return;
  } else if ([self.gateKeeperManager boolForKey:FBSDKGateKeeperAppEventsKillSwitch
                                   defaultValue:NO]) {
    NSString *message = [NSString stringWithFormat:@"FBSDKAppEvents: KillSwitch is enabled and fail to log app event: %@", eventName];
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                           logEntry:message];
    return;
  }
#if !TARGET_OS_TV
  // Update conversion value for SKAdNetwork if needed
  [self.featureChecker checkFeature:FBSDKFeatureSKAdNetworkV4 completionBlock:^(BOOL enabled) {
    if (enabled) {
      [self.skAdNetworkReporterV2 recordAndUpdateEvent:eventName
                                            currency:[FBSDKTypeUtility dictionary:parameters objectForKey:FBSDKAppEventParameterNameCurrency ofType:NSString.class]
                                               value:valueToSum
                                          parameters:parameters];
    }
    else {
      [self.skAdNetworkReporter recordAndUpdateEvent:eventName
                                            currency:[FBSDKTypeUtility dictionary:parameters objectForKey:FBSDKAppEventParameterNameCurrency ofType:NSString.class]
                                               value:valueToSum
                                          parameters:parameters];
    }
  }];
  // Update conversion value for AEM if needed
  [self.aemReporter recordAndUpdateEvent:eventName
                                currency:[FBSDKTypeUtility dictionary:parameters objectForKey:FBSDKAppEventParameterNameCurrency ofType:NSString.class]
                                   value:valueToSum
                              parameters:parameters];
#endif

  if (self.appEventsUtility.shouldDropAppEvents) {
    return;
  }

  if (isImplicitlyLogged && self.serverConfiguration && !self.serverConfiguration.isImplicitLoggingSupported) {
    return;
  }

  operationalParameters = [self addImplicitPurchaseParameters:operationalParameters];

  BOOL isProtectedModeApplied = (self.protectedModeManager && [FBSDKProtectedModeManager isProtectedModeAppliedWithParameters:parameters]);
  if (!isProtectedModeApplied && self.sensitiveParamsManager) {
    @try {
      parameters = [self.sensitiveParamsManager processParameters:parameters eventName:eventName];
    } @catch(NSException *exception) {
      [self.logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                                   logEntry:@"FBSDKAppEvents: caught exception while processing sensitiveParamsManager."];
    }
  }

  // remove banned parameters
    if (self.bannedParamsManager) {
      @try {
        parameters = [self.bannedParamsManager processParameters:parameters event:eventName?:@""];
      } @catch(NSException *exception) {
        [self.logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                               logEntry:@"FBSDKAppEvents: caght exception while processing bannedParamsManager."];
      }
    }

  if (self.macaRuleMatchingManager) {
    @try {
        parameters = [self.macaRuleMatchingManager processParameters:parameters event:eventName?:@""];
    } @catch(NSException *exception) {}
  }

  // Schematize certain params
  if (self.stdParamEnforcementManager) {
    @try {
      parameters = [self.stdParamEnforcementManager processParameters:parameters event:eventName?:@""];
    } @catch(NSException *exception) {
        [self.logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                                     logEntry:@"FBSDKAppEvents: caght exception while processing stdParamEnforcementManager."];
    }
  }

  if (!isImplicitlyLogged && !g_explicitEventsLoggedYet) {
    g_explicitEventsLoggedYet = YES;
  }
  __block BOOL failed = ![self.appEventsUtility validateIdentifier:eventName];

  // Make sure parameter dictionary is well formed.  Log and exit if not.
  [FBSDKTypeUtility dictionary:parameters enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
    if (![key isKindOfClass:NSString.class]) {
      [self.appEventsUtility logAndNotify:[NSString stringWithFormat:@"The keys in the parameters must be NSStrings, '%@' is not.", key]];
      failed = YES;
    }
    if (![self.appEventsUtility validateIdentifier:key]) {
      failed = YES;
    }
    if (![obj isKindOfClass:NSString.class] && ![obj isKindOfClass:NSNumber.class]) {
      [self.appEventsUtility logAndNotify:[NSString stringWithFormat:@"The values in the parameters dictionary must be NSStrings or NSNumbers, '%@' is not.", obj]];
      failed = YES;
    }
  }];

  if (failed) {
    return;
  }
  // Filter out deactivated params
  if (self.eventDeactivationParameterProcessor) {
    parameters = [self.eventDeactivationParameterProcessor processParameters:parameters eventName:eventName];
  }

#if !TARGET_OS_TV
  // Filter out restrictive data with on-device ML
  if (self.onDeviceMLModelManager.integrityParametersProcessor) {
    parameters = [self.onDeviceMLModelManager.integrityParametersProcessor processParameters:parameters eventName:eventName];
  }
#endif
  // Filter out restrictive keys
  parameters = [self.restrictiveDataFilterParameterProcessor processParameters:parameters
                                                                     eventName:eventName];

  // Filter out non-standard params
  if (self.protectedModeManager) {
    @try {
        parameters = [self.protectedModeManager processParameters:parameters eventName:eventName];
    } @catch(NSException *exception) {}
  }

  // VPPA Video Viewing Protections — must run AFTER ProtectedMode so the
  // `vvp` / `vvp_md` tags survive ProtectedMode's standard-params filter
  // (those keys are added to ProtectedMode's allowlist for that reason).
  if (self.vvpConfigManager) {
    @try {
      parameters = [self.vvpConfigManager processParameters:parameters event:eventName ?: @""];
    } @catch (NSException *exception) {
      [self.logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                             logEntry:@"FBSDKAppEvents: caught exception while processing vvpConfigManager."];
    }
  }


  NSMutableDictionary<FBSDKAppEventParameterName, id> *eventDictionary = [NSMutableDictionary dictionaryWithDictionary:parameters ?: @{}];
  [FBSDKTypeUtility dictionary:eventDictionary setObject:eventName forKey:FBSDKAppEventParameterNameEventName];
  if (!eventDictionary[FBSDKAppEventParameterNameLogTime]) {
    [FBSDKTypeUtility dictionary:eventDictionary setObject:@(self.appEventsUtility.unixTimeNow) forKey:FBSDKAppEventParameterNameLogTime];
  }
  if (valueToSum != nil) {
    [FBSDKTypeUtility dictionary:eventDictionary setObject:valueToSum forKey:@"_valueToSum"];
  }
  if (isImplicitlyLogged) {
    [FBSDKTypeUtility dictionary:eventDictionary setObject:@"1" forKey:FBSDKAppEventParameterNameImplicitlyLogged];
  }

  NSString *currentViewControllerName;
  UIApplicationState applicationState;
  if (NSThread.isMainThread) {
    // We only collect the view controller when on the main thread, as the behavior off
    // the main thread is unpredictable.  Besides, UI state for off-main-thread computations
    // isn't really relevant anyhow.
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // @lint-ignore FBOBJCDISCOURAGEDFUNCTION
    UIViewController *vc = UIApplication.sharedApplication.keyWindow.rootViewController;
    #pragma clang diagnostic pop
    vc = vc.presentedViewController ?: vc;
    if (vc) {
      currentViewControllerName = [vc.class description];
    } else {
      currentViewControllerName = @"no_ui";
    }
    applicationState = UIApplication.sharedApplication.applicationState;
  } else {
    currentViewControllerName = @"off_thread";
    applicationState = self.applicationState;
  }
  [FBSDKTypeUtility dictionary:eventDictionary setObject:currentViewControllerName forKey:@"_ui"];

  NSString *screenTitle = [FBSDKScreenTitleObserver shared].currentScreenTitle;
  if (screenTitle.length > 0) {
    [FBSDKTypeUtility dictionary:eventDictionary setObject:screenTitle forKey:FBSDKAppEventParameterNameScreenTitle];
  }

  // Attribute the event to the app link that most recently brought the user into the app, or that
  // the app most recently sent the user out through.
  FBSDKAppLinkURLCache *appLinkURLCache = FBSDKAppLinkURLCache.shared;
  NSString *inboundURL = appLinkURLCache.inboundURL;
  if (inboundURL.length > 0) {
    [FBSDKTypeUtility dictionary:eventDictionary setObject:inboundURL forKey:FBSDKAppEventParameterNameInboundURL];
  }
  NSString *outboundURL = appLinkURLCache.outboundURL;
  if (outboundURL.length > 0) {
    [FBSDKTypeUtility dictionary:eventDictionary setObject:outboundURL forKey:FBSDKAppEventParameterNameOutboundURL];
  }

  if (applicationState == UIApplicationStateBackground) {
    [FBSDKTypeUtility dictionary:eventDictionary setObject:@"1" forKey:FBSDKAppEventParameterNameInBackground];
  }

  NSString *tokenString = [self.appEventsUtility tokenStringToUseFor:accessToken
                                                loggingOverrideAppID:self.loggingOverrideAppID];
  NSString *appID = [self appID];

  @synchronized(self) {
    if (!self.appEventsState) {
      self.appEventsState = [self.appEventsStateProvider createStateWithToken:tokenString appID:appID];
    } else if (![self.appEventsState isCompatibleWithTokenString:tokenString appID:appID]) {
      if (self.flushBehavior == FBSDKAppEventsFlushBehaviorExplicitOnly) {
        [self.appEventsStateStore persistAppEventsData:self.appEventsState];
      } else {
        [self flushForReason:FBSDKAppEventsFlushReasonSessionChange];
      }
      self.appEventsState = [self.appEventsStateProvider createStateWithToken:tokenString appID:appID];
    }

    [self.appEventsState addEvent:eventDictionary isImplicit:isImplicitlyLogged withOperationalParameters:operationalParameters];
    if (!isImplicitlyLogged) {
      NSString *message = [NSString stringWithFormat:@"FBSDKAppEvents: Recording event @ %f: %@",
                           [self.appEventsUtility unixTimeNow],
                           eventDictionary];
      [self.logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                             logEntry:message];
    }

    [self checkPersistedEvents];

    if (nil != [self.appEventsUtility getCampaignIDs]) {
       [self flushForReason:FBSDKAppEventsFlushReasonEagerlyFlushingEvent];
       return;
    }

    if (self.appEventsState.events.count > NUM_LOG_EVENTS_TO_TRY_TO_FLUSH_AFTER
        && self.flushBehavior != FBSDKAppEventsFlushBehaviorExplicitOnly) {
      [self flushForReason:FBSDKAppEventsFlushReasonEventThreshold];
    }
  }
}

// this fetches persisted event states.
// for those matching the currently tracked events, add it.
// otherwise, either flush (if not explicitonly behavior) or persist them back.
- (void)checkPersistedEvents
{
  NSArray<FBSDKAppEventsState *> *existingEventsStates = [self.appEventsStateStore retrievePersistedAppEventsStates];
  if (existingEventsStates.count == 0) {
    return;
  }
  FBSDKAppEventsState *matchingEventsPreviouslySaved = nil;
  // reduce lock time by creating a new FBSDKAppEventsState to collect matching persisted events.
  @synchronized(self) {
    if (self.appEventsState) {
      matchingEventsPreviouslySaved = [self.appEventsStateProvider createStateWithToken:self.appEventsState.tokenString
                                                                                  appID:self.appEventsState.appID];
    }
  }
  for (FBSDKAppEventsState *saved in existingEventsStates) {
    if ([saved isCompatibleWithAppEventsState:matchingEventsPreviouslySaved]) {
      [matchingEventsPreviouslySaved addEventsFromAppEventState:saved];
    } else {
      if (self.flushBehavior == FBSDKAppEventsFlushBehaviorExplicitOnly) {
        [self.appEventsStateStore persistAppEventsData:saved];
      } else {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self flushOnMainQueue:saved forReason:FBSDKAppEventsFlushReasonPersistedEvents];
        });
      }
    }
  }
  if (matchingEventsPreviouslySaved.events.count > 0) {
    @synchronized(self) {
      if ([self.appEventsState isCompatibleWithAppEventsState:matchingEventsPreviouslySaved]) {
        [self.appEventsState addEventsFromAppEventState:matchingEventsPreviouslySaved];
      }
    }
  }
}

- (void)flushOnMainQueue:(FBSDKAppEventsState *)appEventsState
               forReason:(FBSDKAppEventsFlushReason)reason
{
  if (appEventsState.events.count == 0) {
    return;
  }

  if (appEventsState.appID.length == 0) {
    [self.logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors logEntry:@"Missing [FBSDKAppEvents appEventsState.appID] for [FBSDKAppEvents flushOnMainQueue:]"];
    return;
  }

  [self.appEventsUtility ensureOnMainThread:NSStringFromSelector(_cmd) className:NSStringFromClass(self.class)];

  [self fetchServerConfiguration:^(void) {
    if ([self.appEventsUtility shouldDropAppEvents]) {
      return;
    }
    NSString *receipt_data = appEventsState.extractReceiptData;
    const BOOL shouldIncludeImplicitEvents = (self.serverConfiguration.implicitLoggingEnabled && self.settings.isAutoLogAppEventsEnabled);
    NSDictionary<NSString *, id> *appEventsData = [appEventsState JSONStringForEventsAndOperationalParametersIncludingImplicitEvents:shouldIncludeImplicitEvents];
    NSString *encodedEvents = [appEventsData objectForKey:@"custom_events"];
    NSString *encodedOperationalData = [appEventsData objectForKey:@"operational_parameters"];
    if (!encodedEvents || appEventsState.events.count == 0) {
      [self.logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                             logEntry:@"FBSDKAppEvents: Flushing skipped - no events after removing implicitly logged ones.\n"];
      return;
    }
    NSMutableDictionary<NSString *, NSString *> *postParameters = [self.appEventsUtility
                                                                   activityParametersDictionaryForEvent:@"CUSTOM_APP_EVENTS"
                                                                   shouldAccessAdvertisingID:self.serverConfiguration.advertisingIDEnabled
                                                                   userID:self.userID
                                                                   userData:[self getUserData]];
    NSInteger length = receipt_data.length;
    if (length > 0) {
      [FBSDKTypeUtility dictionary:postParameters setObject:receipt_data forKey:@"receipt_data"];
    }

    [FBSDKTypeUtility dictionary:postParameters setObject:encodedEvents forKey:@"custom_events"];
    if ([self.featureChecker isEnabled:FBSDKFeatureIAPLoggingSK2] && encodedOperationalData != nil) {
      [FBSDKTypeUtility dictionary:postParameters setObject:encodedOperationalData forKey:@"operational_parameters"];
    }
    if (appEventsState.numSkipped > 0) {
      [FBSDKTypeUtility dictionary:postParameters setObject:[NSString stringWithFormat:@"%lu", (unsigned long)appEventsState.numSkipped] forKey:@"num_skipped_events"];
    }
    if (self.pushNotificationsDeviceTokenString) {
      [FBSDKTypeUtility dictionary:postParameters setObject:self.pushNotificationsDeviceTokenString forKey:FBSDKActivitesParameterPushDeviceToken];
    }

    NSString *loggingEntry = nil;
    if ([self.settings isLoggingBehaviorEnabled:FBSDKLoggingBehaviorAppEvents]) {
      NSData *prettyJSONData = [FBSDKTypeUtility dataWithJSONObject:appEventsState.events
                                                            options:NSJSONWritingPrettyPrinted
                                                              error:NULL];
      NSString *prettyPrintedJsonEvents = [[NSString alloc] initWithData:prettyJSONData
                                                                encoding:NSUTF8StringEncoding];
      // Remove this param -- just an encoding of the events which we pretty print later.
      NSMutableDictionary<NSString *, id> *paramsForPrinting = [postParameters mutableCopy];
      [paramsForPrinting removeObjectForKey:@"custom_events_file"];

      loggingEntry = [NSString stringWithFormat:@"FBSDKAppEvents: Flushed @ %f, %lu events due to '%@' - %@\nEvents: %@",
                      [self.appEventsUtility unixTimeNow],
                      (unsigned long)appEventsState.events.count,
                      [self.appEventsUtility flushReasonToString:reason],
                      paramsForPrinting,
                      prettyPrintedJsonEvents];
    }
    [self.capiReporter recordEvent:postParameters];
    id<FBSDKGraphRequest> request = [self.graphRequestFactory createGraphRequestWithGraphPath:[NSString stringWithFormat:@"%@/activities", appEventsState.appID]
                                                                                   parameters:postParameters
                                                                                  tokenString:appEventsState.tokenString
                                                                                   HTTPMethod:FBSDKHTTPMethodPOST
                                                                                        flags:FBSDKGraphRequestFlagDoNotInvalidateTokenOnError | FBSDKGraphRequestFlagDisableErrorRecovery
                                                                                 forAppEvents:YES
                                                            useAlternativeDefaultDomainPrefix:NO];
    [request startWithCompletion:^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *error) {
      [self handleActivitiesPostCompletion:error
                              loggingEntry:loggingEntry
                            appEventsState:(FBSDKAppEventsState *)appEventsState];
    }];
  }];
}

- (void)handleActivitiesPostCompletion:(NSError *)error
                          loggingEntry:(NSString *)loggingEntry
                        appEventsState:(FBSDKAppEventsState *)appEventsState
{
  typedef NS_ENUM(NSUInteger, FBSDKAppEventsFlushResult) {
    FlushResultSuccess,
    FlushResultServerError,
    FlushResultNoConnectivity,
  };

  [self.appEventsUtility ensureOnMainThread:NSStringFromSelector(_cmd) className:NSStringFromClass(self.class)];

  FBSDKAppEventsFlushResult flushResult = FlushResultSuccess;
  if (error) {
    NSInteger errorCode = [error.userInfo[FBSDKGraphRequestErrorHTTPStatusCodeKey] integerValue];

    // We interpret a 400 coming back from FBRequestConnection as a server error due to improper data being
    // sent down.  Otherwise we assume no connectivity, or another condition where we could treat it as no connectivity.
    // Adding 404 as having wrong/missing appID results in 404 and that is not a connectivity issue
    flushResult = (errorCode == 400 || errorCode == 404) ? FlushResultServerError : FlushResultNoConnectivity;
  }

  if (flushResult == FlushResultServerError) {
    // Only log events that developer can do something with (i.e., if parameters are incorrect).
    // as opposed to cases where the token is bad.
    if ([error.userInfo[FBSDKGraphRequestErrorKey] unsignedIntegerValue] == FBSDKGraphRequestErrorOther) {
      NSString *message = [NSString stringWithFormat:@"Failed to send AppEvents: %@", error];
      [self.appEventsUtility logAndNotify:message allowLogAsDeveloperError:!appEventsState.areAllEventsImplicit];
    }
  } else if (flushResult == FlushResultNoConnectivity) {
    @synchronized(self) {
      if ([appEventsState isCompatibleWithAppEventsState:self.appEventsState]) {
        [self.appEventsState addEventsFromAppEventState:appEventsState];
      } else {
        // flush failed due to connectivity. Persist to be tried again later.
        [self.appEventsStateStore persistAppEventsData:appEventsState];
      }
    }
  }

  NSString *resultString = @"<unknown>";
  switch (flushResult) {
    case FlushResultSuccess:
      resultString = @"Success";
      break;

    case FlushResultNoConnectivity:
      resultString = @"No Connectivity";
      break;

    case FlushResultServerError:
      resultString = [NSString stringWithFormat:@"Server Error - %@", error.description];
      break;
  }

  NSString *message = [NSString stringWithFormat:@"%@\nFlush Result : %@", loggingEntry, resultString];
  [self.logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                         logEntry:message];
}

- (void)flushTimerFired:(id)arg
{
  [self.appEventsUtility ensureOnMainThread:NSStringFromSelector(_cmd) className:NSStringFromClass(self.class)];
  if (self.flushBehavior != FBSDKAppEventsFlushBehaviorExplicitOnly) {
    [self flushForReason:FBSDKAppEventsFlushReasonTimer];
  }
}

- (void)applicationDidBecomeActive
{
  [self.appEventsUtility ensureOnMainThread:NSStringFromSelector(_cmd) className:NSStringFromClass(self.class)];

  // This must happen here to avoid a race condition with the shared `Settings` object.
  [self fetchServerConfiguration:nil];

  [self checkPersistedEvents];

  // Restore time spent data, indicating that we're not being called from "activateApp".
  [self.timeSpentRecorder restore:NO];
}

- (void)applicationMovingFromActiveState
{
  // When moving from active state, we don't have time to wait for the result of a flush, so
  // just persist events to storage, and we'll process them at the next activation.
  FBSDKAppEventsState *copy = nil;
  @synchronized(self) {
    copy = [self.appEventsState copy];
    self.appEventsState = nil;
  }
  if (copy) {
    [self.appEventsStateStore persistAppEventsData:copy];
  }
  [self.timeSpentRecorder suspend];
}

- (void)applicationTerminating
{
  NSString *appID = [self appID];
  if (appID) {
    NSString *lastAttributionPingString = [NSString stringWithFormat:@"com.facebook.sdk:lastAttributionPing%@", appID];
    NSString *lastInstallResponseKey = [NSString stringWithFormat:@"com.facebook.sdk:lastInstallResponse%@", appID];
    if (nil == [self.primaryDataStore fb_objectForKey:lastInstallResponseKey]) {
      [self.primaryDataStore fb_removeObjectForKey:lastAttributionPingString];
    }
  }
  [self applicationMovingFromActiveState];
}

- (void)checkForAutologgedPurchases
{
#if DEBUG
  if ([self.settings isAutoLogAppEventsEnabled] && self.serverConfiguration.implicitPurchaseLoggingEnabled && !g_hasLoggedManualImplicitLoggingWarning) {
    NSString *message = @"You are manually logging purchase events, but you also have auto-logging turned on. "
    "If you are manually logging In-App Purchases, we recommend just choosing one set up to avoid duplicate logging";
    NSLog(@"%@%@", @"<Warning>: ", message);
    g_hasLoggedManualImplicitLoggingWarning = YES;
  }
#endif
}

#pragma mark - Configuration Validation

- (void)validateConfiguration
{
#if DEBUG
  if (!self.isConfigured) {
    static NSString *const reason = @"As of v9.0, you must initialize the SDK prior to calling any methods or setting any properties. "
    "You can do this by calling `FBSDKApplicationDelegate`'s `application:didFinishLaunchingWithOptions:` method. "
    "Learn more: https://developers.facebook.com/docs/ios/getting-started"
    "If no `UIApplication` is available you can use `FBSDKApplicationDelegate`'s `initializeSDK` method.";
    @throw [NSException exceptionWithName:@"InvalidOperationException" reason:reason userInfo:nil];
  }
#endif
}

#pragma mark - Custom Audience

- (nullable id<FBSDKGraphRequest>)requestForCustomAudienceThirdPartyIDWithAccessToken:(nullable FBSDKAccessToken *)accessToken
{
  [self validateConfiguration];

  if (accessToken == nil && (![[FBSDKDomainHandler sharedInstance] isDomainHandlingEnabled] || self.settings.isAdvertiserTrackingEnabled)) {
    accessToken = FBSDKAccessToken.currentAccessToken;
  }

  // Rules for how we use the attribution ID / advertiser ID for an 'custom_audience_third_party_id' Graph API request
  // 1) if the OS tells us that the user has Limited Ad Tracking, then just don't send, and return a nil in the token.
  // 2) if the app has set 'limitEventAndDataUsage', this effectively implies that app-initiated ad targeting shouldn't happen,
  // so use that data here to return nil as well.
  // 3) if we have a user session token, then no need to send attribution ID / advertiser ID back as the udid parameter
  // 4) otherwise, send back the udid parameter.
  if (self.settings.isEventDataUsageLimited) {
    return nil;
  }
  if ([[FBSDKDomainHandler sharedInstance] isDomainHandlingEnabled]) {
    if (![self.settings isAdvertiserTrackingEnabled]) {
      return nil;
    }
  } else if (self.settings.advertisingTrackingStatus == FBSDKAdvertisingTrackingDisallowed) {
    return nil;
  }

  NSString *tokenString = [self.appEventsUtility tokenStringToUseFor:accessToken
                                                loggingOverrideAppID:self.loggingOverrideAppID];
  NSString *udid = nil;
  if (!accessToken) {
    // We don't have a logged in user, so we need some form of udid representation. Prefer advertiser ID if
    // available. Note that this function only makes sense to be called in the context of advertising.
    udid = self.advertiserIDProvider.advertiserID;
    if (!udid) {
      // No udid, and no user token.  No point in making the request.
      return nil;
    }
  }

  NSDictionary<NSString *, id> *parameters = @{};
  if (udid) {
    parameters = @{ @"udid" : udid };
  }

  NSString *graphPath = [NSString stringWithFormat:@"%@/custom_audience_third_party_id", self.appID];

  id<FBSDKGraphRequest> request = [self.graphRequestFactory createGraphRequestWithGraphPath:graphPath
                                                                                 parameters:parameters
                                                                                tokenString:tokenString
                                                                                 HTTPMethod:FBSDKHTTPMethodGET
                                                                                      flags:FBSDKGraphRequestFlagDoNotInvalidateTokenOnError | FBSDKGraphRequestFlagDisableErrorRecovery
                                                          useAlternativeDefaultDomainPrefix:NO];
  return request;
}

#pragma clang diagnostic pop

#pragma mark - Testability

#if DEBUG

- (void)reset
{
  self.isConfigured = NO;
  self.applicationState = UIApplicationStateInactive;

  self.gateKeeperManager = nil;
  self.appEventsConfigurationProvider = nil;
  self.serverConfigurationProvider = nil;
  self.graphRequestFactory = nil;
  self.featureChecker = nil;
  self.primaryDataStore = nil;
  self.logger = nil;
  self.settings = nil;
  self.paymentObserver = nil;
  self.timeSpentRecorder = nil;
  self.appEventsStateStore = nil;
  self.eventDeactivationParameterProcessor = nil;
  self.restrictiveDataFilterParameterProcessor = nil;
  self.atePublisher = nil;
  self.atePublisherFactory = nil;
  self.appEventsStateProvider = nil;
  self.advertiserIDProvider = nil;
  self.userDataStore = nil;
  self.appEventsUtility = nil;
  self.internalUtility = nil;
  self.protectedModeManager = nil;
  self.bannedParamsManager = nil;
  self.stdParamEnforcementManager = nil;
  self.macaRuleMatchingManager = nil;
  self.vvpConfigManager = nil;
  self.blocklistEventsManager = nil;
  self.redactedEventsManager = nil;
  self.sensitiveParamsManager = nil;
  self.transactionObserver = nil;
  // The actual setter on here has a check to see if the SDK is initialized
  // This is not a useful check for tests so we can just reset the underlying
  // static var.
  @synchronized (self) {
    g_overrideAppID = nil;
  }

#if !TARGET_OS_TV
  self.onDeviceMLModelManager = nil;
  self.metadataIndexer = nil;
  self.skAdNetworkReporter = nil;
  self.skAdNetworkReporterV2 = nil;
  self.codelessIndexer = nil;
  self.swizzler = nil;
  self.eventBindingManager = nil;
  self.aemReporter = nil;
#endif
}

+ (void)setShared:(FBSDKAppEvents *)appEvents
{
  _shared = appEvents;
}

- (void)setFlushBehavior:(FBSDKAppEventsFlushBehavior)flushBehavior
{
  [self validateConfiguration];
  _flushBehavior = flushBehavior;
}

#endif

@end
