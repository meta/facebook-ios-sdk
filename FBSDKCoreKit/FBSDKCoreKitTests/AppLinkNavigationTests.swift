/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSDKCoreKit

import TestTools

final class AppLinkNavigationTests: XCTestCase {

  struct AppLinkUrlPayload: Codable {
    let userAgent: String
    let version: String
    let extras: [String: String]
    let targetUrl: URL?

    enum CodingKeys: String, CodingKey {
      case userAgent = "user_agent"
      case version
      case extras
      case targetUrl = "target_url"
    }
  }

  // swiftlint:disable implicitly_unwrapped_optional
  var target: AppLinkTarget!
  var emptyAppLink: AppLink!
  var eventPoster: TestMeasurementEvent!
  var resolver: TestAppLinkResolver!
  var settings: TestSettings!
  fileprivate var urlOpener: URLOpener!
  var navigation: AppLinkNavigation!
  // swiftlint:enable implicitly_unwrapped_optional

  override func setUp() {
    super.setUp()

    target = AppLinkTarget(url: .usingHost1, appStoreId: "123", appName: "ExampleApp")
    emptyAppLink = AppLink(sourceURL: nil, targets: [], webURL: nil)
    eventPoster = TestMeasurementEvent()
    resolver = TestAppLinkResolver()
    settings = TestSettings()
    settings.sdkVersion = "19.0.1"
    urlOpener = URLOpener(canOpenURL: true)
    AppLinkNavigation.defaultResolver = resolver

    AppLinkNavigation.setDependencies(
      .init(
        settings: settings,
        urlOpener: urlOpener,
        appLinkEventPoster: eventPoster,
        appLinkResolver: resolver
      )
    )

    navigation = AppLinkNavigation(
      appLink: emptyAppLink,
      extras: [:],
      appLinkData: [:]
    )
  }

  override func tearDown() {
    target = nil
    emptyAppLink = nil
    eventPoster = nil
    resolver = nil
    settings = nil
    urlOpener = nil
    navigation = nil

    AppLinkNavigation.resetDependencies()

    super.tearDown()
  }

  func testDefaultResolver() {
    AppLinkNavigation.resetDependencies()
    XCTAssertIdentical(
      AppLinkNavigation.defaultResolver,
      WebViewAppLinkResolver.shared,
      "Should use the shared webview app link resolver by default"
    )
  }

  func testSettingDefaultResolver() {
    let resolver = AppLinkResolver()
    AppLinkNavigation.defaultResolver = resolver

    XCTAssertIdentical(
      AppLinkNavigation.defaultResolver,
      resolver,
      "Should be able to set the default app link resolver"
    )
    XCTAssertIdentical(
      AppLinkNavigation.appLinkResolver,
      resolver,
      "Should set the underlying resolver when setting the default"
    )
  }

  func testCreatingWithEmptyAppLink() {
    XCTAssertNotNil(
      navigation,
      "Should be able to create an app link without verifying anything about it at all"
    )
  }

  func testCallbackAppLinkData() {
    XCTAssertEqual(
      AppLinkNavigation.callbackAppLinkData(forApp: "foo", url: "bar"),
      ["referer_app_link": ["app_name": "foo", "url": "bar"]],
      "Should produce the expected app link callback data"
    )
  }

  // MARK: - Dependencies Configuration

  func testDefaultTypeDependencies() throws {
    AppLinkNavigation.resetDependencies()
    XCTAssertThrowsError(try AppLinkNavigation.getDependencies(), .defaultDependencies)
  }

  func testCustomTypeDependencies() throws {
    let dependencies = try AppLinkNavigation.getDependencies()

    XCTAssertIdentical(
      dependencies.settings as AnyObject,
      settings,
      .customDependency(for: "settings sharing")
    )

    XCTAssertIdentical(
      dependencies.urlOpener as AnyObject,
      urlOpener,
      .customDependency(for: "opening urls")
    )

    XCTAssertTrue(
      dependencies.appLinkEventPoster is TestMeasurementEvent,
      .customDependency(for: "event posting")
    )

    XCTAssertIdentical(
      dependencies.appLinkResolver as AnyObject,
      resolver,
      .customDependency(for: "resolving app links")
    )
  }

