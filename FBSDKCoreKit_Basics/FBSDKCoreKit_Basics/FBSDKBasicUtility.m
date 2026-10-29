/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSDKBasicUtility.h"

#import <CommonCrypto/CommonCrypto.h>
#import <zlib.h>

#import "FBSDKTypeUtility.h"

#define kChunkSize 1024

static NSString *const FBSDK_BASICUTILITY_ANONYMOUSIDFILENAME = @"com-facebook-sdk-PersistedAnonymousID.json";
static NSString *const FBSDK_BASICUTILITY_ANONYMOUSID_KEY = @"anon_id";

void fb_dispatch_on_main_thread(dispatch_block_t block)
{
  if (block != nil) {
    if (NSThread.isMainThread) {
      block();
    } else {
      dispatch_async(dispatch_get_main_queue(), block);
    }
  }
}

void fb_dispatch_on_default_thread(dispatch_block_t block)
{
  if (block != nil) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), block);
  }
}

NS_ASSUME_NONNULL_BEGIN

@protocol FBSDKBasicsErrorCreating

- (NSError *)invalidArgumentErrorWithName:(NSString *)name
                                    value:(nullable id)value
                                  message:(nullable NSString *)message
                          underlyingError:(nullable NSError *)underlyingError;

@end

NS_ASSUME_NONNULL_END

@implementation FBSDKBasicUtility

+ (nullable NSString *)JSONStringForObject:(id)object
                                     error:(NSError *__autoreleasing *)errorRef
                      invalidObjectHandler:(FBSDKInvalidObjectHandler)invalidObjectHandler
{
  if (invalidObjectHandler || ![NSJSONSerialization isValidJSONObject:object]) {
    object = [self _convertObjectToJSONObject:object invalidObjectHandler:invalidObjectHandler stop:NULL];
    if (![NSJSONSerialization isValidJSONObject:object]) {
      if (errorRef != NULL) {
        Class FBSDKErrorFactory = NSClassFromString(@"FBSDKErrorFactory");
        id factory = [FBSDKErrorFactory new];
        if ([factory respondsToSelector:@selector(invalidArgumentErrorWithName:value:message:underlyingError:)]) {
          *errorRef = [factory invalidArgumentErrorWithName:@"object"
                                                      value:object
                                                    message:@"Invalid object for JSON serialization."
                                            underlyingError:nil];
        }
      }
      return nil;
    }
  }
  NSData *data = [FBSDKTypeUtility dataWithJSONObject:object options:0 error:errorRef];
  if (!data) {
    return nil;
  }
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (BOOL)      dictionary:(NSMutableDictionary<NSString *, id> *)dictionary
  setJSONStringForObject:(id)object
                  forKey:(id<NSCopying>)key
                   error:(NSError *__autoreleasing *)errorRef
{
  if (!object || !key) {
    return YES;
  }
  NSString *JSONString = [self JSONStringForObject:object error:errorRef invalidObjectHandler:NULL];
  if (!JSONString) {
    return NO;
  }
  [FBSDKTypeUtility dictionary:dictionary setObject:JSONString forKey:key];
  return YES;
}

+ (id)_convertObjectToJSONObject:(id)object
            invalidObjectHandler:(FBSDKInvalidObjectHandler)invalidObjectHandler
                            stop:(BOOL *)stopRef
{
  __block BOOL stop = NO;
  if ([object isKindOfClass:NSString.class] || [object isKindOfClass:NSNumber.class]) {
    // good to go, keep the object
  } else if ([object isKindOfClass:NSURL.class]) {
    object = ((NSURL *)object).absoluteString;
  } else if ([object isKindOfClass:[NSDictionary<NSString *, id> class]]) {
    NSMutableDictionary<NSString *, id> *dictionary = [NSMutableDictionary new];
    [FBSDKTypeUtility dictionary:(NSDictionary<id, id> *) object enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *dictionaryStop) {
      [FBSDKTypeUtility dictionary:dictionary
                         setObject:[self _convertObjectToJSONObject:obj invalidObjectHandler:invalidObjectHandler stop:&stop]
                            forKey:[FBSDKTypeUtility coercedToStringValue:key]];
      if (stop) {
        *dictionaryStop = YES;
      }
    }];
    object = dictionary;
  } else if ([object isKindOfClass:NSArray.class]) {
    NSMutableArray<id> *array = [NSMutableArray new];
    for (id obj in (NSArray<id> *)object) {
      id convertedObj = [self _convertObjectToJSONObject:obj invalidObjectHandler:invalidObjectHandler stop:&stop];
      [FBSDKTypeUtility array:array addObject:convertedObj];
      if (stop) {
        break;
      }
    }
    object = array;
  } else {
    if (invalidObjectHandler) {
      object = invalidObjectHandler(object, stopRef);
    } else {
      object = nil;
    }
  }
  if (stopRef != NULL) {
    *stopRef = stop;
  }
  return object;
}

