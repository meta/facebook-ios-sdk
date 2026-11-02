/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <FBSDKCoreKit/FBSDKGraphRequest.h>
#import <FBSDKCoreKit/FBSDKServerConfiguration.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Internal type exposed to facilitate transition to Swift.
 API Subject to change or removal without warning. Do not use.

 @warning INTERNAL - DO NOT USE
 */
NS_SWIFT_NAME(_ServerConfigurationBlock)
typedef void (^FBSDKServerConfigurationBlock)(FBSDKServerConfiguration *_Nullable serverConfiguration, NSError *_Nullable error);

/**
 Internal type exposed to facilitate transition to Swift.
 API Subject to change or removal without warning. Do not use.

 @warning INTERNAL - DO NOT USE
 */
NS_SWIFT_NAME(_ServerConfigurationProviding)
@protocol FBSDKServerConfigurationProviding

- (FBSDKServerConfiguration *)cachedServerConfiguration;

/**
 Executes the completionBlock with a valid and current configuration when it is available.

 This method will use a cached configuration if it is valid and not expired.
 If a recent load failed, the completion receives the last configuration and error until the retry cooldown expires.
 */
- (void)loadServerConfigurationWithCompletionBlock:(nullable FBSDKServerConfigurationBlock)completionBlock;

- (void)processLoadRequestResponse:(id)result error:(nullable NSError *)error appID:(NSString *)appID;

/// Returns nil during the retry cooldown after a recent failure for the requested app.
- (nullable FBSDKGraphRequest *)requestToLoadServerConfiguration:(NSString *)appID;

@end

NS_ASSUME_NONNULL_END
