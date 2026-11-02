/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSDKCoreKit

import TestTools
import XCTest

final class ApplicationDelegateAuthenticationTests: XCTestCase {

  // swiftlint:disable implicitly_unwrapped_optional
  var delegate: ApplicationDelegate! // swiftlint:disable:this weak_delegate
  var cache: TokenCache!
  private var keychainStore: TestAuthenticationKeychainStore!
  var dataStore: UserDefaultsSpy!
  var sessionProvider: TestSessionProvider!
  var notificationCenter: NotificationCenter!
  var serverConfigurationProvider: TestServerConfigurationProvider!
  var cachedToken: AuthenticationToken!
  var cachedProfile: Profile!
  // swiftlint:enable implicitly_unwrapped_optional
  var deferredSetup: (() -> Void)?

  override func setUp() {
    super.setUp()

    AuthenticationToken.resetCurrentAuthenticationTokenCache()
    Profile._current = nil
    TestAccessTokenWallet.reset()
    TestAuthenticationRestoreObserver.tokens = []
    _DomainConfiguration.setDefaultDomainInfo()
    keychainStore = TestAuthenticationKeychainStore()
    dataStore = UserDefaultsSpy()
    sessionProvider = TestSessionProvider()
    notificationCenter = NotificationCenter()
    serverConfigurationProvider = TestServerConfigurationProvider()
    let settings = TestSettings()
    cache = TokenCache()
    cache.setDependencies(.init(settings: settings, keychainStore: keychainStore, dataStore: dataStore))
    cachedToken = SampleAuthenticationToken.validToken
    cache.authenticationToken = cachedToken
    cachedProfile = SampleUserProfiles.createValid()
    dataStore.set(
      try? NSKeyedArchiver.archivedData(withRootObject: cachedProfile as Any, requiringSecureCoding: false),
      forKey: Profile.profileUserDefaultsKey
    )
    AuthenticationToken.tokenCache = cache
    let components = TestCoreKitComponents.makeComponents(
      authenticationTokenWallet: AuthenticationToken.self,
      notificationCenter: notificationCenter,
      profileSetter: Profile.self,
      serverConfigurationProvider: serverConfigurationProvider,
      sessionDataTaskProvider: sessionProvider,
      settings: settings,
      tokenCache: cache
    )
    Profile.setDependencies(
      .init(
        accessTokenProvider: TestAccessTokenWallet.self,
        dataStore: dataStore,
        graphRequestFactory: components.graphRequestFactory,
        notificationCenter: components.notificationCenter,
        settings: settings,
        urlHoster: components.urlHoster
      )
    )
    _AuthenticationStatusUtility.configure(
      profileSetter: Profile.self,
      sessionDataTaskProvider: sessionProvider,
      accessTokenWallet: TestAccessTokenWallet.self,
      authenticationTokenWallet: AuthenticationToken.self
    )
    _DomainHandler.sharedInstance().configure(
      domainConfigurationProvider: TestDomainConfigurationManager(domainInfo: nil, shouldExecuteCompletion: true),
      settings: settings,
      dataStore: dataStore,
      graphRequestFactory: components.graphRequestFactory,
      graphRequestConnectionFactory: components.graphRequestConnectionFactory
    )
    delegate = ApplicationDelegate(
      components: components,
      configurator: TestCoreKitConfigurator(components: components)
    )
    delegate.scheduleAfterFirstFrame = { self.deferredSetup = $0 }
    delegate.restoredSessionObserverProvider = { TestAuthenticationRestoreObserver.self }
  }

  override func tearDown() {
    deferredSetup = nil
    delegate = nil
    AuthenticationToken.resetCurrentAuthenticationTokenCache()
    AuthenticationToken.tokenCache = nil
    Profile._current = nil
    Profile.resetDependencies()
    _AuthenticationStatusUtility.resetClassDependencies()
    _DomainConfiguration.resetDefaultDomainInfo()
    TestAccessTokenWallet.reset()
    TestAuthenticationRestoreObserver.tokens = []
    cache = nil
    keychainStore = nil
    dataStore = nil
    sessionProvider = nil
    notificationCenter = nil
    serverConfigurationProvider = nil
    cachedToken = nil
    cachedProfile = nil

    super.tearDown()
  }

  func testInitializeSDKRestoresSessionBeforeFirstFrame() throws {
    delegate.initializeSDK()

    assertSessionRestoredBeforeFirstFrame()
    try XCTUnwrap(deferredSetup)()
    XCTAssertEqual(AuthenticationToken.current?.tokenString, cachedToken.tokenString)
    XCTAssertEqual(keychainStore.dictionaryReadCount, 1)
    XCTAssertTrue(TestAuthenticationRestoreObserver.tokens.isEmpty)
    XCTAssertEqual(sessionProvider.dataTaskCallCount, 0)
  }

  func testDidFinishLaunchingRestoresSessionBeforeFirstFrame() throws {
    XCTAssertTrue(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))

