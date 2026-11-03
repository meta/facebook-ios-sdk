/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <FBSDKCoreKit/FBSDKCoreKit-Swift.h>
#import <FBSDKCoreKit_Basics/FBSDKCoreKit_Basics.h>
#import <objc/runtime.h>

#import "FBSDKGraphRequestFactory.h"
#import "FBSDKImageDownloader.h"
#import "FBSDKInternalUtility+Internal.h"
#import "FBSDKObjectDecoding.h"
#import "FBSDKServerConfiguration+Internal.h"
#import "FBSDKUnarchiverProvider.h"

#define FBSDK_SERVER_CONFIGURATION_USER_DEFAULTS_KEY @"com.facebook.sdk:serverConfiguration%@"

#define FBSDK_SERVER_CONFIGURATION_APP_EVENTS_FEATURES_FIELD @"app_events_feature_bitmask"
#define FBSDK_SERVER_CONFIGURATION_APP_NAME_FIELD @"name"
#define FBSDK_SERVER_CONFIGURATION_DEFAULT_SHARE_MODE_FIELD @"default_share_mode"
#define FBSDK_SERVER_CONFIGURATION_DIALOG_CONFIGURATIONS_FIELD @"ios_dialog_configs"
#define FBSDK_SERVER_CONFIGURATION_DIALOG_FLOWS_FIELD @"ios_sdk_dialog_flows"
#define FBSDK_SERVER_CONFIGURATION_ERROR_CONFIGURATION_FIELD @"ios_sdk_error_categories"
#define FBSDK_SERVER_CONFIGURATION_IMPLICIT_LOGGING_ENABLED_FIELD @"supports_implicit_sdk_logging"
#define FBSDK_SERVER_CONFIGURATION_LOGIN_TOOLTIP_ENABLED_FIELD @"gdpv4_nux_enabled"
#define FBSDK_SERVER_CONFIGURATION_LOGIN_TOOLTIP_TEXT_FIELD @"gdpv4_nux_content"
#define FBSDK_SERVER_CONFIGURATION_SESSION_TIMEOUT_FIELD @"app_events_session_timeout"
#define FBSDK_SERVER_CONFIGURATION_LOGGIN_TOKEN_FIELD @"logging_token"
#define FBSDK_SERVER_CONFIGURATION_SMART_LOGIN_OPTIONS_FIELD @"seamless_login"
#define FBSDK_SERVER_CONFIGURATION_SMART_LOGIN_BOOKMARK_ICON_URL_FIELD @"smart_login_bookmark_icon_url"
#define FBSDK_SERVER_CONFIGURATION_SMART_LOGIN_MENU_ICON_URL_FIELD @"smart_login_menu_icon_url"
#define FBSDK_SERVER_CONFIGURATION_UPDATE_MESSAGE_FIELD @"sdk_update_message"
#define FBSDK_SERVER_CONFIGURATION_EVENT_BINDINGS_FIELD  @"auto_event_mapping_ios"
#define FBSDK_SERVER_CONFIGURATION_RESTRICTIVE_PARAMS_FIELD @"restrictive_data_filter_params"
#define FBSDK_SERVER_CONFIGURATION_AAM_RULES_FIELD @"aam_rules"
#define FBSDK_SERVER_CONFIGURATION_SUGGESTED_EVENTS_SETTING_FIELD @"suggested_events_setting"
#define FBSDK_SERVER_CONFIGURATION_MONITORING_CONFIG_FIELD @"monitoringConfiguration"
#define FBSDK_SERVER_CONFIGURATION_PROTECTED_MODE_RULES_FIELD @"protected_mode_rules"
#define FBSDK_SERVER_CONFIGURATION_AUTO_LOG_APP_EVENTS_DEFAULT_FIELD @"auto_log_app_events_default"
#define FBSDK_SERVER_CONFIGURATION_AUTO_LOG_APP_EVENTS_ENABLED_FIELD @"auto_log_app_events_enabled"


@interface FBSDKServerConfigurationManager ()

@property (nonatomic) NSMutableArray<FBSDKServerConfigurationBlock> *completionBlocks;
@property (nonatomic) BOOL loadingServerConfiguration;
@property (nonatomic) FBSDKServerConfiguration *serverConfiguration;
@property (nonatomic) NSError *serverConfigurationError;
@property (nonatomic) NSDate *serverConfigurationErrorTimestamp;
@property (nonatomic, copy) NSString *serverConfigurationErrorAppID;
@property (nonatomic) BOOL requeryFinishedForAppStart;