  // MARK: - Link Creation

  func testAppLinkWithTargetUrl() {
    do {
      let url = try XCTUnwrap(navigation.appLinkURL(targetURL: .usingHost1))
      let payload = decodedPayload(url: url)

      XCTAssertEqual(payload?.userAgent, "FBSDK \(FBSDK_VERSION_STRING)")
      XCTAssertEqual(payload?.version, "1.0")
      XCTAssertEqual(payload?.extras, [:])
      XCTAssertNil(payload?.targetUrl)
    } catch {
      XCTAssertNil(
        error,
        "Should not populate an error when creating an app link with a valid target url"
      )
    }
  }

  func testAppLinkWithTargetUrlWithValidStartingAppLink() {
    let appLink = AppLink(sourceURL: .usingHost1, targets: [target], webURL: .usingHost1)
    navigation = AppLinkNavigation(
      appLink: appLink, extras: [:], appLinkData: [:]
    )
    do {
      let url = try XCTUnwrap(navigation.appLinkURL(targetURL: .usingHost1))
      let payload = decodedPayload(url: url)

      XCTAssertEqual(payload?.userAgent, "FBSDK \(FBSDK_VERSION_STRING)")
      XCTAssertEqual(payload?.version, "1.0")
      XCTAssertEqual(payload?.extras, [:])
      XCTAssertEqual(payload?.targetUrl, .usingHost1)
    } catch {
      XCTAssertNil(
        error,
        "Should not populate an error when creating an app link with a valid target url"
      )
    }
  }

  func testAppLinkWithTargetUrlWithInvalidStartingAppLinkData() {
    navigation = AppLinkNavigation(
      appLink: emptyAppLink, extras: [:], appLinkData: ["foo": Any.self]
    )

    XCTAssertThrowsError(
      try navigation.appLinkURL(targetURL: .usingHost1),
      "An error is thrown when a valid url is passed but bad app link data is provided"
    )
  }

  func testAppLinkWithTargetUrlWithValidStartingAppLinkData() {
    let appLinkData = ["user_agent": "foo", "version": "bar"]
    navigation = AppLinkNavigation(
      appLink: emptyAppLink, extras: ["some": "extra"], appLinkData: appLinkData
    )

    do {
      let url = try XCTUnwrap(navigation.appLinkURL(targetURL: .usingHost1))
      let payload = decodedPayload(url: url)

      XCTAssertEqual(payload?.userAgent, "foo")
      XCTAssertEqual(payload?.version, "bar")
      XCTAssertEqual(payload?.extras, ["some": "extra"])
      XCTAssertNil(payload?.targetUrl)
    } catch {
      XCTAssertNil(
        error,
        "Should not populate an error when creating an app link with a valid target url"
      )
    }
  }

  // MARK: - Posting Navigation Events

  func testPostingNavigationEventWithTypeApp() {
    navigation.postNavigateEventNotification(
      targetURL: nil,
      error: nil,
      navigationType: .app
    )
    XCTAssertEqual(
      eventPoster.capturedEventName,
      AppLinkNavigateOutEventName,
      "Should post a notification with the expected event name"
    )
    XCTAssertEqual(
      eventPoster.capturedArgs,
      ["type": "app", "success": "1"],
      "Post an event with type 'app' should be considered a success"
    )
  }

  func testPostingNavigationEventWithTypeBrowser() {
    navigation.postNavigateEventNotification(
      targetURL: nil,
      error: nil,
      navigationType: .browser
    )
    XCTAssertEqual(
      eventPoster.capturedEventName,
      AppLinkNavigateOutEventName,
      "Should post a notification with the expected event name"
    )
    XCTAssertEqual(
      eventPoster.capturedArgs,
      ["type": "web", "success": "1"],
      "Post an event with type 'browser' should be considered a success"
    )
  }

