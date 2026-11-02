/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <FBSDKCoreKit/FBSDKCoreKit.h>
#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#import "FBSDKAEMManager+Testing.h"
#import "FBSDKSwizzler+Testing.h"

@interface FBSDKAEMManager (DelegateTesting)
- (void)setup;
- (void)setupWithProxy;
@property (nullable, nonatomic, assign) IMP originalAppDelegateOpenURLIMP;
@property (nullable, nonatomic, assign) IMP originalAppDelegateContinueUserActivityIMP;
@end

@interface FBSDKAEMTestAppDelegate : NSObject <UIApplicationDelegate>
@property (nonatomic) BOOL handled;
@property (nonatomic) NSUInteger callCount;
@property (nonatomic, strong) id capturedApplication;
@property (nonatomic, strong) id capturedInput;
@property (nonatomic, strong) id capturedOptions;
@end

@implementation FBSDKAEMTestAppDelegate

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
  self.callCount++;
  self.capturedApplication = application;
  self.capturedInput = url;
  self.capturedOptions = options;
  return self.handled;
}

- (BOOL)application:(UIApplication *)application
    continueUserActivity:(NSUserActivity *)userActivity
      restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> *))restorationHandler
{
  self.callCount++;
  self.capturedApplication = application;
  self.capturedInput = userActivity;
  self.capturedOptions = restorationHandler;
  return self.handled;
}

@end

@interface FBSDKAEMTestApplication : NSObject
@property (nonatomic, weak) id<UIApplicationDelegate> delegate;
@property (nonatomic, copy) NSSet<UIScene *> *connectedScenes;
@end

@implementation FBSDKAEMTestApplication
@end

@interface FBSDKSwizzlerTestObject : NSObject

@property (nonatomic) int methodToSwizzleAsynchronouslyCallCount;
@property (nonatomic) int methodWithNoArgumentsCallCount;
@property (nonatomic) int methodWithOneArgumentCallCount;
@property (nonatomic) int methodWithTwoArgumentsCallCount;
@property (nonatomic) int methodWithThreeArgumentsCallCount;
@property (nonatomic) int methodWithFourArgumentsCallCount;
@property (nonatomic) int methodToUnswizzleCallCount;
@property (nonatomic) int methodToConflictCallCount;
@property (nonatomic) int methodToOverrideCallCount;
@property (nonatomic) int methodToSwizzleInSuperAndSubclassCallCount;

- (void)methodToSwizzleAsynchronously;
- (void)methodWithNoArguments;
- (void)methodWithOneArgument:(id)arg;
- (void)methodWithArgument:(id)arg
            secondArgument:(id)arg2;
- (void)methodWithArgument:(id)arg
            secondArgument:(id)arg2
             thirdArgument:(id)arg3;
- (void)methodWithArgument:(id)arg
            secondArgument:(id)arg2
             thirdArgument:(id)arg3
            fourthArgument:(id)arg4;
- (void)methodToUnswizzle;
- (void)methodToConflict;
- (void)methodToOverride;
- (void)methodToSwizzleInSuperAndSubclass;

@end

@implementation FBSDKSwizzlerTestObject

- (instancetype)init
{
  if ((self = [super init])) {
    _methodToSwizzleAsynchronouslyCallCount = 0;
    _methodWithNoArgumentsCallCount = 0;
    _methodWithOneArgumentCallCount = 0;
    _methodWithTwoArgumentsCallCount = 0;
    _methodWithThreeArgumentsCallCount = 0;
    _methodWithFourArgumentsCallCount = 0;
    _methodToUnswizzleCallCount = 0;
    _methodToConflictCallCount = 0;
    _methodToOverrideCallCount = 0;
  }
  return self;
}

- (void)methodToSwizzleAsynchronously
{
  self.methodToSwizzleAsynchronouslyCallCount++;
}

- (void)methodWithNoArguments
{
  self.methodWithNoArgumentsCallCount++;
}

- (void)methodWithOneArgument:(id)arg
{
  self.methodWithOneArgumentCallCount++;
}

- (void)methodWithArgument:(id)arg
            secondArgument:(id)arg2
{
  self.methodWithTwoArgumentsCallCount++;
}

- (void)methodWithArgument:(id)arg
            secondArgument:(id)arg2
             thirdArgument:(id)arg3
{
  self.methodWithThreeArgumentsCallCount++;
}

- (void)methodWithArgument:(id)arg
            secondArgument:(id)arg2
             thirdArgument:(id)arg3
            fourthArgument:(id)arg4
{
  self.methodWithFourArgumentsCallCount++;
}

