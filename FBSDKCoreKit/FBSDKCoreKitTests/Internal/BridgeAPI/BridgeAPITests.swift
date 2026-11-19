/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSDKCoreKit
import SafariServices

import TestTools
import XCTest

final class BridgeAPITests: XCTestCase {

  let sampleSource = "com.example"
  let sampleAnnotation = "foo"

  let sampleURL = SampleURLs.valid
  let validBridgeResponseURL = URL(string: "http://bridge")!

  // swiftlint:disable implicitly_unwrapped_optional
  var logger: TestLogger!
  var urlOpener: TestInternalURLOpener!
  var responseFactory: TestBridgeAPIResponseFactory!
  var frameworkLoader: TestDylibResolver!
  var appURLSchemeProvider: TestInternalUtility!
  var errorFactory: TestErrorFactory!
  var api: _BridgeAPI!
  // swiftlint:enable implicitly_unwrapped_optional

  override func setUp() {
    super.setUp()

    FBSDKLoginManager.resetTestEvidence()

    logger = TestLogger(loggingBehavior: .developerErrors)
    urlOpener = TestInternalURLOpener()
    responseFactory = TestBridgeAPIResponseFactory()
    appURLSchemeProvider = TestInternalUtility()
    errorFactory = TestErrorFactory()

    configureSDK()

    api = _BridgeAPI(
      logger: logger,
      urlOpener: urlOpener,
      bridgeAPIResponseFactory: responseFactory,
      appURLSchemeProvider: appURLSchemeProvider,
      errorFactory: errorFactory
    )

    TestBackgroundEventLogger.setDependencies(
      .init(
        infoDictionaryProvider: TestBundle(),
        eventLogger: TestAppEvents()
      )
    )
  }

  override func tearDown() {
    logger = nil
    urlOpener = nil
    responseFactory = nil
    frameworkLoader = nil
    appURLSchemeProvider = nil
    errorFactory = nil
    api = nil

    FBSDKLoginManager.resetTestEvidence()

    super.tearDown()
  }

  func configureSDK() {
    let backgroundEventLogger = TestBackgroundEventLogger()
    let serverConfigurationProvider = TestServerConfigurationProvider(
      configuration: ServerConfigurationFixtures.defaultConfiguration
    )
    let components = TestCoreKitComponents.makeComponents(
      backgroundEventLogger: backgroundEventLogger,
      serverConfigurationProvider: serverConfigurationProvider
    )
    let delegate = ApplicationDelegate(
      components: components,
      configurator: TestCoreKitConfigurator(components: components)
    )
    // Run deferred SDK setup synchronously so there is no dependency on a rendered frame.
    delegate.scheduleAfterFirstFrame = { $0() }
    delegate.initializeSDK()
  }

  // MARK: - Dependencies

  func testDefaultDependencies() throws {
    XCTAssertIdentical(
      _BridgeAPI.shared.urlOpener as AnyObject,
      CoreUIApplication.shared,
      "Should use the expected concrete url opener by default"
    )
    XCTAssertTrue(
      _BridgeAPI.shared.bridgeAPIResponseFactory is _BridgeAPIResponseFactory,
      "Should use and instance of the expected concrete response factory type by default"
    )
    XCTAssertTrue(
      _BridgeAPI.shared.appURLSchemeProvider is InternalUtility,
      "Should use the expected internal utility type by default"
    )

    let reporter = try _ErrorFactory.getDependencies().reporter
    XCTAssertIdentical(
      reporter,
      ErrorReporter.shared,
      "Should use the shared error reporter by default"
    )
  }

  func testCreatingWithDependencies() {
    XCTAssertEqual(
      api.logger as? TestLogger,
      logger,
      "Should be able to create a bridge api with a specific logger"
    )
    XCTAssertEqual(
      api.urlOpener as? TestInternalURLOpener,
      urlOpener,
      "Should be able to create a bridge api with a specific url opener"
    )
    XCTAssertTrue(
      api.bridgeAPIResponseFactory is TestBridgeAPIResponseFactory,
      "Should be able to create a bridge api with a specific response factory"
    )
    XCTAssertIdentical(
      api.errorFactory,
      errorFactory,
      "Should be able to create a bridge API instance with an error factory"
    )
  }