  func testPostingNavigationEventWithTypeFailure() {
    navigation.postNavigateEventNotification(
      targetURL: nil,
      error: nil,
      navigationType: .failure
    )
    XCTAssertEqual(
      eventPoster.capturedEventName,
      AppLinkNavigateOutEventName,
      "Should post a notification with the expected event name"
    )
    XCTAssertEqual(
      eventPoster.capturedArgs,
      ["type": "fail", "success": "0"],
      "Post an event with type 'failure' should be considered a failure"
    )
  }

  func testPostingNavigationEventWithAppLink() {
    let appLink = AppLink(sourceURL: .usingHost1, targets: [target], webURL: .usingHost1)
    navigation = AppLinkNavigation(
      appLink: appLink, extras: [:], appLinkData: [:]
    )

    navigation.postNavigateEventNotification(
      targetURL: nil,
      error: nil,
      navigationType: .app
    )
    XCTAssertEqual(
      eventPoster.capturedEventName,
      AppLinkNavigateOutEventName,
      "Should post a notification with the expected event name"
    )
    XCTAssertEqual(
      eventPoster.capturedArgs["sourceHost"],
      URL.usingHost1.host,
      "A navigation event notification should include information about the app link"
    )
    XCTAssertEqual(
      eventPoster.capturedArgs["sourceScheme"],
      URL.usingHost1.scheme,
      "A navigation event notification should include information about the app link"
    )
    XCTAssertEqual(
      eventPoster.capturedArgs["sourceURL"],
      URL.usingHost1.absoluteString,
      "A navigation event notification should include information about the app link"
    )
  }

  func testPostingNavigationEventWithError() {
    navigation.postNavigateEventNotification(
      targetURL: nil,
      error: SampleError(),
      navigationType: .app
    )
    XCTAssertEqual(
      eventPoster.capturedEventName,
      AppLinkNavigateOutEventName,
      "Should post a notification with the expected event name"
    )
    XCTAssertEqual(
      eventPoster.capturedArgs["error"],
      "The operation couldn’t be completed. (TestTools.SampleError error 1.)",
      "A navigation event notification should include information about any errors"
    )
    XCTAssertEqual(
      eventPoster.capturedArgs["success"],
      "1",
      "A navigation event notification should be considered successful even if there's an error"
    )
  }

  func testPostingNavigationEventWithBackToReferrer() {
    let appLink = AppLink(sourceURL: nil, targets: [], webURL: nil, isBackToReferrer: true)
    navigation = AppLinkNavigation(
      appLink: appLink, extras: [:], appLinkData: [:]
    )

    navigation.postNavigateEventNotification(
      targetURL: nil,
      error: nil,
      navigationType: .app
    )

    XCTAssertEqual(
      eventPoster.capturedEventName,
      AppLinkNavigateBackToReferrerEventName,
      "A navigation event notification should be indicate if the app link points back to the referrer"
    )
  }

  // MARK: - Navigation Type

  func testNavigationTypeWithoutTarget() {
    XCTAssertEqual(
      navigation.navigationType(for: []),
      .failure,
      "The navigation type for an empty list of targets should be a failure"
    )
  }

  func testNavigationTypeWithInvalidTargetWithoutWebUrl() {
    var url = URL(string: "invalid url")
    #if swift(>=5.9)
    if #available(iOS 17.0, *) {
      url = URL(string: "invalid url", encodingInvalidCharacters: false)
    }
    #endif
    let target = AppLinkTarget(url: url, appStoreId: nil, appName: name)
    let appLink = AppLink(sourceURL: nil, targets: [target], webURL: nil)
    navigation = AppLinkNavigation(appLink: appLink, extras: [:], appLinkData: [:])