- (void)methodToUnswizzle
{
  self.methodToUnswizzleCallCount++;
}

- (void)methodToConflict
{
  self.methodToConflictCallCount++;
}

- (void)methodToOverride
{
  self.methodToOverrideCallCount++;
}

- (void)methodToSwizzleInSuperAndSubclass
{
  self.methodToSwizzleInSuperAndSubclassCallCount++;
}

@end

@interface FBSDKSwizzlerTestObjectSubclass : FBSDKSwizzlerTestObject
@end

@implementation FBSDKSwizzlerTestObjectSubclass

- (void)methodToOverride
{
  [super methodToOverride];
}

- (void)methodToSwizzleInSuperAndSubclass
{
  self.methodToSwizzleInSuperAndSubclassCallCount++;
  [super methodToSwizzleInSuperAndSubclass];
}

@end

@interface FBSDKSwizzlerTests : XCTestCase
@end

@implementation FBSDKSwizzlerTests

- (void)testAEMSwizzlingPreservesOpenURLResult
{
  [self assertAEMDelegateResultWithProxy:NO universalLink:NO];
}

- (void)testAEMSwizzlingPreservesUniversalLinkResult
{
  [self assertAEMDelegateResultWithProxy:NO universalLink:YES];
}

- (void)testAEMProxyPreservesOpenURLResult
{
  [self assertAEMDelegateResultWithProxy:YES universalLink:NO];
}

- (void)testAEMProxyPreservesUniversalLinkResult
{
  [self assertAEMDelegateResultWithProxy:YES universalLink:YES];
}

- (void)assertAEMDelegateResultWithProxy:(BOOL)proxyEnabled universalLink:(BOOL)universalLink
{
  // CoreKit runs unhosted tests, so supply only the UIApplication boundary.
  FBSDKAEMTestApplication *testApplication = [FBSDKAEMTestApplication new];
  testApplication.connectedScenes = [NSSet set];
  UIApplication *application = (UIApplication *)testApplication;
  Method sharedApplicationMethod = class_getClassMethod(UIApplication.class, @selector(sharedApplication));
  IMP originalSharedApplication = method_getImplementation(sharedApplicationMethod);
  IMP sharedApplication = imp_implementationWithBlock(^id (id receiver) {
    return application;
  });
  FBSDKAEMTestAppDelegate *delegate = [FBSDKAEMTestAppDelegate new];
  Class delegateClass = delegate.class;
  SEL openSelector = @selector(application:openURL:options:);
  SEL continueSelector = @selector(application:continueUserActivity:restorationHandler:);
  Method openMethod = class_getInstanceMethod(delegateClass, openSelector);
  Method continueMethod = class_getInstanceMethod(delegateClass, continueSelector);
  IMP originalOpen = method_getImplementation(openMethod);
  IMP originalContinue = method_getImplementation(continueMethod);
  FBSDKAEMManager *manager = FBSDKAEMManager.shared;
  Class originalSwizzler = manager.swizzler;
  Class originalReporter = manager.aemReporter;
  id originalLogger = manager.eventLogger;
  id originalUtility = manager.appEventsUtility;
  IMP originalProxyOpen = manager.originalAppDelegateOpenURLIMP;
  IMP originalProxyContinue = manager.originalAppDelegateContinueUserActivityIMP;

  @try {
    method_setImplementation(sharedApplicationMethod, sharedApplication);
    application.delegate = delegate;
    manager.swizzler = FBSDKSwizzler.class;
    manager.aemReporter = nil;
    manager.eventLogger = nil;
    manager.appEventsUtility = nil;
    if (proxyEnabled) {
      [manager setupWithProxy];
    } else {
      [manager setup];
    }

    XCTestExpectation *expectation = [self expectationWithDescription:@"AEM hooks installed"];
    [FBSDKSwizzler swizzleSelectorWithBlock:^{
      [expectation fulfill];
    } async:YES];
    [self waitForExpectations:@[expectation] timeout:3];
    XCTAssertNotEqual(method_getImplementation(openMethod), originalOpen);
    XCTAssertNotEqual(method_getImplementation(continueMethod), originalContinue);

    NSURL *url = [NSURL URLWithString:@"https://example.com/aem-delegate"];
    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = url;
    NSDictionary *options = @{};
    void (^restorationHandler)(NSArray<id<UIUserActivityRestoring>> *) =
      ^(NSArray<id<UIUserActivityRestoring>> *objects) {};
    for (NSNumber *handled in @[@YES, @NO]) {
      delegate.handled = handled.boolValue;
      NSUInteger previousCallCount = delegate.callCount;
      BOOL result = universalLink
        ? [delegate application:application continueUserActivity:activity restorationHandler:restorationHandler]
        : [delegate application:application openURL:url options:options];
      XCTAssertEqual(result, handled.boolValue, @"AEM must preserve the application's return value");
      XCTAssertEqual(delegate.callCount, previousCallCount + 1);
      XCTAssertEqual(delegate.capturedApplication, application);
      XCTAssertEqual(delegate.capturedInput, universalLink ? activity : url);
      XCTAssertEqual(delegate.capturedOptions, universalLink ? (id)restorationHandler : options);
    }
  } @finally {
    if (!proxyEnabled) {
      [FBSDKSwizzler unswizzleSelector:openSelector onClass:delegateClass named:@"AEMDeeplinkAutoSetup"];
      [FBSDKSwizzler unswizzleSelector:continueSelector onClass:delegateClass named:@"AEMUniversallinkAutoSetup"];
    }
    method_setImplementation(openMethod, originalOpen);
    method_setImplementation(continueMethod, originalContinue);
    manager.originalAppDelegateOpenURLIMP = originalProxyOpen;
    manager.originalAppDelegateContinueUserActivityIMP = originalProxyContinue;
    manager.swizzler = originalSwizzler;
    manager.aemReporter = originalReporter;
    manager.eventLogger = originalLogger;
    manager.appEventsUtility = originalUtility;
    method_setImplementation(sharedApplicationMethod, originalSharedApplication);
    imp_removeBlock(sharedApplication);
  }
}