  // MARK: - Bridge Request Cancellation

  func testCancellingBridgeRequestClearsStateBeforeCallingCompletion() {
    let request = TestBridgeAPIRequest(url: sampleURL)
    var completionCount = 0
    api.open(request, useSafariViewController: false, from: nil) { [self] response in
      completionCount += 1
      XCTAssertTrue(response.isCancelled)
      XCTAssertIdentical(response.request, request)
      XCTAssertNil(api.pendingRequest)
      XCTAssertNil(api.pendingRequestCompletionBlock)
      if completionCount == 1 {
        api.cancelBridgeRequest()
      }
    }

    api.cancelBridgeRequest()

    XCTAssertEqual(completionCount, 1)
  }

  func testCancellingBridgeRequestPreservesRequestOpenedByCompletion() {
    let originalRequest = TestBridgeAPIRequest(url: sampleURL)
    let newRequest = TestBridgeAPIRequest(url: sampleURL)
    var newCompletionCount = 0
    api.open(originalRequest, useSafariViewController: false, from: nil) { [self] response in
      XCTAssertTrue(response.isCancelled)
      XCTAssertIdentical(response.request, originalRequest)
      api.open(newRequest, useSafariViewController: false, from: nil) { newResponse in
        XCTAssertTrue(newResponse.isCancelled)
        XCTAssertIdentical(newResponse.request, newRequest)
        newCompletionCount += 1
      }
    }

    api.cancelBridgeRequest()

    XCTAssertIdentical(api.pendingRequest, newRequest)
    XCTAssertNotNil(api.pendingRequestCompletionBlock)
    XCTAssertEqual(newCompletionCount, 0)
    api.cancelBridgeRequest()
    XCTAssertEqual(newCompletionCount, 1)
    XCTAssertNil(api.pendingRequest)
    XCTAssertNil(api.pendingRequestCompletionBlock)
  }

  func testBecomingActivePreservesRequestOpenedByCancellationCompletion() throws {
    let originalRequest = TestBridgeAPIRequest(url: sampleURL)
    let newRequest = TestBridgeAPIRequest(url: sampleURL)
    var completionCount = 0
    var newCompletionCount = 0
    appURLSchemeProvider.appURLScheme = try XCTUnwrap(validBridgeResponseURL.scheme)
    api.open(originalRequest, useSafariViewController: false, from: nil) { [self] response in
      completionCount += 1
      XCTAssertTrue(response.isCancelled)
      api.open(newRequest, useSafariViewController: false, from: nil) { newResponse in
        newCompletionCount += 1
        XCTAssertFalse(newResponse.isCancelled)
        XCTAssertIdentical(newResponse.request, newRequest)
      }
    }
    api.applicationDidEnterBackground(UIApplication.shared)

    api.applicationDidBecomeActive(UIApplication.shared)

    XCTAssertEqual(completionCount, 1)
    XCTAssertIdentical(api.pendingRequest, newRequest)
    XCTAssertNotNil(api.pendingRequestCompletionBlock)
    XCTAssertEqual(newCompletionCount, 0)
    XCTAssertTrue(
      api.application(
        UIApplication.shared,
        open: validBridgeResponseURL,
        sourceApplication: sampleSource,
        annotation: nil
      )
    )
    XCTAssertEqual(newCompletionCount, 1)
    XCTAssertNil(api.pendingRequest)
    XCTAssertNil(api.pendingRequestCompletionBlock)
  }

  // MARK: - Lifecycle Methods

  // MARK: Will Resign Active

  func testWillResignActiveWithoutAuthSessionWithoutAuthSessionState() {
    api.applicationWillResignActive(UIApplication.shared)

    XCTAssertEqual(
      api.authenticationSessionState,
      .none,
      "Should not modify the auth session state if there is no auth session"
    )
  }

  func testWillResignActiveWithAuthSessionWithoutAuthSessionState() {
    api.authenticationSession = AuthenticationSessionSpy.makeDefaultSpy()

    api.applicationWillResignActive(UIApplication.shared)

    XCTAssertEqual(
      api.authenticationSessionState,
      .none,
      "Should not modify the auth session state unless the current state is 'started'"
    )
  }