+ (nullable id)objectForJSONString:(NSString *)string error:(NSError *__autoreleasing *)errorRef
{
  NSData *data = [[FBSDKTypeUtility stringValueOrNil:string] dataUsingEncoding:NSUTF8StringEncoding];
  if (!data) {
    if (errorRef != NULL) {
      *errorRef = nil;
    }
    return nil;
  }
  return [FBSDKTypeUtility JSONObjectWithData:data options:NSJSONReadingAllowFragments error:errorRef];
}

+ (nullable NSString *)queryStringWithDictionary:(NSDictionary<NSString *, id> *)dictionary
                                           error:(NSError *__autoreleasing *)errorRef
                            invalidObjectHandler:(nullable FBSDKInvalidObjectHandler)invalidObjectHandler
{
  NSMutableString *queryString = [NSMutableString new];
  __block BOOL hasParameters = NO;
  if (dictionary) {
    NSMutableArray<NSString *> *keys = [dictionary.allKeys mutableCopy];
    // remove non-string keys, as they are not valid
    [keys filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL (id evaluatedObject, NSDictionary<id, id> *bindings) {
      return [evaluatedObject isKindOfClass:NSString.class];
    }]];
    // sort the keys so that the query string order is deterministic
    [keys sortUsingSelector:@selector(compare:)];
    BOOL stop = NO;
    for (NSString *key in keys) {
      id value = [self convertRequestValue:dictionary[key]];
      if ([value isKindOfClass:NSString.class]) {
        value = [self URLEncode:value];
      }
      if (invalidObjectHandler && ![value isKindOfClass:NSString.class]) {
        value = invalidObjectHandler(value, &stop);
        if (stop) {
          break;
        }
      }
      if (value) {
        if (hasParameters) {
          [queryString appendString:@"&"];
        }
        [queryString appendFormat:@"%@=%@", key, value];
        hasParameters = YES;
      }
    }
  }
  if (errorRef != NULL) {
    *errorRef = nil;
  }
  return (queryString.length ? [queryString copy] : nil);
}