- (void)_testSwizzlingIsAsynchronousByDefault
{
  __block int swizzleBlockInvocationCount = 0;
  [FBSDKSwizzler swizzleSelector:@selector(methodToSwizzleAsynchronously)
                         onClass:FBSDKSwizzlerTestObject.class
                       withBlock:^{
                         swizzleBlockInvocationCount++;
                       }
                           named:self.name];
  FBSDKSwizzlerTestObject *testObject = [FBSDKSwizzlerTestObject new];
  [testObject methodToSwizzleAsynchronously];
  XCTAssertEqual(
    swizzleBlockInvocationCount,
    0,
    "Should not swizzle the method synchronously"
  );
  XCTAssertEqual(
    testObject.methodToSwizzleAsynchronouslyCallCount,
    1,
    "Should invoke the original implementation once per method call"
  );

  // Predicates expectations are evaluated every second so we can just poll
  // the method until it has been swizzled asynchronously
  NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL (id evaluatedObject, NSDictionary<NSString *, id> *bindings) {
    [testObject methodToSwizzleAsynchronously];
    return swizzleBlockInvocationCount > 0;
  }];

  XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:self];
  [self waitForExpectations:@[expectation] timeout:3];
}

- (void)testSwizzlingMethodWithNoArguments
{
  __block int swizzleBlockInvocationCount = 0;
  [FBSDKSwizzler swizzleSelector:@selector(methodWithNoArguments)
                         onClass:FBSDKSwizzlerTestObject.class
                       withBlock:^{
                         swizzleBlockInvocationCount++;
                       }
                           named:self.name
                           async:NO];
  FBSDKSwizzlerTestObject *testObject = [FBSDKSwizzlerTestObject new];
  [testObject methodWithNoArguments];
  [testObject methodWithNoArguments];
  XCTAssertEqual(
    swizzleBlockInvocationCount,
    2,
    "Should invoke the swizzle block once per method call"
  );
  XCTAssertEqual(
    testObject.methodWithNoArgumentsCallCount,
    2,
    "Should invoke the original implementation once per method call"
  );
}

- (void)testSwizzlingMethodWithOneArgument
{
  __block int swizzleBlockInvocationCount = 0;
  __block id capturedArgument = nil;
  [FBSDKSwizzler swizzleSelector:@selector(methodWithOneArgument:)
                         onClass:FBSDKSwizzlerTestObject.class
                       withBlock:^(id caller, SEL command, id arg) {
                         swizzleBlockInvocationCount++;
                         capturedArgument = arg;
                       }
                           named:self.name
                           async:NO];
  FBSDKSwizzlerTestObject *testObject = [FBSDKSwizzlerTestObject new];
  [testObject methodWithOneArgument:@"Foo"];
  XCTAssertEqualObjects(
    capturedArgument,
    @"Foo",
    "Should invoke the swizzle block with the original arguments"
  );
  XCTAssertEqual(
    testObject.methodWithOneArgumentCallCount,
    1,
    "Should invoke the original implementation"
  );
  XCTAssertEqual(
    swizzleBlockInvocationCount,
    1,
    "Should invoke the swizzle block once per method call"
  );
}