    XCTAssertEqual(
      navigation.navigationType(for: [target]),
      .failure,
      "The navigation type when there is an invalid target and no web url should be 'failure'"
    )
  }

  func testNavigationTypeWithValidTargetWithoutWebUrl() {
    let target = AppLinkTarget(url: .usingHost1, appStoreId: nil, appName: name)
    let appLink = AppLink(sourceURL: nil, targets: [target], webURL: nil)
    navigation = AppLinkNavigation(appLink: appLink, extras: [:], appLinkData: [:])

    XCTAssertEqual(
      navigation.navigationType(for: [target]),
      .app,
      "The navigation type when there is a valid target and no web url should be 'app'"
    )
  }

  func testNavigationTypeWithValidTargetWithWebUrl() {
    let target = AppLinkTarget(url: .usingHost1, appStoreId: nil, appName: name)
    let appLink = AppLink(sourceURL: nil, targets: [target], webURL: .usingHost1)
    navigation = AppLinkNavigation(appLink: appLink, extras: [:], appLinkData: [:])

    XCTAssertEqual(
      navigation.navigationType(for: [target]),
      .app,
      "The navigation type when there is a valid target and a web url should be 'app'"
    )
  }

  func testNavigationTypeWithInvalidTargetWithWebUrl() {
    var url = URL(string: "invalid url")
    #if swift(>=5.9)
    if #available(iOS 17.0, *) {
      url = URL(string: "invalid url", encodingInvalidCharacters: false)
    }
    #endif
    let target = AppLinkTarget(url: url, appStoreId: nil, appName: name)
    let appLink = AppLink(sourceURL: nil, targets: [target], webURL: .usingHost1)
    navigation = AppLinkNavigation(appLink: appLink, extras: [:], appLinkData: [:])

    XCTAssertEqual(
      navigation.navigationType(for: [target]),
      .browser,
      "The navigation type when there is an invalid target and a web url should be 'browser'"
    )
  }

  // MARK: - Navigating

  func testSuccessfullyNavigatingWithTargetWithoutWebUrl() {
    urlOpener.stubOpenSuccess(host: .host1, succeeds: true)
    let target = AppLinkTarget(url: .usingHost1, appStoreId: nil, appName: name)
    let appLink = AppLink(sourceURL: nil, targets: [target], webURL: nil)

    navigation = AppLinkNavigation(appLink: appLink, extras: [:], appLinkData: [:])
    urlOpener.stubNavigation(navigation: navigation)
    urlOpener.stubNavigationType(navType: .app)

    let handler: (AppLinkNavigationType, Error?) -> Void = { navType, error in
      XCTAssertEqual(navType, .app, "Should return the correct navigation type")
      XCTAssertNil(
        error,
        "Should return nil error"
      )
      XCTAssertNotNil(
        self.urlOpener.capturedOpenURL,
        "Should create an open a url for a valid target"
      )
      XCTAssertEqual(
        self.urlOpener.capturedOpenURL?.absoluteString,
        self.eventPoster.capturedArgs["outputURL"],
        "Should post a notification with the url that was opened"
      )
    }
    urlOpener.stubHandler(handler: handler)
    navigation.navigate(handler: nil)
  }

  func testUnsuccessfullyNavigatingWithTargetWithWebUrl() {
    urlOpener.stubOpenSuccess(host: .host1, succeeds: false)
    urlOpener.stubOpenSuccess(host: .host2, succeeds: true)
    let target = AppLinkTarget(url: .usingHost1, appStoreId: nil, appName: name)
    let appLink = AppLink(sourceURL: nil, targets: [target], webURL: .usingHost2)

    navigation = AppLinkNavigation(appLink: appLink, extras: [:], appLinkData: [:])
    urlOpener.stubNavigation(navigation: navigation)
    urlOpener.stubNavigationType(navType: .browser)
    let handler: (AppLinkNavigationType, Error?) -> Void = { navType, error in
      XCTAssertEqual(navType, .browser, "Should return the correct navigation type")
      XCTAssertNil(
        error,
        "Should return nil error"
      )
      XCTAssertNotNil(
        self.urlOpener.capturedOpenURL,
        "Should create an open a url for a valid target"
      )
      XCTAssertEqual(
        URL.usingHost2.absoluteString,
        self.eventPoster.capturedArgs["outputURL"],
        "Should post a notification with the url that was opened"
      )
    }
    urlOpener.stubHandler(handler: handler)
    navigation.navigate(handler: nil)
  }

  func testUnsuccessfullyNavigatingWithoutTargetAndNoWebURL() {
    let appLink = AppLink(sourceURL: nil, targets: [], webURL: nil)
    navigation = AppLinkNavigation(appLink: appLink, extras: [:], appLinkData: [:])
    let handler: (AppLinkNavigationType, Error?) -> Void = { navType, error in
      XCTAssertEqual(
        navType,
        .failure,
        "A correct navigation type is returned when there are not targets, no web url"
      )
      XCTAssertNil(
        error,
        "Should return nil error"
      )
    }
    navigation.navigate(handler: handler)
  }

  func testUnsuccessfullyNavigatingWithoutTargetAndWebURL() {
    let appLink = AppLink(sourceURL: nil, targets: [], webURL: .usingHost1)
    let appLinkData = ["bad link data": Date()]
    navigation = AppLinkNavigation(appLink: appLink, extras: [:], appLinkData: appLinkData)

    let handler: (AppLinkNavigationType, Error?) -> Void = { navType, error in
      XCTAssertEqual(
        navType,
        .failure,
        "A correct navigation type is returned when there are not targets, no web url"
      )
      XCTAssertNotNil(
        error,
        "Should return an error"
      )
    }
    navigation.navigate(handler: handler)
  }

  func testUnsuccessfullyNavigatingWithTargetAndBadLinkData() {
    let target = AppLinkTarget(url: .usingHost1, appStoreId: nil, appName: name)
    let appLink = AppLink(sourceURL: nil, targets: [target], webURL: nil)
    let appLinkData = ["bad link data": Date()]
    navigation = AppLinkNavigation(appLink: appLink, extras: [:], appLinkData: appLinkData)

    let handler: (AppLinkNavigationType, Error?) -> Void = { navType, error in
      XCTAssertEqual(
        navType,
        .failure,
        "A correct navigation type is returned when there are not targets, no web url"
      )
      XCTAssertNotNil(
        error,
        "Should return an error"
      )
    }
    navigation.navigate(handler: handler)
  }

  func testNavigatingToUrlWithoutAppLink() {
    let expectation = self.expectation(description: name)
    AppLinkNavigation.navigate(to: .usingHost1) { _, _ in
      expectation.fulfill()
    }

    // The captured completion itself is dispatched asynchronously to the main thread
    // so we can delay a tick here to make sure it's complete
    DispatchQueue.main.async {
      self.resolver.capturedCompletion?(nil, nil)
    }

    waitForExpectations(timeout: 1, handler: nil)
  }

  func testNavigatingToUrlWithAppLink() {
    let expectation = self.expectation(description: name)
    var callbackNavigationType: AppLinkNavigationType?
    var callbackError: Error?

    AppLinkNavigation.navigate(to: .usingHost1) { potentialNavigationType, potentialError in
      callbackNavigationType = potentialNavigationType
      callbackError = potentialError
      expectation.fulfill()
    }

    let appLink = AppLink(sourceURL: .usingHost1, targets: [], webURL: nil)

    // The captured completion itself is dispatched asynchronously to the main thread
    // so we can delay a tick here to make sure it's complete
    DispatchQueue.main.async {
      self.resolver.capturedCompletion?(appLink, nil)
    }
    waitForExpectations(timeout: 1, handler: nil)

    XCTAssertEqual(callbackNavigationType, .failure)
    XCTAssertNil(callbackError)
  }

  func testNavigatingToUrlWithError() {
    let expectation = self.expectation(description: name)
    var callbackNavigationType: AppLinkNavigationType?
    var callbackError: Error?

    AppLinkNavigation.navigate(to: .usingHost1) { potentialNavigationType, potentialError in
      callbackNavigationType = potentialNavigationType
      callbackError = potentialError
      expectation.fulfill()
    }

    let appLink = AppLink(sourceURL: .usingHost1, targets: [], webURL: nil)

    // The captured completion itself is dispatched asynchronously to the main thread
    // so we can delay a tick here to make sure it's complete
    DispatchQueue.main.async {
      self.resolver.capturedCompletion?(
        appLink,
        NSError(domain: "foo", code: 0, userInfo: nil)
      )
    }
    waitForExpectations(timeout: 1, handler: nil)

    XCTAssertEqual(callbackNavigationType, .failure)
    XCTAssertNotNil(callbackError)
  }

  // MARK: - Resolving

  func testResolvingAppLinkWithMissingDestination() {
    var didInvokeCompletion = false
    AppLinkNavigation.resolveAppLink(.usingHost1) { _, _ in
      didInvokeCompletion = true
    }
    resolver.capturedCompletion?(nil, nil)

    XCTAssertEqual(
      resolver.capturedURL,
      .usingHost1,
      "Should resolve using the provided url"
    )
    XCTAssertTrue(didInvokeCompletion)
  }

  // MARK: - Helpers

  func decodedPayload(
    url: URL,
    file: StaticString = #file,
    line: UInt = #line
  ) -> AppLinkUrlPayload? {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems,
      let data = queryItems.first?.value?.data(using: .utf8),
      let payload = try? JSONDecoder().decode(AppLinkUrlPayload.self, from: data)
    else {
      XCTFail("Could not decode the payload from the query item", file: file, line: line)
      return nil
    }

    return payload
  }
}

