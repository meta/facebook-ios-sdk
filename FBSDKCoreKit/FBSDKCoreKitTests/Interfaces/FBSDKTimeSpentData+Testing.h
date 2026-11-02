/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <FBSDKCoreKit/FBSDKCoreKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBSDKTimeSpentData ()

@property (nonatomic, weak) id<FBSDKEventLogging> eventLogger;
@property (nonnull, nonatomic) id<FBSDKServerConfigurationProviding> serverConfigurationProvider;
@property (nonatomic) NSString *sourceApplication;
@property (nonatomic) BOOL isOpenedFromAppLink;
@property (nonatomic) BOOL isCurrentlyLoaded;
@property (nonatomic) NSTimeInterval lastRestoreTime;
@property (nonatomic) NSTimeInterval secondsSpentInCurrentSession;
@property (nonatomic) int numInterruptionsInCurrentSession;
@property (nonatomic) NSString *sessionID;
@property (nonatomic) NSTimeInterval lastSuspendTime;

- (NSString *)getSourceApplication;
- (void)resetSourceApplication;
- (NSDictionary<NSString *, id> *)appEventsParametersForDeactivate;
- (void)suspendTimeSpentData NS_SWIFT_NAME(suspendTimeSpentData());
- (void)restoreTimeSpendDataWithCalledFromActivateApp:(BOOL)calledFromActivateApp
    NS_SWIFT_NAME(restoreTimeSpentData(calledFromActivateApp:));

@end

NS_ASSUME_NONNULL_END