- (void)testSwizzlingMethodWithTwoArguments
{
  __block id capturedArg1 = nil;
  __block id capturedArg2 = nil;
  __block int swizzleBlockInvocationCount = 0;
  [FBSDKSwizzler swizzleSelector:@selector(methodWithArgument:secondArgument:)
                         onClass:FBSDKSwizzlerTestObject.class
                       withBlock:^(id caller, SEL command, id arg1, id arg2) {
                         capturedArg1 = arg1;
                         capturedArg2 = arg2;
                         swizzleBlockInvocationCount++;
                       }
                           named:self.name
                           async:NO];
  NSString *arg1 = @"Foo";
  NSString *arg2 = @"Bar";
  FBSDKSwizzlerTestObject *testObject = [FBSDKSwizzlerTestObject new];
  [testObject methodWithArgument:arg1
                  secondArgument:arg2];
  XCTAssertEqualObjects(capturedArg1, arg1);
  XCTAssertEqualObjects(capturedArg2, arg2);
  XCTAssertEqual(
    testObject.methodWithTwoArgumentsCallCount,
    1,
    "Should invoke the original implementation"
  );
  XCTAssertEqual(
    swizzleBlockInvocationCount,
    1,
    "Should invoke the swizzle block once per method call"
  );
}

- (void)testSwizzlingMethodWithMaxAllowedArguments
{
  __block id capturedArg1 = nil;
  __block id capturedArg2 = nil;
  __block id capturedArg3 = nil;
  __block int swizzleBlockInvocationCount = 0;
  [FBSDKSwizzler swizzleSelector:@selector(methodWithArgument:secondArgument:thirdArgument:)
                         onClass:FBSDKSwizzlerTestObject.class
                       withBlock:^(id caller, SEL command, id arg1, id arg2, id arg3) {
                         capturedArg1 = arg1;
                         capturedArg2 = arg2;
                         capturedArg3 = arg3;
                         swizzleBlockInvocationCount++;
                       }
                           named:self.name
                           async:NO];
  NSString *arg1 = @"Foo";
  NSString *arg2 = @"Bar";
  NSString *arg3 = @"Baz";
  FBSDKSwizzlerTestObject *testObject = [FBSDKSwizzlerTestObject new];
  [testObject methodWithArgument:arg1
                  secondArgument:arg2
                   thirdArgument:arg3];
  XCTAssertEqualObjects(capturedArg1, arg1);
  XCTAssertEqualObjects(capturedArg2, arg2);
  XCTAssertEqualObjects(capturedArg3, arg3);
  XCTAssertEqual(
    testObject.methodWithThreeArgumentsCallCount,
    1,
    "Should invoke the original implementation"
  );
  XCTAssertEqual(
    swizzleBlockInvocationCount,
    1,
    "Should invoke the swizzle block once per method call"
  );
}

- (void)testSwizzlingMethodWithMoreThanMaxAllowedArguments
{
  __block BOOL didInvokeSwizzleBlock = NO;
  [FBSDKSwizzler swizzleSelector:@selector(methodWithArgument:secondArgument:thirdArgument:fourthArgument:) // fifthArgument:)
                         onClass:FBSDKSwizzlerTestObject.class
                       withBlock:^(id caller, SEL command, id arg1, id arg2, id arg3, id arg4) {
                         didInvokeSwizzleBlock = YES;
                       }
                           named:self.name
                           async:NO];
  FBSDKSwizzlerTestObject *testObject = [FBSDKSwizzlerTestObject new];
  [testObject methodWithArgument:@"Foo"
                  secondArgument:@"Foo"
                   thirdArgument:@"Foo"
                  fourthArgument:@"Foo"];
  XCTAssertFalse(
    didInvokeSwizzleBlock,
    "Should not invoke the swizzle block if there are too many arguments"
  );
  XCTAssertEqual(
    testObject.methodWithFourArgumentsCallCount,
    1,
    "Should invoke the original implementation"
  );
}

- (void)testSwizzlingWithNoName
{
  __block BOOL swizzleBlockWasCalled = NO;
  [FBSDKSwizzler swizzleSelector:@selector(methodWithNoArguments)
                         onClass:FBSDKSwizzlerTestObject.class
                       withBlock:^{
                         swizzleBlockWasCalled = YES;
                       }
                           named:nil
                           async:NO];
  FBSDKSwizzlerTestObject *testObject = [FBSDKSwizzlerTestObject new];
  [testObject methodWithNoArguments];
  XCTAssertFalse(
    swizzleBlockWasCalled,
    "Should not invoke the swizzle block for an unnamed swizzle"
  );
  XCTAssertEqual(
    testObject.methodWithNoArgumentsCallCount,
    1,
    "Should invoke the original implementation once per method call"
  );
}