  func testWillResignActiveWithAuthSessionWithNonStartedAuthSessionState() {
    api.authenticationSession = AuthenticationSessionSpy.makeDefaultSpy()

    [
      AuthenticationSessionState.none,
      .showAlert,
      .showWebBrowser,
      .canceledBySystem,
    ]
      .shuffled()
      .forEach { state in
        api.authenticationSessionState = state
        api.applicationWillResignActive(UIApplication.shared)
        XCTAssertEqual(
          api.authenticationSessionState,
          state,
          "Should not modify the auth session state unless the current state is 'started'"
        )
      }
  }

  func testWillResignActiveWithAuthSessionWithStartedAuthSessionState() {
    api.authenticationSession = AuthenticationSessionSpy.makeDefaultSpy()

    api.authenticationSessionState = .started
    api.applicationWillResignActive(UIApplication.shared)
    XCTAssertEqual(
      api.authenticationSessionState,
      .showAlert,
      "Should change the auth state from 'started' to 'alert' before resigning activity"
    )
  }

  // MARK: Did Become Active

  func testUpdatingShowAlertStateForDidBecomeActiveWithoutAuthSession() {
    [
      AuthenticationSessionState.none,
      .started,
      .showAlert,
      .showWebBrowser,
      .canceledBySystem,
    ]
      .shuffled()
      .forEach { state in
        api.authenticationSessionState = state
        api.applicationDidBecomeActive(UIApplication.shared)
        XCTAssertEqual(
          api.authenticationSessionState,
          state,
          "Should not modify the auth session state if there is no auth session"
        )
      }
  }

  func testUpdatingShowAlertStateForDidBecomeActive() {
    let authSessionSpy = AuthenticationSessionSpy.makeDefaultSpy()
    api.authenticationSession = authSessionSpy
    api.authenticationSessionState = .showAlert

    api.applicationDidBecomeActive(UIApplication.shared)

    XCTAssertEqual(
      api.authenticationSessionState,
      .showWebBrowser,
      "Becoming active when the state is 'showAlert' should set the state to be 'showWebBrowser'"
    )
    XCTAssertEqual(
      authSessionSpy.cancelCallCount,
      0,
      "Becoming active when the state is 'showAlert' should not cancel the session"
    )
    XCTAssertNotNil(
      api.authenticationSession,
      "Becoming active when the state is 'showAlert' should not destroy the session"
    )
  }

  func testUpdatingCancelledBySystemStateForDidBecomeActive() {
    let authSessionSpy = AuthenticationSessionSpy.makeDefaultSpy()
    api.authenticationSession = authSessionSpy
    api.authenticationSessionState = .canceledBySystem

    api.applicationDidBecomeActive(UIApplication.shared)

    XCTAssertEqual(
      api.authenticationSessionState,
      .canceledBySystem,
      "Becoming active when the state is 'canceledBySystem' should not change the state"
    )
    XCTAssertNil(
      api.authenticationSession,
      "Becoming active when the state is 'canceledBySystem' should destroy the session"
    )
    XCTAssertEqual(
      authSessionSpy.cancelCallCount,
      1,
      "Becoming active when the state is 'canceledBySystem' should cancel the session"
    )
  }

  func testCompletingWithCancelledBySystemStateForDidBecomeActive() {
    let authSessionSpy = AuthenticationSessionSpy.makeDefaultSpy()
    api.authenticationSession = authSessionSpy
    api.authenticationSessionState = .canceledBySystem

    var capturedCallbackURL: URL?
    var capturedError: Error?
    api.authenticationSessionCompletionHandler = { callbackURL, error in
      capturedCallbackURL = callbackURL
      capturedError = error
    }

    api.applicationDidBecomeActive(UIApplication.shared)

    XCTAssertNil(
      capturedCallbackURL,
      "A completion triggered by becoming active in a canceled state should not have a callback URL"
    )
    XCTAssertEqual(
      (capturedError as NSError?)?.domain,
      "com.apple.AuthenticationServices.WebAuthenticationSession",
      "A completion triggered by becoming active in a canceled state should include an error"
    )
  }

  // MARK: Did Enter Background