@end

static const NSTimeInterval kTimeout = 4.0;

@implementation FBSDKServerConfigurationManager

#if DEBUG
static BOOL _printedUpdateMessage = NO;
#endif

typedef NS_OPTIONS(NSUInteger, FBSDKServerConfigurationManagerAppEventsFeatures)
{
  FBSDKServerConfigurationManagerAppEventsFeaturesNone = 0,
  FBSDKServerConfigurationManagerAppEventsFeaturesAdvertisingIDEnabled = 1 << 0,
  FBSDKServerConfigurationManagerAppEventsFeaturesImplicitPurchaseLoggingEnabled = 1 << 1,
  FBSDKServerConfigurationManagerAppEventsFeaturesCodelessEventsTriggerEnabled = 1 << 5,
  FBSDKServerConfigurationManagerAppEventsFeaturesUninstallTrackingEnabled = 1 << 7,
};

- (instancetype)init
{
  if ((self = [super init])) {
    _completionBlocks = [NSMutableArray new];
  }
  return self;
}

+ (FBSDKServerConfigurationManager *)shared
{
  static FBSDKServerConfigurationManager *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [FBSDKServerConfigurationManager new];
  });
  return instance;
}

- (void)configureWithGraphRequestFactory:(id<FBSDKGraphRequestFactory>)graphRequestFactory
           graphRequestConnectionFactory:(id<FBSDKGraphRequestConnectionFactory>)graphRequestConnectionFactory
           dialogConfigurationMapBuilder:(id<FBSDKDialogConfigurationMapBuilding>)dialogConfigurationMapBuilder
{
  self.graphRequestFactory = graphRequestFactory;
  self.graphRequestConnectionFactory = graphRequestConnectionFactory;
  self.dialogConfigurationMapBuilder = dialogConfigurationMapBuilder;
}

#pragma mark - Public

- (void)clearCache
{
  @synchronized(self) {
    self.serverConfiguration = nil;
    self.serverConfigurationError = nil;
    self.serverConfigurationErrorTimestamp = nil;
    self.serverConfigurationErrorAppID = nil;
  }
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSString *defaultsKey = [NSString stringWithFormat:FBSDK_SERVER_CONFIGURATION_USER_DEFAULTS_KEY, FBSDKSettings.sharedSettings.appID];
  [defaults removeObjectForKey:defaultsKey];
  [defaults synchronize];
}

- (FBSDKServerConfiguration *)cachedServerConfiguration
{
  NSString *appID = FBSDKSettings.sharedSettings.appID;
  @synchronized(self) {
    // load the server configuration if we don't have it already
    [self loadServerConfigurationWithCompletionBlock:nil];

    // use whatever configuration we have or the default
    return self.serverConfiguration ?: [FBSDKServerConfiguration defaultServerConfigurationForAppID:appID];
  }
}