// MARK: - Assumptions

// swiftformat:disable extensionaccesscontrol
fileprivate extension String {
  static let defaultDependencies = "AppLinkNavigation has no type dependencies by default"

  static func customDependency(for type: String) -> String {
    "AppLinkNavigation uses a custom \(type) type dependency when provided"
  }
}

// MARK: - Test Values

fileprivate extension URL {
  // swiftlint:disable force_unwrapping
  static let usingHost1 = URL(string: "https://\(String.host1)/")!
  static let usingHost2 = URL(string: "https://\(String.host2)/")!
  // swiftlint:enable force_unwrapping
}

fileprivate extension String {
  static let host1 = "host1.com"
  static let host2 = "host2.com"
}

// MARK: - Custom Test Doubles

extension AppLinkNavigationTests {

  fileprivate final class URLOpener: _InternalURLOpener {
    var capturedOpenURL: URL?
    var openSuccessStubsByHost = [String: Bool]()
    var canOpenURL: Bool
    var handler: AppLinkNavigationBlock?
    var navType: AppLinkNavigationType
    var nagivation: AppLinkNavigation?

    init(canOpenURL: Bool = false) {
      self.canOpenURL = canOpenURL
      navType = .app
    }

    fileprivate func stubOpenSuccess(host: String, succeeds: Bool) {
      openSuccessStubsByHost[host] = succeeds
    }

    fileprivate func stubHandler(handler: AppLinkNavigationBlock?) {
      self.handler = handler
    }

    fileprivate func stubNavigationType(navType: AppLinkNavigationType) {
      self.navType = navType
    }

    fileprivate func stubNavigation(navigation: AppLinkNavigation) {
      nagivation = navigation
    }

    fileprivate func canOpen(_ url: URL) -> Bool { canOpenURL }

    fileprivate func open(
      _ url: URL,
      options: [UIApplication.OpenExternalURLOptionsKey: Any] = [:],
      completionHandler completion: (
        (Bool) -> Void)? = nil
    ) {
      capturedOpenURL = url

      guard
        let host = url.host,
        let result = openSuccessStubsByHost[host]
      else {
        fatalError("URL must have a host and an opening success stub: \(url.absoluteString)")
      }

      var openedUrl = url
      if !result {
        openedUrl = .usingHost2
      }
      nagivation?.postNavigateEventNotification(targetURL: openedUrl, error: nil, navigationType: navType)
      handler?(navType, nil)
    }
  }
}