  func testDidEnterBackgroundWithoutAuthSession() {
    api.isActive = true
    api.isExpectingBackground = true

    [
      AuthenticationSessionState.none,
      .started,
      .showAlert,
      .showWebBrowser,
      .canceledBySystem,
    ]
      .shuffled()
      .forEach { state in
        api.authenticationSessionState = state
        api.applicationDidEnterBackground(UIApplication.shared)
        XCTAssertFalse(
          api.isActive,
          "Should mark a bridge api inactive when entering the background"
        )
        XCTAssertFalse(
          api.isExpectingBackground,
          "Should mark a bridge api as not expecting backgrounding when entering the background"
        )
      }
  }

  func testDidEnterBackgroundInShowAlertState() {
    api.authenticationSession = AuthenticationSessionSpy.makeDefaultSpy()
    api.authenticationSessionState = .showAlert

    api.applicationDidEnterBackground(UIApplication.shared)
    XCTAssertEqual(
      api.authenticationSessionState,
      .canceledBySystem,
      "Should cancel the session when entering the background while showing an alert"
    )
  }

  func testDidEnterBackgroundInNonShowAlertState() {
    api.authenticationSession = AuthenticationSessionSpy.makeDefaultSpy()

    [
      AuthenticationSessionState.none,
      .started,
      .showWebBrowser,
      .canceledBySystem,
    ]
      .shuffled()
      .forEach { state in
        api.authenticationSessionState = state
        api.applicationDidEnterBackground(UIApplication.shared)
        XCTAssertEqual(
          api.authenticationSessionState,
          state,
          "Should only modify the auth session state on backgrounding if it is showing an alert"
        )
      }
  }

  // MARK: Did Finish Launching With Options

  func testDidFinishLaunchingWithoutLaunchedURLWithoutSourceApplication() {
    XCTAssertFalse(
      api.application(UIApplication.shared, didFinishLaunchingWithOptions: [:]),
      "Should not consider it a successful launch if there is no launch url or source application"
    )
  }

  func testDidFinishLaunchingWithoutLaunchedUrlWithSourceApplication() {
    let options = [UIApplication.LaunchOptionsKey.sourceApplication: "com.example"]
    XCTAssertFalse(
      api.application(UIApplication.shared, didFinishLaunchingWithOptions: options),
      "Should not consider it a successful launch if there is no launch url"
    )
  }

  func testDidFinishLaunchingWithLaunchedUrlWithoutSourceApplication() {
    let options = [UIApplication.LaunchOptionsKey.url: sampleURL]
    XCTAssertFalse(
      api.application(UIApplication.shared, didFinishLaunchingWithOptions: options),
      "Should not consider it a successful launch if there is no source application"
    )
  }

  func testDidFinishLaunchingWithLaunchedUrlWithSourceApplication() {
    let options: [UIApplication.LaunchOptionsKey: Any] = [
      UIApplication.LaunchOptionsKey.url: sampleURL,
      UIApplication.LaunchOptionsKey.sourceApplication: sampleSource,
      UIApplication.LaunchOptionsKey.annotation: sampleAnnotation,
    ]

    FBSDKLoginManager.stubbedOpenURLSuccess = true

    XCTAssertTrue(
      api.application(UIApplication.shared, didFinishLaunchingWithOptions: options),
      "Should return the success value determined by the login manager's open url method"
    )

    XCTAssertEqual(
      FBSDKLoginManager.capturedOpenURL,
      sampleURL,
      "Should pass the launch url to the login manager"
    )
    XCTAssertEqual(
      FBSDKLoginManager.capturedSourceApplication,
      sampleSource,
      "Should pass the source application to the login manager"
    )
    XCTAssertEqual(
      FBSDKLoginManager.capturedAnnotation,
      sampleAnnotation,
      "Should pass the annotation to the login manager"
    )
  }

  // MARK: - Open URL

  func testOpenURLWithMissingSender() {
    api.open(
      sampleURL,
      sender: nil
    ) { _, _ in }

    XCTAssertTrue(
      api.isExpectingBackground,
      "Should set expecting background to true when opening a URL"
    )
    XCTAssertNil(
      api.pendingURLOpener,
      "Should not set the pending url opener if there is no sender"
    )
  }