- (void)loadServerConfigurationWithCompletionBlock:(nullable FBSDKServerConfigurationBlock)completionBlock
{
  @try {
    void (^loadBlock)(void) = nil;
    NSString *appID = FBSDKSettings.sharedSettings.appID;
    @synchronized(self) {
      // validate the cached configuration has the correct appID
      BOOL errorIsForDifferentAppID = self.serverConfigurationError
        && self.serverConfigurationErrorAppID != appID
        && ![self.serverConfigurationErrorAppID isEqualToString:appID];
      if ((self.serverConfiguration && ![self.serverConfiguration.appID isEqualToString:appID])
          || errorIsForDifferentAppID) {
        self.serverConfiguration = nil;
        self.serverConfigurationError = nil;
        self.serverConfigurationErrorTimestamp = nil;
        self.serverConfigurationErrorAppID = nil;
      }

      // load the configuration from NSUserDefaults
      if (!self.serverConfiguration) {
        // load the defaults
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *defaultsKey = [NSString stringWithFormat:FBSDK_SERVER_CONFIGURATION_USER_DEFAULTS_KEY, appID];
        NSData *data = [defaults objectForKey:defaultsKey];
        if ([data isKindOfClass:NSData.class]) {
          // decode the configuration
          id<FBSDKObjectDecoding> unarchiver = [FBSDKUnarchiverProvider createSecureUnarchiverFor:data];
          FBSDKServerConfiguration *serverConfiguration = nil;
          @try {
            serverConfiguration = [unarchiver decodeObjectOfClass:FBSDKServerConfiguration.class forKey:NSKeyedArchiveRootObjectKey];
          } @catch (NSException *ex) {
            // Ignore decoding error
          } @finally {
            // ensure that the configuration points to the current appID
            if ([serverConfiguration.appID isEqualToString:appID]) {
              self.serverConfiguration = serverConfiguration;
            }
          }
        }
      }

      if ([self _serverConfigurationErrorIsValidForAppID:appID]
          || (self.requeryFinishedForAppStart
              && self.serverConfiguration && [self _serverConfigurationTimestampIsValid:self.serverConfiguration.timestamp]
              && self.serverConfiguration.version >= FBSDKServerConfigurationVersion)) {
        // Reuse a valid configuration or the latest failure during the retry cooldown.
        loadBlock = [self _wrapperBlockForLoadBlock:completionBlock];
      } else {
        // hold onto the completion block
        [FBSDKTypeUtility array:self.completionBlocks addObject:[completionBlock copy]];

        // check if we are already loading
        if (!self.loadingServerConfiguration) {
          // load the configuration from the network
          self.loadingServerConfiguration = YES;
          id<FBSDKGraphRequest> request = [self requestToLoadServerConfiguration:appID];

          // start request with specified timeout instead of the default 180s
          id<FBSDKGraphRequestConnecting> requestConnection = [self.graphRequestConnectionFactory createGraphRequestConnection];
          requestConnection.timeout = kTimeout;
          [requestConnection addRequest:request completion:^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *error) {
            self.requeryFinishedForAppStart = YES;
            [self processLoadRequestResponse:result error:error appID:appID];
          }];
          [requestConnection start];
        }
      }
    }

    if (loadBlock) {
      loadBlock();
    }
  } @catch (NSException *exception) {}
}

#pragma mark - Internal

