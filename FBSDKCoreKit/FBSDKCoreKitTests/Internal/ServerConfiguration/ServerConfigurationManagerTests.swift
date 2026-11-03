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

final class ServerConfigurationManagerTests: XCTestCase {

  // swiftlint:disable implicitly_unwrapped_optional
  var connection: TestGraphRequestConnection!
  var requestFactory: TestGraphRequestFactory!
  var connectionFactory: TestGraphRequestConnectionFactory!
  var dialogConfigurationMapBuilder: TestDialogConfigurationMapBuilder!
  // swiftlint:enable implicitly_unwrapped_optional

  private var originalAppID: String?
  private var originalSettingsDependencies: Settings.ObjectDependencies?

  override func setUp() {
    super.setUp()

    originalAppID = Settings.shared.appID
    originalSettingsDependencies = Settings.shared.configuredDependencies
    Settings.shared.setDependencies(
      .init(
        appEventsConfigurationProvider: TestAppEventsConfigurationProvider(),
        serverConfigurationProvider: TestAppEventsServerConfigurationProvider(),
        dataStore: UserDefaultsSpy(),
        eventLogger: TestEventLogger(),
        infoDictionaryProvider: TestBundle()
      )
    )
    Settings.shared.appID = name
    _ServerConfigurationManager.shared.clearCache()
    _ServerConfigurationManager.shared.setValue(NSMutableArray(), forKey: "completionBlocks")
    _ServerConfigurationManager.shared.setValue(false, forKey: "loadingServerConfiguration")
    _ServerConfigurationManager.shared.setValue(false, forKey: "requeryFinishedForAppStart")

    connection = TestGraphRequestConnection()
    requestFactory = TestGraphRequestFactory()
    connectionFactory = TestGraphRequestConnectionFactory(stubbedConnection: connection)
    dialogConfigurationMapBuilder = TestDialogConfigurationMapBuilder()
    _ServerConfigurationManager.shared.configure(
      graphRequestFactory: requestFactory,
      graphRequestConnectionFactory: connectionFactory,
      dialogConfigurationMapBuilder: dialogConfigurationMapBuilder
    )
  }

  override func tearDown() {
    _ServerConfigurationManager.shared.reset()
    _ServerConfigurationManager.shared.setValue(NSMutableArray(), forKey: "completionBlocks")
    _ServerConfigurationManager.shared.setValue(false, forKey: "loadingServerConfiguration")
    _ServerConfigurationManager.shared.setValue(false, forKey: "requeryFinishedForAppStart")
    Settings.shared.appID = originalAppID
    Settings.shared.configuredDependencies = originalSettingsDependencies
    connection = nil
    requestFactory = nil
    connectionFactory = nil
    dialogConfigurationMapBuilder = nil

    super.tearDown()
  }

  func testDefaultDependencies() {
    _ServerConfigurationManager.shared.reset()

    XCTAssertNil(
      _ServerConfigurationManager.shared.graphRequestFactory,
      "Should not have a graph request factory by default"
    )
    XCTAssertNil(
      _ServerConfigurationManager.shared.graphRequestConnectionFactory,
      "Should not have a graph request connection factory by default"
    )
    XCTAssertNil(
      _ServerConfigurationManager.shared.dialogConfigurationMapBuilder,
      "Should not have a dialog configuration map builder by default"
    )
  }

  func testConfiguringWithDependencies() {
    XCTAssertIdentical(
      _ServerConfigurationManager.shared.graphRequestFactory,
      requestFactory,
      "Should set the provided graph request factory"
    )
    XCTAssertIdentical(
      _ServerConfigurationManager.shared.graphRequestConnectionFactory,
      connectionFactory,
      "Should set the provided graph request connection factory"
    )
    XCTAssertIdentical(
      _ServerConfigurationManager.shared.dialogConfigurationMapBuilder,
      dialogConfigurationMapBuilder,
      "Should set the provided dialog configuration map builder"
    )
  }

  // swiftlint:disable:next identifier_name
  func _testCompleteFetchingServerConfigurationWithoutConnectionResponseOrError() throws {
    // This test needs more work before it can be included in the regular test suite
    // See T105037698
    try XCTSkipIf(true)

    var didInvokeCompletion = false
    var configuration: _ServerConfiguration?
    var error: Error?
    _ServerConfigurationManager.shared.loadServerConfiguration { potentialConfiguration, potentialError in
      didInvokeCompletion = true
      configuration = potentialConfiguration
      error = potentialError
    }

    let completion = try XCTUnwrap(connection.capturedCompletion)
    completion(nil, nil, nil)
    XCTAssertEqual(
      connection.startCallCount,
      1,
      "Should start the request to fetch a server configuration"
    )
    XCTAssertTrue(didInvokeCompletion)
    XCTAssertNotNil(
      configuration,
      "Should return a server configuration when there is no result from the graph request"
    )
    XCTAssertNil(
      error,
      "Missing results from the graph request should not result in an error"
    )
  }