+ (id)convertRequestValue:(id)value
{
  if ([value isKindOfClass:NSNumber.class]) {
    value = ((NSNumber *)value).stringValue;
  } else if ([value isKindOfClass:NSURL.class]) {
    value = ((NSURL *)value).absoluteString;
  }
  return value;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
+ (NSString *)URLEncode:(NSString *)value
{
  return (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(
    NULL,
    (CFStringRef)value,
    NULL, // characters to leave unescaped
    CFSTR(":!*();@/&?+$,='"),
    kCFStringEncodingUTF8
  );
}

#pragma clang diagnostic pop

+ (NSDictionary<NSString *, NSString *> *)dictionaryWithQueryString:(NSString *)queryString
{
  NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary new];
  NSArray<NSString *> *parts = [queryString componentsSeparatedByString:@"&"];

  for (NSString *part in parts) {
    if (part.length == 0) {
      continue;
    }

    NSRange index = [part rangeOfString:@"="];
    NSString *key;
    NSString *value;

    if (index.location == NSNotFound) {
      key = part;
      value = @"";
    } else {
      key = [part substringToIndex:index.location];
      value = [part substringFromIndex:index.location + index.length];
    }

    key = [self URLDecode:key];
    value = [self URLDecode:value];
    if (key && value) {
      [FBSDKTypeUtility dictionary:result setObject:value forKey:key];
    }
  }
  return result;
}

+ (NSString *)URLDecode:(NSString *)value
{
  value = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Wdeprecated-declarations"
  value = [value stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
  #pragma clang diagnostic pop
  return value;
}

+ (nullable NSData *)gzip:(NSData *)data
{
  const void *bytes = data.bytes;
  const NSUInteger length = data.length;

  if (!bytes || !length) {
    return nil;
  }

#if defined(__LP64__) && __LP64__
  if (length > UINT_MAX) {
    return nil;
  }
#endif

  // initialze stream
  z_stream stream;
  bzero(&stream, sizeof(z_stream));

  if (deflateInit2(&stream, -1, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
    return nil;
  }
  stream.avail_in = (uint)length;
  stream.next_in = (Bytef *)bytes;

  int retCode;
  NSMutableData *result = [NSMutableData dataWithCapacity:(length / 4)];
  unsigned char output[kChunkSize];
  do {
    stream.avail_out = kChunkSize;
    stream.next_out = output;
    retCode = deflate(&stream, Z_FINISH);
    if (retCode != Z_OK && retCode != Z_STREAM_END) {
      deflateEnd(&stream);
      return nil;
    }
    unsigned size = kChunkSize - stream.avail_out;
    if (size > 0) {
      [result appendBytes:output length:size];
    }
  } while (retCode == Z_OK);

  deflateEnd(&stream);

  return result;
}

+ (NSString *)anonymousID
{
  // Grab previously written anonymous ID and, if none have been generated, create and
  // persist a new one which will remain associated with this app.
  NSString *result = [self.class retrievePersistedAnonymousID];
  if (!result) {
    // Generate a new anonymous ID.  Create as a UUID, but then prepend the fairly
    // arbitrary 'XZ' to the front so it's easily distinguishable from IDFA's which
    // will only contain hex.
    result = [NSString stringWithFormat:@"XZ%@", [NSUUID UUID].UUIDString];

    [self persistAnonymousID:result];
  }
  return result;
}

+ (NSString *)retrievePersistedAnonymousID
{
  NSString *file = [self.class persistenceFilePath:FBSDK_BASICUTILITY_ANONYMOUSIDFILENAME];
  NSString *content = [[NSString alloc] initWithContentsOfFile:file
                                                      encoding:NSASCIIStringEncoding
                                                         error:nil];
  NSDictionary<NSString *, id> *results = [FBSDKBasicUtility objectForJSONString:content error:NULL];
  return results[FBSDK_BASICUTILITY_ANONYMOUSID_KEY];
}

+ (NSString *)persistenceFilePath:(NSString *)filename
{
  NSSearchPathDirectory directory = NSLibraryDirectory;
  NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(directory, NSUserDomainMask, YES);
  NSString *docDirectory = paths.firstObject;
  return [docDirectory stringByAppendingPathComponent:filename];
}

+ (void)persistAnonymousID:(NSString *)anonymousID
{
  NSDictionary<NSString *, NSString *> *data = @{ FBSDK_BASICUTILITY_ANONYMOUSID_KEY : anonymousID };
  NSString *content = [self JSONStringForObject:data error:NULL invalidObjectHandler:NULL];

  [content writeToFile:[self.class persistenceFilePath:FBSDK_BASICUTILITY_ANONYMOUSIDFILENAME]
            atomically:YES
              encoding:NSASCIIStringEncoding
                 error:nil];
}

+ (nullable NSString *)SHA256Hash:(nullable NSObject *)input
{
  NSData *data = nil;

  if ([input isKindOfClass:NSData.class]) {
    data = (NSData *)input;
  } else if ([input isKindOfClass:NSString.class]) {
    data = [(NSString *)input dataUsingEncoding:NSUTF8StringEncoding];
  }

  if (!data) {
    return nil;
  }

  uint8_t digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hashed = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
    [hashed appendFormat:@"%02x", digest[i]];
  }

  return [hashed copy];
}

@end