- (void)processLoadRequestResponse:(id)result error:(NSError *)error appID:(NSString *)appID
{
  @try {
    if (error) {
      [self _didProcessConfigurationFromNetwork:nil appID:appID error:error];
      return;
    }

    NSDictionary<NSString *, id> *resultDictionary = [FBSDKTypeUtility dictionaryValue:result];
    NSUInteger appEventsFeatures = [FBSDKTypeUtility unsignedIntegerValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_APP_EVENTS_FEATURES_FIELD]];
    BOOL advertisingIDEnabled = (appEventsFeatures & FBSDKServerConfigurationManagerAppEventsFeaturesAdvertisingIDEnabled) != 0;
    BOOL implicitPurchaseLoggingEnabled = (appEventsFeatures & FBSDKServerConfigurationManagerAppEventsFeaturesImplicitPurchaseLoggingEnabled) != 0;
    BOOL codelessEventsEnabled = (appEventsFeatures & FBSDKServerConfigurationManagerAppEventsFeaturesCodelessEventsTriggerEnabled) != 0;
    BOOL uninstallTrackingEnabled = (appEventsFeatures & FBSDKServerConfigurationManagerAppEventsFeaturesUninstallTrackingEnabled) != 0;
    NSString *appName = [FBSDKTypeUtility coercedToStringValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_APP_NAME_FIELD]];
    BOOL loginTooltipEnabled = [FBSDKTypeUtility boolValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_LOGIN_TOOLTIP_ENABLED_FIELD]];
    NSString *loginTooltipText = [FBSDKTypeUtility coercedToStringValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_LOGIN_TOOLTIP_TEXT_FIELD]];
    NSString *defaultShareMode = [FBSDKTypeUtility coercedToStringValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_DEFAULT_SHARE_MODE_FIELD]];
    BOOL implicitLoggingEnabled = [FBSDKTypeUtility boolValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_IMPLICIT_LOGGING_ENABLED_FIELD]];
    NSDictionary<NSString *, id> *dialogConfigurations = [FBSDKTypeUtility dictionaryValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_DIALOG_CONFIGURATIONS_FIELD]];
    if (dialogConfigurations) {
      dialogConfigurations = [self _parseDialogConfigurations:dialogConfigurations];
    } else {
      dialogConfigurations = @{};
    }
    NSDictionary<NSString *, id> *dialogFlows = [FBSDKTypeUtility dictionaryValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_DIALOG_FLOWS_FIELD]];
    FBSDKErrorConfiguration *errorConfiguration = [[FBSDKErrorConfiguration alloc] initWithDictionary:nil];
    [errorConfiguration updateWithArray:resultDictionary[FBSDK_SERVER_CONFIGURATION_ERROR_CONFIGURATION_FIELD]];
    NSTimeInterval sessionTimeoutInterval = [FBSDKTypeUtility timeIntervalValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_SESSION_TIMEOUT_FIELD]];
    NSString *loggingToken = [FBSDKTypeUtility coercedToStringValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_LOGGIN_TOKEN_FIELD]];
    FBSDKServerConfigurationSmartLoginOptions smartLoginOptions = [FBSDKTypeUtility integerValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_SMART_LOGIN_OPTIONS_FIELD]];
    NSURL *smartLoginBookmarkIconURL = [FBSDKTypeUtility coercedToURLValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_SMART_LOGIN_BOOKMARK_ICON_URL_FIELD]];
    NSURL *smartLoginMenuIconURL = [FBSDKTypeUtility coercedToURLValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_SMART_LOGIN_MENU_ICON_URL_FIELD]];
    NSString *updateMessage = [FBSDKTypeUtility coercedToStringValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_UPDATE_MESSAGE_FIELD]];
    NSArray<NSDictionary<NSString *, id> *> *eventBindings = [FBSDKTypeUtility arrayValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_EVENT_BINDINGS_FIELD]];
    NSDictionary<NSString *, id> *restrictiveParams = [FBSDKBasicUtility objectForJSONString:resultDictionary[FBSDK_SERVER_CONFIGURATION_RESTRICTIVE_PARAMS_FIELD] error:nil];
    NSDictionary<NSString *, id> *AAMRules = [FBSDKBasicUtility objectForJSONString:resultDictionary[FBSDK_SERVER_CONFIGURATION_AAM_RULES_FIELD] error:nil];
    NSDictionary<NSString *, id> *suggestedEventsSetting = [FBSDKBasicUtility objectForJSONString:resultDictionary[FBSDK_SERVER_CONFIGURATION_SUGGESTED_EVENTS_SETTING_FIELD] error:nil];
    NSDictionary<NSString *, id> *protectedModeRules = [FBSDKTypeUtility dictionaryValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_PROTECTED_MODE_RULES_FIELD]];
    NSMutableDictionary<NSString *, id> *migratedAutoLogValues = [NSMutableDictionary<NSString *, id> new];
    if([resultDictionary.allKeys containsObject:FBSDK_SERVER_CONFIGURATION_AUTO_LOG_APP_EVENTS_ENABLED_FIELD]) {
      migratedAutoLogValues[FBSDK_SERVER_CONFIGURATION_AUTO_LOG_APP_EVENTS_ENABLED_FIELD] = @([FBSDKTypeUtility boolValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_AUTO_LOG_APP_EVENTS_ENABLED_FIELD]]);
    }
    if([resultDictionary.allKeys containsObject:FBSDK_SERVER_CONFIGURATION_AUTO_LOG_APP_EVENTS_DEFAULT_FIELD]) {
      migratedAutoLogValues[FBSDK_SERVER_CONFIGURATION_AUTO_LOG_APP_EVENTS_DEFAULT_FIELD] = @([FBSDKTypeUtility
          boolValue:resultDictionary[FBSDK_SERVER_CONFIGURATION_AUTO_LOG_APP_EVENTS_DEFAULT_FIELD]]);
    }

    FBSDKServerConfiguration *serverConfiguration = [[FBSDKServerConfiguration alloc] initWithAppID:appID
                                                                                            appName:appName
                                                                                loginTooltipEnabled:loginTooltipEnabled
                                                                                   loginTooltipText:loginTooltipText
                                                                                   defaultShareMode:defaultShareMode
                                                                               advertisingIDEnabled:advertisingIDEnabled
                                                                             implicitLoggingEnabled:implicitLoggingEnabled
                                                                     implicitPurchaseLoggingEnabled:implicitPurchaseLoggingEnabled
                                                                              codelessEventsEnabled:codelessEventsEnabled
                                                                           uninstallTrackingEnabled:uninstallTrackingEnabled
                                                                               dialogConfigurations:dialogConfigurations
                                                                                        dialogFlows:dialogFlows
                                                                                          timestamp:[NSDate date]
                                                                                 errorConfiguration:errorConfiguration
                                                                             sessionTimeoutInterval:sessionTimeoutInterval
                                                                                           defaults:NO
                                                                                       loggingToken:loggingToken
                                                                                  smartLoginOptions:smartLoginOptions
                                                                          smartLoginBookmarkIconURL:smartLoginBookmarkIconURL
                                                                              smartLoginMenuIconURL:smartLoginMenuIconURL
                                                                                      updateMessage:updateMessage
                                                                                      eventBindings:eventBindings
                                                                                  restrictiveParams:restrictiveParams
                                                                                           AAMRules:AAMRules
                                                                             suggestedEventsSetting:suggestedEventsSetting
                                                                                 protectedModeRules:protectedModeRules
                                                                              migratedAutoLogValues:migratedAutoLogValues.copy];
  
    [self _didProcessConfigurationFromNetwork:serverConfiguration appID:appID error:nil];
  } @catch (NSException *exception) {}
}