  func testOpenURLWithSender() {
    let urlOpener = FBSDKLoginManager()
    api.open(
      sampleURL,
      sender: urlOpener
    ) { _, _ in }

    XCTAssertTrue(api.isExpectingBackground, "Should set expecting background to true when opening a URL")
    XCTAssertIdentical(
      api.pendingURLOpener,
      urlOpener,
      "Should set the pending url opener to the sender"
    )
  }

  func testOpenUrlWhenApplicationOpens() {
    var capturedSuccess = false
    var capturedError: Error?
    api.open(
      sampleURL,
      sender: nil
    ) { success, error in
      capturedSuccess = success
      capturedError = error
    }

    urlOpener.capturedOpenURLCompletion?(true)

    XCTAssertTrue(
      capturedSuccess,
      "Should call the completion handler with the expected value"
    )
    XCTAssertNil(capturedError, "Should not call the completion handler with an error")
  }

  func testOpenUrlWhenApplicationDoesNotOpen() {
    var capturedSuccess = true
    var capturedError: Error?
    api.open(
      sampleURL,
      sender: nil
    ) { success, error in
      capturedSuccess = success
      capturedError = error
    }

    urlOpener.capturedOpenURLCompletion?(false)

    XCTAssertFalse(
      capturedSuccess,
      "Should call the completion handler with the expected value"
    )
    XCTAssertNil(capturedError, "Should not call the completion handler with an error")
  }

  // MARK: - Request completion block

  func testRequestCompletionBlockCalledWithSuccess() {
    let request = TestBridgeAPIRequest(url: sampleURL)
    let responseBlock: BridgeAPIResponseBlock = { _ in
      XCTFail("Should not call the response block when the request completion is called with success")
    }
    api.pendingRequest = request
    api.pendingRequestCompletionBlock = { _ in }

    let completion = api.bridgeAPIRequestCompletionBlock(request: request, completion: responseBlock)

    // With Error
    completion(true, SampleError())
    assertPendingPropertiesNotCleared()

    // Without Error
    completion(true, nil)
    assertPendingPropertiesNotCleared()
  }

  func testRequestCompletionBlockWithNonHttpRequestCalledWithoutSuccessWithError() throws {
    let request = TestBridgeAPIRequest(url: sampleURL, scheme: "file")

    var capturedResponse: BridgeAPIResponse?
    let responseBlock: BridgeAPIResponseBlock = { response in
      capturedResponse = response
    }
    api.pendingRequest = request
    api.pendingRequestCompletionBlock = { _ in }

    let completion = api.bridgeAPIRequestCompletionBlock(request: request, completion: responseBlock)

    // With Error
    completion(false, SampleError())
    assertPendingPropertiesCleared()

    XCTAssertIdentical(
      capturedResponse?.request,
      request,
      "The response should contain the original request"
    )
    let error = try XCTUnwrap(capturedResponse?.error as? TestSDKError)
    XCTAssertEqual(
      error.type,
      .general,
      "The response should contain a general error"
    )
    XCTAssertEqual(
      error.code,
      CoreError.errorAppVersionUnsupported.rawValue,
      "The error should use an app version unsupported error code"
    )
    XCTAssertEqual(
      error.message,
      "the app switch failed because the destination app is out of date",
      "The error should use an appropriate error message"
    )
  }

  func testRequestCompletionBlockWithNonHttpRequestCalledWithoutSuccessWithoutError() throws {
    let request = TestBridgeAPIRequest(url: sampleURL, scheme: "file")

    var capturedResponse: BridgeAPIResponse?
    let responseBlock: BridgeAPIResponseBlock = { response in
      capturedResponse = response
    }
    api.pendingRequest = request
    api.pendingRequestCompletionBlock = { _ in }

    let completion = api.bridgeAPIRequestCompletionBlock(request: request, completion: responseBlock)

    // Without Error
    completion(false, nil)
    assertPendingPropertiesCleared()

    XCTAssertIdentical(
      capturedResponse?.request,
      request,
      "The response should contain the original request"
    )
    let error = try XCTUnwrap(capturedResponse?.error as? TestSDKError)
    XCTAssertEqual(
      error.type,
      .general,
      "The response should contain a general error"
    )
    XCTAssertEqual(
      error.code,
      CoreError.errorAppVersionUnsupported.rawValue,
      "The error should use an app version unsupported error code"
    )
    XCTAssertEqual(
      error.message,
      "the app switch failed because the destination app is out of date",
      "The error should use an appropriate error message"
    )
  }

