/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if !TARGET_OS_TV

#import "FBSDKGraphErrorRecoveryProcessor.h"

#import "FBSDKAccessToken+Internal.h"
#import "FBSDKErrorRecoveryAttempter.h"
#import "FBSDKGraphRequestProtocol.h"

@interface FBSDKGraphErrorRecoveryProcessor ()

@property (nonatomic, readonly) NSString *accessToken;
@property (nullable, nonatomic, readonly, weak) id<FBSDKGraphErrorRecoveryProcessorDelegate> delegate;
@property (nullable, nonatomic) FBSDKErrorRecoveryAttempter *recoveryAttempter;
@property (nullable, nonatomic) NSError *_error;

@end

@implementation FBSDKGraphErrorRecoveryProcessor

+ (instancetype)new
{
  return [[FBSDKGraphErrorRecoveryProcessor alloc] init];
}

- (instancetype)init
{
  return [self initWithAccessTokenString:FBSDKAccessToken.currentAccessToken.tokenString];
}

- (instancetype)initWithAccessTokenString:(NSString *)accessTokenString
{
  if ((self = [super init])) {
    _accessToken = accessTokenString;
  }

  return self;
}

- (BOOL)processError:(NSError *)error
             request:(id<FBSDKGraphRequest>)request
            delegate:(nullable id<FBSDKGraphErrorRecoveryProcessorDelegate>)delegate
{
  if ([delegate respondsToSelector:@selector(processorWillProcessError:error:)]) {
    if (![delegate processorWillProcessError:self error:error]) {
      return NO;
    }
  }

  FBSDKGraphRequestError errorCategory;
  id rawErrorCategory = error.userInfo[FBSDKGraphRequestErrorKey];
  if (rawErrorCategory && [rawErrorCategory respondsToSelector:@selector(unsignedIntegerValue)]) {
    errorCategory = [rawErrorCategory unsignedIntegerValue];
  } else {
    return NO;
  }

  switch (errorCategory) {
    case FBSDKGraphRequestErrorTransient:
      [delegate processorDidAttemptRecovery:self didRecover:YES error:nil];
      return YES;
    case FBSDKGraphRequestErrorRecoverable:
      if (request.tokenString && [request.tokenString isEqualToString:self.accessToken]) {
        self.recoveryAttempter = error.recoveryAttempter;
        if (!self.recoveryAttempter) {
          return NO;
        }
        [self.recoveryAttempter attemptRecoveryFromError:error
                                       completionHandler:^(BOOL didRecover) {
                                         [delegate processorDidAttemptRecovery:self didRecover:didRecover error:error];
                                         self->_delegate = nil;
                                       }];
        return YES;
      }
      break;
    case FBSDKGraphRequestErrorOther:
      return NO;
  }
  return NO;
}

@end

#endif