- (id<FBSDKGraphRequest>)requestToLoadServerConfiguration:(NSString *)appID
{
  if ([self _serverConfigurationErrorIsValidForAppID:appID]) {
    return nil;
  }

  NSOperatingSystemVersion operatingSystemVersion = [FBSDKInternalUtility.sharedUtility operatingSystemVersion];
  NSString *osVersion = [NSString stringWithFormat:@"%ti.%ti.%ti",
                         operatingSystemVersion.majorVersion,
                         operatingSystemVersion.minorVersion,
                         operatingSystemVersion.patchVersion];
  NSString *dialogFlowsField = [NSString stringWithFormat:@"%@.os_version(%@)",
                                FBSDK_SERVER_CONFIGURATION_DIALOG_FLOWS_FIELD,
                                osVersion];
  NSArray<NSString *> *fields = @[FBSDK_SERVER_CONFIGURATION_APP_EVENTS_FEATURES_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_APP_NAME_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_DEFAULT_SHARE_MODE_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_DIALOG_CONFIGURATIONS_FIELD,
                                  dialogFlowsField,
                                  FBSDK_SERVER_CONFIGURATION_ERROR_CONFIGURATION_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_IMPLICIT_LOGGING_ENABLED_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_LOGIN_TOOLTIP_ENABLED_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_LOGIN_TOOLTIP_TEXT_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_SESSION_TIMEOUT_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_LOGGIN_TOKEN_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_RESTRICTIVE_PARAMS_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_AAM_RULES_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_SUGGESTED_EVENTS_SETTING_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_PROTECTED_MODE_RULES_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_AUTO_LOG_APP_EVENTS_DEFAULT_FIELD,
                                  FBSDK_SERVER_CONFIGURATION_AUTO_LOG_APP_EVENTS_ENABLED_FIELD
                                #if !TARGET_OS_TV
                                  , FBSDK_SERVER_CONFIGURATION_EVENT_BINDINGS_FIELD
                                #endif
                                #if DEBUG
                                  , FBSDK_SERVER_CONFIGURATION_UPDATE_MESSAGE_FIELD
                                #endif
  ];
  NSDictionary<NSString *, NSString *> *parameters = @{ @"fields" : [fields componentsJoinedByString:@","],
                                                        @"os_version" : osVersion};

  return [self.graphRequestFactory createGraphRequestWithGraphPath:appID
                                                        parameters:parameters
                                                       tokenString:nil
                                                        HTTPMethod:nil
                                                             flags:FBSDKGraphRequestFlagSkipClientToken | FBSDKGraphRequestFlagDisableErrorRecovery
                                 useAlternativeDefaultDomainPrefix:NO];
}