  func testRequestCompletionBlockWithHttpRequestCalledWithoutSuccessWithError() throws {
    let request = TestBridgeAPIRequest(url: sampleURL, scheme: "https")

    var capturedResponse: BridgeAPIResponse?
    let responseBlock: BridgeAPIResponseBlock = { response in
      capturedResponse = response
    }

    api.pendingRequest = request
    api.pendingRequestCompletionBlock = { _ in }

    let completion = api.bridgeAPIRequestCompletionBlock(request: request, completion: responseBlock)

    // With Error
    completion(false, SampleError())
    assertPendingPropertiesCleared()

    XCTAssertIdentical(
      capturedResponse?.request,
      request,
      "The response should contain the original request"
    )
    let error = try XCTUnwrap(capturedResponse?.error as? TestSDKError)
    XCTAssertEqual(
      error.type,
      .general,
      "The response should contain a general error"
    )
    XCTAssertEqual(
      error.code,
      CoreError.errorBrowserUnavailable.rawValue,
      "The error should use a browser unavailable error code"
    )
    XCTAssertEqual(
      error.message,
      "the app switch failed because the browser is unavailable",
      "The response should use an appropriate error message"
    )
  }

  func testRequestCompletionBlockWithHttpRequestCalledWithoutSuccessWithoutError() throws {
    let request = TestBridgeAPIRequest(url: sampleURL, scheme: "https")

    var capturedResponse: BridgeAPIResponse?
    let responseBlock: BridgeAPIResponseBlock = { response in
      capturedResponse = response
    }

    api.pendingRequest = request
    api.pendingRequestCompletionBlock = { _ in }

    let completion = api.bridgeAPIRequestCompletionBlock(request: request, completion: responseBlock)

    // Without Error
    completion(false, nil)
    assertPendingPropertiesCleared()

    XCTAssertIdentical(
      capturedResponse?.request,
      request,
      "The response should contain the original request"
    )
    let error = try XCTUnwrap(capturedResponse?.error as? TestSDKError)
    XCTAssertEqual(
      error.type,
      .general,
      "The response should contain a general error"
    )
    XCTAssertEqual(
      error.code,
      CoreError.errorBrowserUnavailable.rawValue,
      "The error should use a browser unavailable error code"
    )
    XCTAssertEqual(
      error.message,
      "the app switch failed because the browser is unavailable",
      "The response should use an appropriate error message"
    )
  }

  // MARK: - Safari View Controller Delegate Methods

  func testSafariVcDidFinishWithPendingUrlOpener() throws {
    let urlOpener = FBSDKLoginManager()
    api.pendingURLOpener = urlOpener
    api.safariViewController = TestSafariViewController(url: sampleURL)

    // Setting a pending request so we can assert that it's nilled out upon cancellation
    api.pendingRequest = createSampleTestBridgeAPIRequest()

    // Funny enough there's no check that the safari view controller from the delegate
    // is the same instance stored in the safariViewController property
    let safariViewController = try XCTUnwrap(api.safariViewController)
    api.safariViewControllerDidFinish(safariViewController)

    XCTAssertNil(api.pendingURLOpener, "Should remove the reference to the pending url opener")
    XCTAssertNil(
      api.safariViewController,
      "Should remove the reference to the safari view controller when the delegate method is called"
    )

    XCTAssertNil(api.pendingRequest, "Should cancel the request")
    XCTAssertTrue(
      urlOpener.openURLWasCalled,
      "Should ask the opener to open a url (even though there is not one provided)"
    )
    XCTAssertNil(FBSDKLoginManager.capturedOpenURL, "The url opener should be called with nil arguments")
    XCTAssertNil(FBSDKLoginManager.capturedSourceApplication, "The url opener should be called with nil arguments")
    XCTAssertNil(FBSDKLoginManager.capturedAnnotation, "The url opener should be called with nil arguments")
  }