- (void)testUnswizzling
{
  __block BOOL swizzleBlockWasCalled = NO;
  [FBSDKSwizzler swizzleSelector:@selector(methodToUnswizzle)
                         onClass:FBSDKSwizzlerTestObject.class
                       withBlock:^{
                         swizzleBlockWasCalled = YES;
                       }
                           named:self.name
                           async:NO];
  FBSDKSwizzlerTestObject *testObject = [FBSDKSwizzlerTestObject new];
  [testObject methodToUnswizzle];
  XCTAssertTrue(swizzleBlockWasCalled);

  // Reset the expectation
  swizzleBlockWasCalled = NO;

  [FBSDKSwizzler unswizzleSelector:@selector(methodToUnswizzle)
                           onClass:FBSDKSwizzlerTestObject.class
                             named:self.name];

  [testObject methodToUnswizzle];
  XCTAssertFalse(
    swizzleBlockWasCalled,
    "Should not invoke the swizzle block after the method has been unswizzled"
  );
  XCTAssertEqual(
    testObject.methodToUnswizzleCallCount,
    2,
    "Should invoke the original implementation once per method call"
  );
}

- (void)testConflictingSwizzles
{
  __block int swizzleBlockInvocationCount = 0;
  [FBSDKSwizzler swizzleSelector:@selector(methodToConflict)
                         onClass:FBSDKSwizzlerTestObject.class
                       withBlock:^{
                         XCTFail("Should not call the overridden swizzle block");
                       }
                           named:self.name
                           async:NO];
  [FBSDKSwizzler swizzleSelector:@selector(methodToConflict)
                         onClass:FBSDKSwizzlerTestObject.class
                       withBlock:^{
                         swizzleBlockInvocationCount++;
                       }
                           named:self.name
                           async:NO];
  FBSDKSwizzlerTestObject *testObject = [FBSDKSwizzlerTestObject new];
  [testObject methodToConflict];
  XCTAssertEqual(
    swizzleBlockInvocationCount,
    1,
    "Should override the first swizzle block with the subsequent swizzle block"
  );
  XCTAssertEqual(
    testObject.methodToConflictCallCount,
    1,
    "Should invoke the original implementation once per method call"
  );
}

- (void)testSwizzlingSubclass
{
  __block int swizzleBlockInvocationCount = 0;
  [FBSDKSwizzler swizzleSelector:@selector(methodToOverride)
                         onClass:FBSDKSwizzlerTestObject.class
                       withBlock:^{
                         swizzleBlockInvocationCount++;
                       }
                           named:self.name
                           async:NO];
  FBSDKSwizzlerTestObjectSubclass *testObject = [FBSDKSwizzlerTestObjectSubclass new];
  [testObject methodToOverride];

  XCTAssertEqual(
    swizzleBlockInvocationCount,
    1,
    "Should find the swizzle on the superclass"
  );
}

- (void)testSwizzlingWhenBothSubAndSuperclassAreSwizzled
{
  // Swizzle the superclass
  __block int firstSwizzleBlockCallCount = 0;
  [FBSDKSwizzler swizzleSelector:@selector(methodToSwizzleInSuperAndSubclass)
                         onClass:FBSDKSwizzlerTestObject.class
                       withBlock:^{
                         firstSwizzleBlockCallCount++;
                       }
                           named:self.name
                           async:NO];
  // Swizzle the same method on the subclass
  __block int secondSwizzleBlockCallCount = 0;
  [FBSDKSwizzler swizzleSelector:@selector(methodToSwizzleInSuperAndSubclass)
                         onClass:FBSDKSwizzlerTestObjectSubclass.class
                       withBlock:^{
                         secondSwizzleBlockCallCount++;
                       }
                           named:self.name
                           async:NO];
  FBSDKSwizzlerTestObjectSubclass *testObject = [FBSDKSwizzlerTestObjectSubclass new];
  [testObject methodToSwizzleInSuperAndSubclass];

  XCTAssertEqual(
    firstSwizzleBlockCallCount,
    1,
    "Should call the swizzle block on the superclass"
  );
  XCTAssertEqual(
    secondSwizzleBlockCallCount,
    1,
    "Should call the swizzle block on the subclass"
  );
  XCTAssertEqual(
    testObject.methodToSwizzleInSuperAndSubclassCallCount,
    2,
    "Should call the original method on the superclass and subclass"
  );
}

@end