- (void)_didProcessConfigurationFromNetwork:(FBSDKServerConfiguration *)serverConfiguration
                                      appID:(NSString *)appID
                                      error:(NSError *)error
{
  NSMutableArray<FBSDKServerConfigurationBlock> *completionBlocks = [NSMutableArray new];
  @synchronized(self) {
    if (error) {
      // Only set the error if we don't have previously fetched app settings.
      // (i.e., if we have app settings and a new call gets an error, we'll
      // ignore the error and surface the last successfully fetched settings).
      if (_serverConfiguration && [_serverConfiguration.appID isEqualToString:appID]) {
        // We have older app settings but the refresh received an error.
        // Log and ignore the error.
        NSString *msg = [NSString stringWithFormat:@"loadServerConfigurationWithCompletionBlock failed with %@", error];
        [FBSDKLogger singleShotLogEntry:FBSDKLoggingBehaviorInformational
                               logEntry:msg];
      } else {
        _serverConfiguration = nil;
      }
      _serverConfigurationError = error;
      _serverConfigurationErrorTimestamp = [NSDate date];
      _serverConfigurationErrorAppID = [appID copy];
    } else {
      _serverConfiguration = serverConfiguration;
      _serverConfigurationError = nil;
      _serverConfigurationErrorTimestamp = nil;
      _serverConfigurationErrorAppID = nil;

    #if DEBUG
      NSString *updateMessage = _serverConfiguration.updateMessage;
      if (updateMessage && updateMessage.length > 0 && !_printedUpdateMessage) {
        _printedUpdateMessage = YES;
        [FBSDKLogger singleShotLogEntry:FBSDKLoggingBehaviorInformational logEntry:updateMessage];
      }
    #endif
    }

    // update the cached copy in NSUserDefaults
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *defaultsKey = [NSString stringWithFormat:FBSDK_SERVER_CONFIGURATION_USER_DEFAULTS_KEY, appID];
    if (serverConfiguration) {
      NSData *data = [NSKeyedArchiver archivedDataWithRootObject:serverConfiguration requiringSecureCoding:NO error:nil];
      [defaults setObject:data forKey:defaultsKey];
    }

    // wrap the completion blocks
    for (FBSDKServerConfigurationBlock completionBlock in _completionBlocks) {
      [FBSDKTypeUtility array:completionBlocks addObject:[self _wrapperBlockForLoadBlock:completionBlock]];
    }
    [_completionBlocks removeAllObjects];
    _loadingServerConfiguration = NO;
  }

  // release the lock before calling out of this class
  for (void (^completionBlock)(void) in completionBlocks) {
    completionBlock();
  }
}

- (NSDictionary<NSString *, FBSDKDialogConfiguration *> *)_parseDialogConfigurations:(nonnull NSDictionary<NSString *, id> *)dictionary
{
  NSArray<NSDictionary<NSString *, id> *> *dialogConfigurationsArray = [FBSDKTypeUtility arrayValue:dictionary[@"data"]];
  if (dialogConfigurationsArray) {
    return [self.dialogConfigurationMapBuilder buildDialogConfigurationMapWithRawConfigurations:dialogConfigurationsArray];
  } else {
    return @{};
  }
}

- (BOOL)_serverConfigurationErrorIsValidForAppID:(NSString *)appID
{
  @synchronized(self) {
    return self.serverConfigurationError
    && self.serverConfigurationErrorTimestamp
    && (self.serverConfigurationErrorAppID == appID || [self.serverConfigurationErrorAppID isEqualToString:appID])
    && [self _serverConfigurationTimestampIsValid:self.serverConfigurationErrorTimestamp];
  }
}

- (BOOL)_serverConfigurationTimestampIsValid:(NSDate *)timestamp
{
  return ([[NSDate date] timeIntervalSinceDate:timestamp] < FBSDK_SERVER_CONFIGURATION_MANAGER_CACHE_TIMEOUT);
}

- (nullable FBSDKCodeBlock)_wrapperBlockForLoadBlock:(FBSDKServerConfigurationBlock)loadBlock
{
  if (!loadBlock) {
    return nil;
  }

  // create local vars to capture the current values from the ivars to allow this wrapper to be called outside of a lock
  FBSDKServerConfiguration *serverConfiguration;
  NSError *serverConfigurationError;
  @synchronized(self) {
    serverConfiguration = _serverConfiguration;
    serverConfigurationError = _serverConfigurationError;
  }
  return ^{
    loadBlock(serverConfiguration, serverConfigurationError);
  };
}

#if DEBUG

- (void)reset
{
  [self clearCache];
  self.graphRequestFactory = nil;
  self.graphRequestConnectionFactory = nil;
  self.dialogConfigurationMapBuilder = nil;
}

#endif

@end