  func testSafariVcDidFinishWithoutPendingUrlOpener() throws {
    api.safariViewController = TestSafariViewController(url: sampleURL)

    // Setting a pending request so we can assert that it's nilled out upon cancellation
    api.pendingRequest = createSampleTestBridgeAPIRequest()

    // Funny enough there's no check that the safari view controller from the delegate
    // is the same instance stored in the safariViewController property
    let safariViewController = try XCTUnwrap(api.safariViewController)
    api.safariViewControllerDidFinish(safariViewController)

    XCTAssertNil(api.pendingURLOpener, "Should remove the reference to the pending url opener")
    XCTAssertNil(
      api.safariViewController,
      "Should remove the reference to the safari view controller when the delegate method is called"
    )

    XCTAssertNil(api.pendingRequest, "Should cancel the request")
    XCTAssertNil(FBSDKLoginManager.capturedOpenURL, "The url opener should not be called")
    XCTAssertNil(FBSDKLoginManager.capturedSourceApplication, "The url opener should not be called")
    XCTAssertNil(FBSDKLoginManager.capturedAnnotation, "The url opener should not be called")
  }

  // MARK: - ContainerViewController Delegate Methods

  func testViewControllerDidDisappearWithSafariViewController() {
    api.safariViewController = TestSafariViewController(url: sampleURL)
    let container = _ContainerViewController()

    // Setting a pending request so we can assert that it's nilled out upon cancellation
    api.pendingRequest = createSampleTestBridgeAPIRequest()

    api.viewControllerDidDisappear(container, animated: false)

    XCTAssertEqual(
      logger.capturedContents,
      """
      **ERROR**:
      The SFSafariViewController's parent view controller was dismissed.
      This can happen if you are triggering login from a UIAlertController. Instead, make sure your topmost view \
      controller will not be prematurely dismissed.
      """
    )
    XCTAssertNil(api.pendingRequest, "Should cancel the request")
  }

  func testViewControllerDidDisappearWithoutSafariViewController() {
    let container = _ContainerViewController()

    // Setting a pending request so we can assert that it's nilled out upon cancellation
    api.pendingRequest = createSampleTestBridgeAPIRequest()

    api.viewControllerDidDisappear(container, animated: false)

    XCTAssertNotNil(api.pendingRequest, "Should not cancel the request")
    XCTAssertNil(logger.capturedContents, "Expected nothing to be logged")
  }

  // MARK: - Bridge Response URL Handling

  func testHandlingBridgeResponseWithInvalidScheme() {
    stubBridgeApiResponseWithUrlCreation()
    appURLSchemeProvider.appURLScheme = "foo"

    XCTAssertFalse(
      api.handleBridgeAPIResponse(url: sampleURL, sourceApplication: ""),
      "Should not successfully handle bridge api response url with an invalid url scheme"
    )
    assertPendingPropertiesCleared()
  }

  func testHandlingBridgeResponseWithInvalidHost() throws {
    stubBridgeApiResponseWithUrlCreation()
    appURLSchemeProvider.appURLScheme = try XCTUnwrap(sampleURL.scheme)

    XCTAssertFalse(
      api.handleBridgeAPIResponse(url: sampleURL, sourceApplication: ""),
      "Should not successfully handle bridge api response url with an invalid url host"
    )
    assertPendingPropertiesCleared()
  }

  func testHandlingBridgeResponseWithMissingRequest() throws {
    stubBridgeApiResponseWithUrlCreation()
    appURLSchemeProvider.appURLScheme = try XCTUnwrap(validBridgeResponseURL.scheme)

    XCTAssertFalse(
      api.handleBridgeAPIResponse(url: validBridgeResponseURL, sourceApplication: ""),
      "Should not successfully handle bridge api response url with a missing request"
    )
    assertPendingPropertiesCleared()
  }

  func testHandlingBridgeResponseWithMissingCompletionBlock() throws {
    stubBridgeApiResponseWithUrlCreation()
    appURLSchemeProvider.appURLScheme = try XCTUnwrap(validBridgeResponseURL.scheme)
    api.pendingRequest = TestBridgeAPIRequest(url: sampleURL)

    XCTAssertTrue(
      api.handleBridgeAPIResponse(url: validBridgeResponseURL, sourceApplication: ""),
      "Should successfully handle bridge api response url with a missing completion block"
    )
    assertPendingPropertiesCleared()
  }