  func testParsingWithMissingDialogConfigurations() {
    _ServerConfigurationManager.shared.processLoadRequestResponse(
      [String: Any](),
      error: nil,
      appID: name
    )
    XCTAssertNil(
      dialogConfigurationMapBuilder.capturedRawConfigurations,
      "Should not invoke the dialog configuration builder when the raw response is missing a raw dialog configuration"
    )
  }

  func testParsingWithDialogConfigurationsMissingDataKey() {
    let response = [
      RawServerConfigurationResponseFixtures.Keys.dialogConfigurations: [String: Any](),
    ]

    _ServerConfigurationManager.shared.processLoadRequestResponse(
      response,
      error: nil,
      appID: name
    )
    XCTAssertNil(
      dialogConfigurationMapBuilder.capturedRawConfigurations,
      "Should not invoke the dialog configuration builder when the raw dialog configuration is missing a data key"
    )
  }

  func testParsingWithValidDialogConfigurations() {
    let expectedRawConfigurations = [
      SampleRawDialogConfigurations.createValid(name: name),
      SampleRawDialogConfigurations.createValid(name: "foo"),
    ]
    let response = [
      "ios_dialog_configs": [
        "data": expectedRawConfigurations,
      ],
    ]

    _ServerConfigurationManager.shared.processLoadRequestResponse(
      response,
      error: nil,
      appID: name
    )

    zip(
      dialogConfigurationMapBuilder.capturedRawConfigurations ?? [],
      expectedRawConfigurations
    )
    .forEach { actual, expected in
      assertEqualRawDialogConfigurations(actual, expected)
    }
  }

  func testParsingResponses() {
    for _ in 0 ..< 100 {
      _ServerConfigurationManager.shared.processLoadRequestResponse(
        RawServerConfigurationResponseFixtures.random,
        error: nil,
        appID: name
      )
    }
  }

  func testFailedLoadDoesNotRetryForRepeatedCacheReads() throws {
    _ = try failInitialLoad()

    for _ in 0 ..< 5 {
      XCTAssertTrue(_ServerConfigurationManager.shared.cachedServerConfiguration().isDefaults)
    }

    XCTAssertEqual(connection.startCallCount, 1)
  }

  func testFailedLoadReturnsCachedErrorToSubsequentCompletions() throws {
    let expectedError = try failInitialLoad()
    var completionCount = 0

    for _ in 0 ..< 5 {
      _ServerConfigurationManager.shared.loadServerConfiguration { configuration, error in
        completionCount += 1
        XCTAssertNil(configuration)
        XCTAssertEqual(error as NSError?, expectedError)
      }
    }

    XCTAssertEqual(completionCount, 5)
    XCTAssertEqual(connection.startCallCount, 1)
  }

  func testFailedRefreshReturnsPreviousConfigurationDuringCooldown() throws {
    let configuration = ServerConfigurationFixtures.configuration(withDictionary: [
      "appID": name,
      "timestamp": Date.distantPast,
      "defaults": false,
    ])
    _ServerConfigurationManager.shared.setValue(configuration, forKey: "serverConfiguration")
    let expectedError = try failInitialLoad()
    var didComplete = false

    _ServerConfigurationManager.shared.loadServerConfiguration { result, error in
      didComplete = true
      XCTAssertIdentical(result, configuration)
      XCTAssertEqual(error as NSError?, expectedError)
    }

    XCTAssertTrue(didComplete)
    XCTAssertIdentical(_ServerConfigurationManager.shared.cachedServerConfiguration(), configuration)
    XCTAssertEqual(connection.startCallCount, 1)
  }

  func testFailedLoadRetriesAfterCooldownExpires() throws {
    _ = try failInitialLoad()
    expireErrorCooldown()
    var didComplete = false

    _ServerConfigurationManager.shared.loadServerConfiguration { configuration, error in
      didComplete = true
      XCTAssertNotNil(configuration)
      XCTAssertNil(error)
    }

    XCTAssertEqual(connection.startCallCount, 2)
    XCTAssertFalse(didComplete)
    let completion = try XCTUnwrap(connection.capturedCompletion)
    completion(connection, [String: Any](), nil)
    XCTAssertTrue(didComplete)
    _ = _ServerConfigurationManager.shared.cachedServerConfiguration()
    XCTAssertEqual(connection.startCallCount, 2)
  }