    assertSessionRestoredBeforeFirstFrame()
    try XCTUnwrap(deferredSetup)()
    XCTAssertEqual(TestAuthenticationRestoreObserver.tokens.map(\.tokenString), [cachedToken.tokenString])
    XCTAssertEqual(keychainStore.dictionaryReadCount, 1)
    XCTAssertTrue(serverConfigurationProvider.loadServerConfigurationWasCalled)
    XCTAssertEqual(sessionProvider.dataTaskCallCount, 1)
  }

  func testProfileChangeObserverSeesRestoredAuthenticationToken() {
    var observedToken: AuthenticationToken?
    var observedProfile: Profile?
    let observer = notificationCenter.addObserver(forName: .ProfileDidChange, object: nil, queue: nil) { _ in
      observedToken = AuthenticationToken.current
      observedProfile = Profile.current
    }
    defer { notificationCenter.removeObserver(observer) }

    delegate.initializeSDK()

    XCTAssertEqual(observedToken?.tokenString, cachedToken.tokenString)
    XCTAssertEqual(observedProfile?.userID, cachedProfile.userID)
    XCTAssertNotNil(deferredSetup)
    XCTAssertEqual(sessionProvider.dataTaskCallCount, 0)
  }

  func testLogoutBeforeFirstFrameIsNotRestoredAgain() throws {
    delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil)
    AuthenticationToken.current = nil
    Profile.current = nil
    let readCount = keychainStore.dictionaryReadCount

    try XCTUnwrap(deferredSetup)()

    XCTAssertNil(AuthenticationToken.current)
    XCTAssertNil(Profile.current)
    XCTAssertEqual(keychainStore.dictionaryReadCount, readCount)
    XCTAssertTrue(TestAuthenticationRestoreObserver.tokens.isEmpty)
    XCTAssertEqual(sessionProvider.dataTaskCallCount, 0)
  }

  func testLoginBeforeFirstFrameIsNotReplacedByAnotherCacheRead() throws {
    delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil)
    let newToken = AuthenticationToken(tokenString: "new-token", nonce: "new-nonce")
    let newProfile = SampleUserProfiles.createValid(userID: "new-user")
    AuthenticationToken.current = newToken
    Profile.current = newProfile
    let readCount = keychainStore.dictionaryReadCount

    try XCTUnwrap(deferredSetup)()

    XCTAssertIdentical(AuthenticationToken.current, newToken)
    XCTAssertIdentical(Profile.current, newProfile)
    XCTAssertEqual(keychainStore.dictionaryReadCount, readCount)
    XCTAssertEqual(TestAuthenticationRestoreObserver.tokens, [newToken])
    XCTAssertEqual(sessionProvider.dataTaskCallCount, 1)
  }

  func testInitializeSDKClearsCurrentAuthenticationTokenWhenCacheIsEmpty() throws {
    AuthenticationToken.current = cachedToken
    cache.authenticationToken = nil

    delegate.initializeSDK()

    XCTAssertNil(AuthenticationToken.current)
    XCTAssertNotNil(deferredSetup)
    try XCTUnwrap(deferredSetup)()
    XCTAssertNil(AuthenticationToken.current)
  }

  func testRepeatedInitializationDoesNotReplaceNewSession() {
    delegate.initializeSDK()
    let newToken = AuthenticationToken(tokenString: "new-token", nonce: "new-nonce")
    AuthenticationToken.current = newToken
    let readCount = keychainStore.dictionaryReadCount

    delegate.initializeSDK()
    XCTAssertFalse(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))

    XCTAssertIdentical(AuthenticationToken.current, newToken)
    XCTAssertEqual(keychainStore.dictionaryReadCount, readCount)
  }

  private func assertSessionRestoredBeforeFirstFrame(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(AuthenticationToken.current?.tokenString, cachedToken.tokenString, file: file, line: line)
    XCTAssertEqual(Profile.current?.userID, cachedProfile.userID, file: file, line: line)
    XCTAssertEqual(keychainStore.dictionaryReadCount, 1, file: file, line: line)
    XCTAssertNotNil(deferredSetup, file: file, line: line)
    XCTAssertFalse(serverConfigurationProvider.loadServerConfigurationWasCalled, file: file, line: line)
    XCTAssertEqual(sessionProvider.dataTaskCallCount, 0, file: file, line: line)
    XCTAssertTrue(TestAuthenticationRestoreObserver.tokens.isEmpty, file: file, line: line)
  }
}

private final class TestAuthenticationRestoreObserver: NSObject, _RestoredAuthenticationSessionObserving {
  static var tokens: [AuthenticationToken] = []

  static func didRestoreAuthenticationSession() {
    if let token = AuthenticationToken.current {
      tokens.append(token)
    }
  }
}

private final class TestAuthenticationKeychainStore: NSObject, KeychainStoreProtocol {
  var dictionaryReadCount = 0
  private var dictionaries: [String: [String: Any]] = [:]

  func string(forKey key: String) -> String? { nil }

  func setString(_ value: String?, forKey key: String, accessibility: CFTypeRef?) -> Bool { true }

  func dictionary(forKey key: String) -> [String: Any]? {
    dictionaryReadCount += 1
    return dictionaries[key]
  }

  func setDictionary(_ value: [String: Any]?, forKey key: String, accessibility: CFTypeRef?) -> Bool {
    dictionaries[key] = value
    return true
  }
}