  func testHandlingBridgeResponseWithBridgeResponse() throws {
    let response = BridgeAPIResponse(
      request: TestBridgeAPIRequest(url: sampleURL),
      responseParameters: [:],
      cancelled: false,
      error: nil
    )
    responseFactory.stubbedResponse = response
    appURLSchemeProvider.appURLScheme = try XCTUnwrap(validBridgeResponseURL.scheme)
    api.pendingRequest = TestBridgeAPIRequest(url: sampleURL)

    var capturedResponse: BridgeAPIResponse?
    api.pendingRequestCompletionBlock = { response in
      capturedResponse = response
    }

    XCTAssertTrue(
      api.handleBridgeAPIResponse(url: validBridgeResponseURL, sourceApplication: ""),
      "Should successfully handle creation of a bridge api response"
    )

    XCTAssertEqual(capturedResponse, response, "Should invoke the completion with the expected bridge api response")
    assertPendingPropertiesCleared()
  }

  func testHandlingBridgeResponseWithBridgeError() throws {
    let response = BridgeAPIResponse(
      request: TestBridgeAPIRequest(url: sampleURL),
      responseParameters: [:],
      cancelled: false,
      error: SampleError()
    )
    responseFactory.stubbedResponse = response
    appURLSchemeProvider.appURLScheme = try XCTUnwrap(validBridgeResponseURL.scheme)
    api.pendingRequest = TestBridgeAPIRequest(url: sampleURL)

    var capturedResponse: BridgeAPIResponse?
    api.pendingRequestCompletionBlock = { response in
      capturedResponse = response
    }

    XCTAssertTrue(
      api.handleBridgeAPIResponse(url: validBridgeResponseURL, sourceApplication: ""),
      "Should retry creation of a bridge api response if the first attempt has an error"
    )
    XCTAssertEqual(capturedResponse, response, "Should invoke the completion with the expected bridge api response")
    assertPendingPropertiesCleared()
  }

  func testHandlingBridgeResponseWithMissingResponseMissingError() throws {
    let response = BridgeAPIResponse(
      request: TestBridgeAPIRequest(url: sampleURL),
      responseParameters: [:],
      cancelled: false,
      error: nil
    )

    responseFactory.stubbedResponse = response
    responseFactory.shouldFailCreation = true
    appURLSchemeProvider.appURLScheme = try XCTUnwrap(validBridgeResponseURL.scheme)
    api.pendingRequest = TestBridgeAPIRequest(url: sampleURL)

    var capturedResponse: BridgeAPIResponse?
    api.pendingRequestCompletionBlock = { response in
      capturedResponse = response
    }

    XCTAssertFalse(
      api.handleBridgeAPIResponse(url: validBridgeResponseURL, sourceApplication: ""),
      "Should return false when a bridge response cannot be created"
    )
    XCTAssertNil(capturedResponse, "Should not invoke pending completion handler")
    assertPendingPropertiesCleared()
  }

  // MARK: - Helpers

  func createSampleTestBridgeAPIRequest() -> TestBridgeAPIRequest {
    TestBridgeAPIRequest(
      url: sampleURL,
      protocolType: FBSDKBridgeAPIProtocolType.web,
      scheme: "1"
    )
  }

  func stubBridgeApiResponseWithUrlCreation() {
    let response = BridgeAPIResponse(
      request: TestBridgeAPIRequest(url: sampleURL),
      responseParameters: [:],
      cancelled: false,
      error: nil
    )
    responseFactory.stubbedResponse = response
  }

  func assertPendingPropertiesCleared(file: StaticString = #file, line: UInt = #line) {
    XCTAssertNil(
      api.pendingRequest,
      "Should clear the pending request",
      file: file,
      line: line
    )
    XCTAssertNil(
      api.pendingRequestCompletionBlock,
      "Should clear the pending request completion block",
      file: file,
      line: line
    )
  }

  func assertPendingPropertiesNotCleared(file: StaticString = #file, line: UInt = #line) {
    XCTAssertNotNil(
      api.pendingRequest,
      "Should not clear the pending request",
      file: file,
      line: line
    )
    XCTAssertNotNil(
      api.pendingRequestCompletionBlock,
      "Should not clear the pending request completion block",
      file: file,
      line: line
    )
  }
}

final class TestSafariViewController: SFSafariViewController {}