  func testClearCacheAllowsRetryAfterFailure() throws {
    _ = try failInitialLoad()
    _ServerConfigurationManager.shared.clearCache()

    _ServerConfigurationManager.shared.loadServerConfiguration(completionBlock: nil)

    XCTAssertEqual(connection.startCallCount, 2)
    XCTAssertNotNil(_ServerConfigurationManager.shared.request(toLoadServerConfiguration: name))
  }

  func testRetryAfterExpiryCoalescesCompletionBlocks() throws {
    _ = try failInitialLoad()
    expireErrorCooldown()
    var completionCount = 0

    for _ in 0 ..< 2 {
      _ServerConfigurationManager.shared.loadServerConfiguration { configuration, error in
        completionCount += 1
        XCTAssertNotNil(configuration)
        XCTAssertNil(error)
      }
    }

    XCTAssertEqual(connection.startCallCount, 2)
    XCTAssertEqual(completionCount, 0)
    let completion = try XCTUnwrap(connection.capturedCompletion)
    completion(connection, [String: Any](), nil)
    XCTAssertEqual(completionCount, 2)
  }

  func testFailureWithoutConfigurationDoesNotThrottleAnotherApp() throws {
    _ = try failInitialLoad()
    let otherAppID = "other-" + name
    Settings.shared.appID = otherAppID

    _ServerConfigurationManager.shared.loadServerConfiguration(completionBlock: nil)

    XCTAssertEqual(connection.startCallCount, 2)
    XCTAssertEqual(connection.capturedRequest?.graphPath, otherAppID)
  }

  func testSuccessfulConfigurationRemainsCached() throws {
    _ServerConfigurationManager.shared.loadServerConfiguration(completionBlock: nil)
    let completion = try XCTUnwrap(connection.capturedCompletion)
    completion(connection, [String: Any](), nil)
    let configuration = _ServerConfigurationManager.shared.cachedServerConfiguration()
    var didComplete = false

    _ServerConfigurationManager.shared.loadServerConfiguration { result, error in
      didComplete = true
      XCTAssertIdentical(result, configuration)
      XCTAssertNil(error)
    }

    XCTAssertTrue(didComplete)
    XCTAssertEqual(connection.startCallCount, 1)
  }

  func testFailureCooldownAppliesToRequestBuilder() throws {
    _ = try failInitialLoad()

    XCTAssertNil(_ServerConfigurationManager.shared.request(toLoadServerConfiguration: name))
    XCTAssertNotNil(_ServerConfigurationManager.shared.request(toLoadServerConfiguration: "other-" + name))

    expireErrorCooldown()
    XCTAssertNotNil(_ServerConfigurationManager.shared.request(toLoadServerConfiguration: name))
  }

  func testFailureCooldownPreventsConfigurationPiggyback() throws {
    _ = try failInitialLoad()
    let settings = TestSettings()
    settings.appID = name
    let piggybackManager = GraphRequestPiggybackManager()
    piggybackManager.setDependencies(
      .init(
        graphRequestFactory: requestFactory,
        serverConfigurationProvider: _ServerConfigurationManager.shared,
        settings: settings,
        tokenWallet: TestAccessTokenWallet.self
      )
    )
    TestAccessTokenWallet.reset()
    defer { TestAccessTokenWallet.reset() }
    let otherConnection = TestGraphRequestConnection()
    otherConnection.add(SampleGraphRequests.valid) { _, _, _ in }

    piggybackManager.addPiggybackRequests(otherConnection)

    XCTAssertEqual(otherConnection.capturedRequests.count, 1)
    XCTAssertEqual(connection.startCallCount, 1)
  }

  // MARK: - Helpers

  private func failInitialLoad() throws -> NSError {
    let error = SampleError() as NSError
    _ServerConfigurationManager.shared.loadServerConfiguration(completionBlock: nil)
    let completion = try XCTUnwrap(connection.capturedCompletion)
    completion(connection, nil, error)
    XCTAssertEqual(connection.startCallCount, 1)
    return error
  }

  private func expireErrorCooldown() {
    _ServerConfigurationManager.shared.setValue(
      Date(timeIntervalSinceNow: -TimeInterval(FBSDK_SERVER_CONFIGURATION_MANAGER_CACHE_TIMEOUT) - 1),
      forKey: "serverConfigurationErrorTimestamp"
    )
  }

  func assertEqualRawDialogConfigurations(
    _ actual: [String: Any],
    _ expected: [String: Any],
    _ file: StaticString = #file,
    _ line: UInt = #line
  ) {
    XCTAssertEqual(
      actual["name"] as? String,
      expected["name"] as? String,
      file: file,
      line: line
    )
    XCTAssertEqual(
      actual["url"] as? String,
      expected["url"] as? String,
      file: file,
      line: line
    )
    XCTAssertEqual(
      actual["versions"] as? [String],
      expected["versions"] as? [String],
      file: file,
      line: line
    )
  }
}
