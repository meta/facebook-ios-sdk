/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSDKCoreKit
@testable import IAPTestsHostApp

import StoreKit
import StoreKitTest
import TestTools
import XCTest

final class IAPDedupeProcessorTests: StoreKitTestCase {

  // swiftlint:disable implicitly_unwrapped_optional
  var dedupeProcessor: IAPDedupeProcessor!
  var eventLogger: TestEventLogger!
  var prodDedupConfig: [String: [String]]!
  var testDedupConfig: [String: [String]]!
  var appEventsConfigurationProvider: TestAppEventsConfigurationProvider!
  var queue: SKPaymentQueue!
  var iapSKProductRequestFactory: TestIAPSKProductsRequestFactory!
  // swiftlint:enable implicitly_unwrapped_optional

  override func setUp() async throws {
    try await super.setUp()
    queue = SKPaymentQueue.default()
    eventLogger = TestEventLogger()
    appEventsConfigurationProvider = TestAppEventsConfigurationProvider()
    prodDedupConfig = [
      "fb_content_id": ["fb_content_id", "fb_product_item_id"],
      "fb_transaction_id": ["fb_transaction_id"],
      "fb_content_title": ["fb_content_title"],
      "fb_description": ["fb_description"],
      "_valueToSum": ["_valueToSum", "fb_product_price_amount"],
      "fb_currency": ["fb_currency", "fb_product_price_currency"],
    ]
    testDedupConfig = [
      "iap_test_key_1": ["iap_test_key_1", "iap_test_key_3"],
      "iap_test_key_2": ["iap_test_key_2"],
      "fb_transaction_id": ["fb_transaction_id"],
    ]
    let appEventsConfig = _AppEventsConfiguration(
      defaultATEStatus: AdvertisingTrackingStatus.unspecified,
      advertiserIDCollectionEnabled: true,
      eventCollectionEnabled: false,
      iapObservationTime: 3600000000000,
      iapManualAndAutoLogDedupWindow: 10000,
      iapProdDedupConfiguration: prodDedupConfig,
      iapTestDedupConfiguration: testDedupConfig
    )
    appEventsConfigurationProvider.stubbedConfiguration = appEventsConfig
    IAPTransactionObserver.shared.configuredDependencies = .init(
      iapTransactionLoggingFactory: IAPTransactionLoggingFactory(),
      paymentQueue: queue,
      appEventsConfigurationProvider: appEventsConfigurationProvider
    )
    IAPTransactionObserver.shared.startObserving()
    IAPDedupeProcessor.configuredDependencies = .init(
      eventLogger: eventLogger,
      appEventsConfigurationProvider: appEventsConfigurationProvider,
      dataStore: UserDefaults.standard
    )
    IAPTransactionLogger.configuredDependencies = .init(
      eventLogger: eventLogger,
      appStoreReceiptProvider: Bundle.main
    )
    iapSKProductRequestFactory = TestIAPSKProductsRequestFactory()
    IAPEventResolver.configuredDependencies = .init(
      gateKeeperManager: TestGateKeeperManager.self,
      iapSKProductRequestFactory: iapSKProductRequestFactory
    )
    dedupeProcessor = IAPDedupeProcessor.shared
    dedupeProcessor.disable()
    TestGateKeeperManager.gateKeepers["app_events_if_auto_log_subs"] = true
  }

  override func tearDown() {
    dedupeProcessor.reset()
    IAPTransactionObserver.shared.stopObserving()
    TestGateKeeperManager.gateKeepers["app_events_if_auto_log_subs"] = false
    super.tearDown()
  }

  func testEnableDisable() {
    XCTAssertFalse(dedupeProcessor.isEnabled)
    dedupeProcessor.enable()
    XCTAssertTrue(dedupeProcessor.isEnabled)
    dedupeProcessor.disable()
    XCTAssertFalse(dedupeProcessor.isEnabled)
  }

  func testShouldDedupePurchaseEvent() {
    let validParameters = [
      AppEvents.ParameterName.currency: "USD",
      AppEvents.ParameterName.transactionID: "123456789",
    ]
    XCTAssertTrue(
      dedupeProcessor.shouldDedupeEvent(
        .purchased,
        valueToSum: 2.99,
        parameters: validParameters
      )
    )
  }

  func testShouldDedupePurchaseEventWithValueParameter() {
    let validParameters: [AppEvents.ParameterName: Any] = [
      AppEvents.ParameterName.currency: "USD",
      AppEvents.ParameterName.transactionID: "123456789",
      AppEvents.ParameterName("_valueToSum"): 2.99,
    ]
    XCTAssertTrue(
      dedupeProcessor.shouldDedupeEvent(
        .purchased,
        valueToSum: nil,
        parameters: validParameters
      )
    )
  }

  func testShouldDedupePurchaseEventWithAlternateValueParameter() {
    let validParameters: [AppEvents.ParameterName: Any] = [
      AppEvents.ParameterName.currency: "USD",
      AppEvents.ParameterName.transactionID: "123456789",
      AppEvents.ParameterName("fb_product_price_amount"): 2.99,
    ]
    XCTAssertTrue(
      dedupeProcessor.shouldDedupeEvent(
        .purchased,
        valueToSum: nil,
        parameters: validParameters
      )
    )
  }

  func testShouldDedupePurchaseEventWithAlternateCurrencyParameter() {
    let validParameters = [
      AppEvents.ParameterName("fb_product_price_currency"): "USD",
      AppEvents.ParameterName.transactionID: "123456789",
    ]
    XCTAssertTrue(
      dedupeProcessor.shouldDedupeEvent(
        .purchased,
        valueToSum: 2.99,
        parameters: validParameters
      )
    )
  }

  func testShouldDedupeSubscribeEvent() {
    let validParameters = [
      AppEvents.ParameterName.currency: "USD",
      AppEvents.ParameterName.transactionID: "123456789",
    ]
    XCTAssertTrue(
      dedupeProcessor.shouldDedupeEvent(
        .subscribe,
        valueToSum: 2.99,
        parameters: validParameters
      )
    )
  }

  func testShouldDedupeStartTrialEvent() {
    let validParameters = [
      AppEvents.ParameterName.currency: "USD",
      AppEvents.ParameterName.transactionID: "123456789",
    ]
    XCTAssertTrue(
      dedupeProcessor.shouldDedupeEvent(
        .startTrial,
        valueToSum: 2.99,
        parameters: validParameters
      )
    )
  }

  func testShouldNotDedupeRestoredEvent() {
    let validParameters = [
      AppEvents.ParameterName.currency: "USD",
      AppEvents.ParameterName.transactionID: "123456789",
    ]
    XCTAssertFalse(
      dedupeProcessor.shouldDedupeEvent(
        .purchaseRestored,
        valueToSum: 2.99,
        parameters: validParameters
      )
    )
  }

  func testShouldNotDedupePurchaseEventMissingValue() {
    let validParameters = [
      AppEvents.ParameterName.currency: "USD",
      AppEvents.ParameterName.transactionID: "123456789",
    ]
    XCTAssertFalse(
      dedupeProcessor.shouldDedupeEvent(
        .purchased,
        valueToSum: nil,
        parameters: validParameters
      )
    )
  }

  func testShouldNotDedupePurchaseEventMissingCurrency() {
    let invalidParameters = [
      AppEvents.ParameterName.transactionID: "123456789",
    ]
    XCTAssertFalse(
      dedupeProcessor.shouldDedupeEvent(
        .purchased,
        valueToSum: 2.99,
        parameters: invalidParameters
      )
    )
  }

  func testShouldNotDedupePurchaseEventMissingIAPKey() {
    let invalidParameters = [
      AppEvents.ParameterName.currency: "USD",
    ]
    XCTAssertFalse(
      dedupeProcessor.shouldDedupeEvent(
        .purchased,
        valueToSum: 2.99,
        parameters: invalidParameters
      )
    )
  }

  func testShouldNotDedupePurchaseEventMissingParameters() {
    XCTAssertFalse(
      dedupeProcessor.shouldDedupeEvent(
        .purchased,
        valueToSum: 2.99,
        parameters: nil
      )
    )
  }

  func testAreDuplicatesContentID() {
    let implicitEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "12345",
        "fb_transaction_date": "2024-10-20 19:02:50Z",
      ],
      isImplicitEvent: true
    )
    let manualEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "12345",
        "_logTime": 1729450978,
      ],
      isImplicitEvent: false
    )
    guard let dedupKey = IAPDedupeProcessor.areDuplicates(
      implicitEvent: implicitEvent,
      manualEvent: manualEvent,
      dedupConfiguration: prodDedupConfig
    ) else {
      XCTFail("Should have dedupe key")
      return
    }
    XCTAssertEqual(dedupKey, "fb_content_id")
  }

  func testAreDuplicatesContentIDWithAlternateValue() {
    let implicitEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "12345",
        "fb_transaction_date": "2024-10-20 19:02:50Z",
      ],
      isImplicitEvent: true
    )
    let manualEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 0,
      parameters: [
        "fb_currency": "USD",
        "fb_product_price_amount": 10,
        "fb_content_id": "12345",
        "_logTime": 1729450978,
      ],
      isImplicitEvent: false
    )
    guard let dedupKey = IAPDedupeProcessor.areDuplicates(
      implicitEvent: implicitEvent,
      manualEvent: manualEvent,
      dedupConfiguration: prodDedupConfig
    ) else {
      XCTFail("Should have dedupe key")
      return
    }
    XCTAssertEqual(dedupKey, "fb_content_id")
  }

  func testAreDuplicatesContentIDWithAlternateCurrency() {
    let implicitEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "12345",
        "fb_transaction_date": "2024-10-20 19:02:50Z",
      ],
      isImplicitEvent: true
    )
    let manualEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_product_price_currency": "USD",
        "fb_content_id": "12345",
        "_logTime": 1729450978,
      ],
      isImplicitEvent: false
    )
    guard let dedupKey = IAPDedupeProcessor.areDuplicates(
      implicitEvent: implicitEvent,
      manualEvent: manualEvent,
      dedupConfiguration: prodDedupConfig
    ) else {
      XCTFail("Should have dedupe key")
      return
    }
    XCTAssertEqual(dedupKey, "fb_content_id")
  }

  func testAreDuplicatesProductItemID() {
    let implicitEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "12345",
        "fb_transaction_date": "2024-10-20 19:02:50Z",
      ],
      isImplicitEvent: true
    )
    let manualEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_product_item_id": "12345",
        "_logTime": "1729450978",
      ],
      isImplicitEvent: false
    )
    guard let dedupKey = IAPDedupeProcessor.areDuplicates(
      implicitEvent: implicitEvent,
      manualEvent: manualEvent,
      dedupConfiguration: prodDedupConfig
    ) else {
      XCTFail("Should have dedupe key")
      return
    }
    XCTAssertEqual(dedupKey, "fb_product_item_id")
  }

  func testAreDuplicatesTestKey() {
    let implicitEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "iap_test_key_1": "12345",
        "fb_transaction_date": "2024-10-20 19:02:50Z",
      ],
      isImplicitEvent: true
    )
    let manualEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "iap_test_key_3": "12345",
        "_logTime": 1729450978,
      ],
      isImplicitEvent: false
    )
    guard let dedupKey = IAPDedupeProcessor.areDuplicates(
      implicitEvent: implicitEvent,
      manualEvent: manualEvent,
      dedupConfiguration: testDedupConfig
    ) else {
      XCTFail("Should have dedupe key")
      return
    }
    XCTAssertEqual(dedupKey, "iap_test_key_3")
  }

  func testAreNotDuplicatesEventName() {
    let implicitEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "12345",
        "fb_transaction_date": "2024-10-20 19:02:50Z",
      ],
      isImplicitEvent: true
    )
    let manualEvent = DedupableEvent(
      eventName: .subscribe,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "12345",
        "_logTime": 1729450978,
      ],
      isImplicitEvent: false
    )
    let dedupKey = IAPDedupeProcessor.areDuplicates(
      implicitEvent: implicitEvent,
      manualEvent: manualEvent,
      dedupConfiguration: prodDedupConfig
    )
    XCTAssertNil(dedupKey)
  }

  func testAreNotDuplicatesValue() {
    let implicitEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "12345",
        "fb_transaction_date": "2024-10-20 19:02:50Z",
      ],
      isImplicitEvent: true
    )
    let manualEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 20,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "12345",
        "_logTime": 1729450978,
      ],
      isImplicitEvent: false
    )
    let dedupKey = IAPDedupeProcessor.areDuplicates(
      implicitEvent: implicitEvent,
      manualEvent: manualEvent,
      dedupConfiguration: prodDedupConfig
    )
    XCTAssertNil(dedupKey)
  }

  func testAreNotDuplicatesCurrency() {
    let implicitEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "12345",
        "fb_transaction_date": "2024-10-20 19:02:50Z",
      ],
      isImplicitEvent: true
    )
    let manualEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "EUR",
        "fb_content_id": "12345",
        "_logTime": 1729450978,
      ],
      isImplicitEvent: false
    )
    let dedupKey = IAPDedupeProcessor.areDuplicates(
      implicitEvent: implicitEvent,
      manualEvent: manualEvent,
      dedupConfiguration: prodDedupConfig
    )
    XCTAssertNil(dedupKey)
  }

  func testAreNotDuplicatesTime() {
    let implicitEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "12345",
        "fb_transaction_date": "2024-10-19 19:02:45Z",
      ],
      isImplicitEvent: true
    )
    let manualEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "12345",
        "_logTime": 1729450978,
      ],
      isImplicitEvent: false
    )
    let dedupKey = IAPDedupeProcessor.areDuplicates(
      implicitEvent: implicitEvent,
      manualEvent: manualEvent,
      dedupConfiguration: prodDedupConfig
    )
    XCTAssertNil(dedupKey)
  }

  func testAreNotDuplicatesIAPKey() {
    let implicitEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "12345",
        "fb_transaction_date": "2024-10-20 19:02:50Z",
      ],
      isImplicitEvent: true
    )
    let manualEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "123456",
        "_logTime": 1729450978,
      ],
      isImplicitEvent: false
    )
    let dedupKey = IAPDedupeProcessor.areDuplicates(
      implicitEvent: implicitEvent,
      manualEvent: manualEvent,
      dedupConfiguration: prodDedupConfig
    )
    XCTAssertNil(dedupKey)
  }

  func testAreNotDuplicatesEmptyIAPKey() {
    let implicitEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "",
        "fb_transaction_date": "2024-10-20 19:02:50Z",
      ],
      isImplicitEvent: true
    )
    let manualEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_content_id": "",
        "_logTime": 1729450978,
      ],
      isImplicitEvent: false
    )
    let dedupKey = IAPDedupeProcessor.areDuplicates(
      implicitEvent: implicitEvent,
      manualEvent: manualEvent,
      dedupConfiguration: prodDedupConfig
    )
    XCTAssertNil(dedupKey)
  }

  func testDedupableEventsEqual() {
    let event1 = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_transaction_date": "2024-10-20 19:02:50Z",
      ],
      isImplicitEvent: true,
      operationalParameters: [
        "iap_parameters": [
          "key_1": "value_1",
        ],
      ]
    )
    let event2 = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_transaction_date": "2024-10-20 19:02:50Z",
        "fb_currency": "USD",
      ],
      isImplicitEvent: true,
      operationalParameters: [
        "iap_parameters": [
          "key_1": "value_1",
        ],
      ]
    )
    XCTAssertEqual(event1, event2)
  }

  func testDedupableEventsNotEqual() {
    let event1 = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_transaction_date": "2024-10-20 19:02:50Z",
      ],
      isImplicitEvent: true
    )
    let event2 = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_transaction_date": "2024-10-20 19:02:50Z",
        "fb_currency": "EUR",
      ],
      isImplicitEvent: true
    )
    XCTAssertNotEqual(event1, event2)
  }

  func testEncodeDecodeWithNoNils() {
    let dedupableEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10.50,
      parameters: [
        "key_1": "value_1",
        "key_2": 2,
        "key_3": false,
        "key_4": ["value_4", "value_5"],
        "key_5": [
          "1": 1,
          "2": 2,
        ],
      ],
      isImplicitEvent: true,
      accessToken: SampleAccessTokens.validToken,
      hasBeenProdDeduped: true,
      hasBeenTestDeduped: false,
      operationalParameters: [
        "iap_parameters": [
          "key_1": "value_1",
        ],
      ]
    )
    guard let data = try? JSONEncoder().encode(dedupableEvent) else {
      XCTFail("We should be able to encode dedupableEvent")
      return
    }
    guard let decodedEvent = try? JSONDecoder().decode(DedupableEvent.self, from: data) else {
      XCTFail("We should be able to decode a DedupableEvent")
      return
    }
    XCTAssertEqual(dedupableEvent, decodedEvent)
  }

  func testEncodeDecodeWithNils() {
    let dedupableEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: nil,
      parameters: nil,
      isImplicitEvent: true,
      accessToken: nil,
      hasBeenProdDeduped: true,
      hasBeenTestDeduped: false,
      operationalParameters: nil
    )
    guard let data = try? JSONEncoder().encode(dedupableEvent) else {
      XCTFail("We should be able to encode dedupableEvent")
      return
    }
    guard let decodedEvent = try? JSONDecoder().decode(DedupableEvent.self, from: data) else {
      XCTFail("We should be able to decode a DedupableEvent")
      return
    }
    XCTAssertEqual(dedupableEvent, decodedEvent)
  }

  func testSaveAndProcessEvents() {
    let implicitEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "fb_transaction_date": "2024-10-20 19:02:50Z",
        "fb_content_id": "123456",
      ],
      isImplicitEvent: true,
      operationalParameters: [
        "iap_parameters": [
          "key_1": "value_1",
        ],
      ]
    )
    let manualEvent = DedupableEvent(
      eventName: .purchased,
      valueToSum: 10,
      parameters: [
        "fb_currency": "USD",
        "_logTime": 1729450978,
        "fb_content_id": "123456",
      ],
      isImplicitEvent: false,
      operationalParameters: [
        "iap_parameters": [
          "key_1": "value_1",
        ],
      ]
    )
    dedupeProcessor.appendImplicitEvent(implicitEvent)
    dedupeProcessor.appendManualEvent(manualEvent)
    dedupeProcessor.saveNonProcessedEvents()
    XCTAssertNotNil(UserDefaults.standard.fb_object(forKey: IAPConstants.implicitlyLoggedDedupableEventsKey))
    XCTAssertNotNil(UserDefaults.standard.fb_object(forKey: IAPConstants.manuallyLoggedDedupableEventsKey))
    dedupeProcessor.processSavedEvents()
    let predicate = NSPredicate { _, _ -> Bool in
      guard let capturedParameters = self.eventLogger.capturedParameters else {
        return false
      }
      guard let capturedOperationalParameters = self.eventLogger.capturedOperationalParameters,
            let iapParameters = capturedOperationalParameters[.iapParameters] else {
        return false
      }
      return self.eventLogger.capturedEventName == .purchased &&
        self.eventLogger.capturedValueToSum == 10 &&
        capturedParameters[.currency] as? String == "USD" &&
        capturedParameters[.contentID] as? String == "123456" &&
        iapParameters["key_1"] as? String == "value_1" &&
        iapParameters["fb_iap_actual_dedup_result"] as? String == "1" &&
        iapParameters["fb_iap_actual_dedup_key_used"] as? String == "fb_content_id" &&
        iapParameters["fb_iap_test_dedup_result"] == nil &&
        iapParameters["fb_iap_test_dedup_key_used"] == nil &&
        iapParameters["fb_iap_non_deduped_event_time"] != nil
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    wait(for: [expectation], timeout: 90.0)
  }
}

// MARK: - Store Kit 2

extension IAPDedupeProcessorTests {
  @available(iOS 17.0, *)
  private func verifiedHistoryReceipt(
    for transactionID: UInt64,
    productID: String,
    deadline: Date
  ) async throws -> VerificationResult<Transaction>? {
    var receipt: VerificationResult<Transaction>?
    for await result in Transaction.all {
      switch result {
      case let .verified(value):
        if value.id == transactionID, value.productID == productID, value.environment == .xcode {
          receipt = result
        }
      case let .unverified(_, error): throw error
      }
    }
    guard Date() <= deadline else { return nil }

    if receipt != nil {
      logStoreKitPhase("verified controlled receipt found in history: id=\(transactionID)")
    }
    return receipt
  }

  @available(iOS 17.0, *)
  private func verifiedControlledReceipt(
    for transactionID: UInt64,
    productID: String
  ) async throws -> VerificationResult<Transaction> {
    let deadline = Date().addingTimeInterval(5)
    var receipt: VerificationResult<Transaction>?
    repeat {
      if let result = await Transaction.latest(for: productID) {
        switch result {
        case let .verified(value):
          if value.id == transactionID,
             value.productID == productID,
             value.environment == .xcode,
             Date() <= deadline { receipt = result }
        case let .unverified(_, error): throw error
        }
      }
      if receipt == nil {
        receipt = try await verifiedHistoryReceipt(for: transactionID, productID: productID, deadline: deadline)
      }
      if receipt != nil || Date() >= deadline { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < deadline
    return try XCTUnwrap(receipt, "Controlled purchase receipt is not available")
  }

  private func executeTransactionFor(_ productID: String) async throws -> (IAPTransaction, Product) {
    logStoreKitPhase("product lookup started")
    let products = try await Product.products(for: [productID])
    logStoreKitPhase("product lookup completed")
    let product = try XCTUnwrap(products.first { $0.id == productID }, "No configured StoreKit product: \(productID)")
    let verification: VerificationResult<Transaction>
    if #available(iOS 17.0, *), product.type == .nonConsumable {
      // Use a controlled non-consumable purchase for SDK deduplication tests.
      // Subscription/trial tests retain Product.purchase() entry semantics.
      logStoreKitPhase("test-session purchase started")
      let purchased = try await testSession.buyProduct(identifier: productID)
      logStoreKitPhase("test-session purchase completed")
      _ = try XCTUnwrap(
        purchased.environment == .xcode ? purchased : nil,
        "Controlled purchase requires the local Xcode environment"
      )
      logStoreKitPhase("verified test receipt lookup started")
      verification = try await verifiedControlledReceipt(for: purchased.id, productID: productID)
      logStoreKitPhase("verified test receipt lookup completed")
      guard case let .verified(value) = verification else {
        throw StoreKitTestCaseError.purchaseFailed
      }
      _ = try XCTUnwrap(
        value.environment == .xcode ? value : nil,
        "Controlled purchase returned a different environment"
      )
    } else {
      logStoreKitPhase("purchase started")
      let result = try await purchaseTestProduct(product)
      logStoreKitPhase("purchase completed")
      guard case let .success(value) = result else {
        throw StoreKitTestCaseError.purchaseFailed
      }
      verification = value
    }
    let transaction: Transaction
    switch verification {
    case let .verified(value): transaction = value
    case let .unverified(_, error): throw error
    }
    _ = try XCTUnwrap(
      transaction.productID == productID ? transaction : nil,
      "Controlled purchase returned a different product"
    )
    let iapTransaction = verification.iapTransaction
    try await finishTestTransaction(transaction)
    logStoreKitPhase("purchase preparation completed")
    return (iapTransaction, product)
  }

  func testDedupWithDuplicatePurchaseEvents() async throws {
    dedupeProcessor.enable()
    let productID = Self.ProductIdentifiers.nonConsumableProduct1.rawValue
    let (iapTransaction, product) = try await executeTransactionFor(productID)
    dedupeProcessor.processManualEvent(
      .purchased,
      valueToSum: iapTransaction.transaction.price?.currencyNumber ?? product.price.currencyNumber,
      parameters: [
        AppEvents.ParameterName.currency: "USD",
        AppEvents.ParameterName.contentID: productID,
      ],
      accessToken: nil,
      operationalParameters: nil
    )
    let predicate = NSPredicate { _, _ -> Bool in
      guard let capturedParameters = self.eventLogger.capturedParameters else {
        return false
      }
      guard let capturedOperationalParameters = self.eventLogger.capturedOperationalParameters,
            let iapParameters = capturedOperationalParameters[.iapParameters] else {
        return false
      }
      return self.eventLogger.capturedEventName == .purchased &&
        self.eventLogger.capturedValueToSum == 0.99 &&
        capturedParameters[.currency] as? String == "USD" &&
        capturedParameters[.contentID] as? String == productID &&
        iapParameters["fb_iap_actual_dedup_result"] as? String == "1" &&
        iapParameters["fb_iap_actual_dedup_key_used"] as? String == "fb_content_id" &&
        iapParameters["fb_iap_test_dedup_result"] == nil &&
        iapParameters["fb_iap_test_dedup_key_used"] == nil &&
        iapParameters["fb_iap_non_deduped_event_time"] != nil
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testDedupWithDuplicatePurchaseEventsOperationalParameters() async throws {
    logStoreKitPhase("dedup enable started")
    dedupeProcessor.enable()
    logStoreKitPhase("dedup enable completed")
    let productID = Self.ProductIdentifiers.nonConsumableProduct1.rawValue
    let (iapTransaction, product) = try await executeTransactionFor(productID)
    dedupeProcessor.processManualEvent(
      .purchased,
      valueToSum: iapTransaction.transaction.price?.currencyNumber ?? product.price.currencyNumber,
      parameters: [
        AppEvents.ParameterName.currency: "USD",
        AppEvents.ParameterName.transactionID: iapTransaction.transaction.id,
      ],
      accessToken: nil,
      operationalParameters: nil
    )
    let predicate = NSPredicate { _, _ -> Bool in
      guard let capturedParameters = self.eventLogger.capturedParameters else {
        return false
      }
      guard let capturedOperationalParameters = self.eventLogger.capturedOperationalParameters,
            let iapParameters = capturedOperationalParameters[.iapParameters] else {
        return false
      }
      return self.eventLogger.capturedEventName == .purchased &&
        self.eventLogger.capturedValueToSum == 0.99 &&
        capturedParameters[.currency] as? String == "USD" &&
        iapParameters["fb_iap_actual_dedup_result"] as? String == "1" &&
        iapParameters["fb_iap_actual_dedup_key_used"] as? String == "fb_transaction_id" &&
        iapParameters["fb_iap_test_dedup_result"] as? String == "1" &&
        iapParameters["fb_iap_test_dedup_key_used"] as? String == "fb_transaction_id" &&
        iapParameters["fb_iap_non_deduped_event_time"] != nil
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testDedupWithDuplicateSubscribeEvents() async throws {
    dedupeProcessor.enable()
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1.rawValue
    let (iapTransaction, product) = try await executeTransactionFor(productID)
    dedupeProcessor.processManualEvent(
      .subscribe,
      valueToSum: iapTransaction.transaction.price?.currencyNumber ?? product.price.currencyNumber,
      parameters: [
        AppEvents.ParameterName.currency: "USD",
        AppEvents.ParameterName.contentID: productID,
      ],
      accessToken: nil,
      operationalParameters: nil
    )
    let predicate = NSPredicate { _, _ -> Bool in
      guard let capturedParameters = self.eventLogger.capturedParameters else {
        return false
      }
      guard let capturedOperationalParameters = self.eventLogger.capturedOperationalParameters,
            let iapParameters = capturedOperationalParameters[.iapParameters] else {
        return false
      }
      return self.eventLogger.capturedEventName == .subscribe &&
        self.eventLogger.capturedValueToSum == 2 &&
        capturedParameters[.currency] as? String == "USD" &&
        capturedParameters[.contentID] as? String == productID &&
        iapParameters["fb_iap_actual_dedup_result"] as? String == "1" &&
        iapParameters["fb_iap_actual_dedup_key_used"] as? String == "fb_content_id" &&
        iapParameters["fb_iap_test_dedup_result"] == nil &&
        iapParameters["fb_iap_test_dedup_key_used"] == nil &&
        iapParameters["fb_iap_non_deduped_event_time"] != nil
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testDedupWithDuplicateStartTrialEvents() async throws {
    dedupeProcessor.enable()
    let productID = Self.ProductIdentifiers.autoRenewingSubscription2.rawValue
    let (iapTransaction, product) = try await executeTransactionFor(productID)
    dedupeProcessor.processManualEvent(
      .startTrial,
      valueToSum: iapTransaction.transaction.price?.currencyNumber ?? product.price.currencyNumber,
      parameters: [
        AppEvents.ParameterName.currency: "USD",
        AppEvents.ParameterName.contentID: productID,
      ],
      accessToken: nil,
      operationalParameters: nil
    )
    let predicate = NSPredicate { _, _ -> Bool in
      guard let capturedParameters = self.eventLogger.capturedParameters else {
        return false
      }
      guard let capturedOperationalParameters = self.eventLogger.capturedOperationalParameters,
            let iapParameters = capturedOperationalParameters[.iapParameters] else {
        return false
      }
      return self.eventLogger.capturedEventName == .startTrial &&
        self.eventLogger.capturedValueToSum == 0 &&
        capturedParameters[.currency] as? String == "USD" &&
        capturedParameters[.contentID] as? String == productID &&
        iapParameters["fb_iap_actual_dedup_result"] as? String == "1" &&
        iapParameters["fb_iap_actual_dedup_key_used"] as? String == "fb_content_id" &&
        iapParameters["fb_iap_test_dedup_result"] == nil &&
        iapParameters["fb_iap_test_dedup_key_used"] == nil &&
        iapParameters["fb_iap_non_deduped_event_time"] != nil
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testDedupWithDuplicatePurchaseEventsTestDedupConfig() async throws {
    // Keep one production match so unordered config keys don't decide this assertion.
    let singleMatchConfig = prodDedupConfig.filter { $0.key != "fb_transaction_id" }
    appEventsConfigurationProvider.stubbedConfiguration = TestAppEventsConfiguration(
      advertiserIDCollectionEnabled: true,
      iapManualAndAutoLogDedupWindow: 10000,
      iapProdDedupConfiguration: singleMatchConfig,
      iapTestDedupConfiguration: testDedupConfig
    )
    dedupeProcessor.enable()
    let productID = Self.ProductIdentifiers.nonConsumableProduct1.rawValue
    let (iapTransaction, product) = try await executeTransactionFor(productID)
    dedupeProcessor.processManualEvent(
      .purchased,
      valueToSum: iapTransaction.transaction.price?.currencyNumber ?? product.price.currencyNumber,
      parameters: [
        AppEvents.ParameterName.currency: "USD",
        AppEvents.ParameterName.contentID: productID,
        AppEvents.ParameterName.transactionID: iapTransaction.transaction.id,
      ],
      accessToken: nil,
      operationalParameters: nil
    )
    let predicate = NSPredicate { _, _ -> Bool in
      guard let capturedParameters = self.eventLogger.capturedParameters else {
        return false
      }
      guard let capturedOperationalParameters = self.eventLogger.capturedOperationalParameters,
            let iapParameters = capturedOperationalParameters[.iapParameters] else {
        return false
      }
      return self.eventLogger.capturedEventName == .purchased &&
        self.eventLogger.capturedValueToSum == 0.99 &&
        capturedParameters[.currency] as? String == "USD" &&
        capturedParameters[.contentID] as? String == productID &&
        iapParameters["fb_iap_actual_dedup_result"] as? String == "1" &&
        iapParameters["fb_iap_actual_dedup_key_used"] as? String == "fb_content_id" &&
        iapParameters["fb_iap_test_dedup_result"] as? String == "1" &&
        iapParameters["fb_iap_test_dedup_key_used"] as? String == "fb_transaction_id" &&
        iapParameters["fb_iap_non_deduped_event_time"] != nil
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testDedupWithNonDuplicatePurchaseEvents() async throws {
    dedupeProcessor.enable()
    let productID = Self.ProductIdentifiers.nonConsumableProduct1.rawValue
    let (iapTransaction, product) = try await executeTransactionFor(productID)
    dedupeProcessor.processManualEvent(
      .purchased,
      valueToSum: iapTransaction.transaction.price?.currencyNumber ?? product.price.currencyNumber,
      parameters: [
        AppEvents.ParameterName.currency: "USD",
      ],
      accessToken: nil,
      operationalParameters: nil
    )
    let predicate = NSPredicate { _, _ -> Bool in
      guard let capturedParameters = self.eventLogger.capturedParameters else {
        return false
      }
      return self.eventLogger.capturedEventName == .purchased &&
        self.eventLogger.capturedValueToSum == 0.99 &&
        capturedParameters[.currency] as? String == "USD" &&
        self.eventLogger.capturedOperationalParameters == nil
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testSeveralManualAndImplicitEventsWithSomeDuplicatesAndSomeNonDuplicates() async throws {
    dedupeProcessor.enable()
    let productID = Self.ProductIdentifiers.nonConsumableProduct1.rawValue
    let (iapTransaction, product) = try await executeTransactionFor(productID)
    let productID2 = Self.ProductIdentifiers.nonConsumableProduct2.rawValue
    let (iapTransaction2, _) = try await executeTransactionFor(productID2)
    dedupeProcessor.processManualEvent(
      .purchased,
      valueToSum: iapTransaction.transaction.price?.currencyNumber ?? product.price.currencyNumber,
      parameters: [
        AppEvents.ParameterName.currency: "USD",
        AppEvents.ParameterName.contentID: productID,
      ],
      accessToken: nil,
      operationalParameters: nil
    )
    let productID3 = Self.ProductIdentifiers.nonRenewingSubscription1.rawValue
    let (iapTransaction3, _) = try await executeTransactionFor(productID3)
    dedupeProcessor.processManualEvent(
      .purchased,
      valueToSum: iapTransaction3.transaction.price?.currencyNumber ?? 0,
      parameters: [
        AppEvents.ParameterName.currency: "USD",
        AppEvents.ParameterName.contentID: productID3,
      ],
      accessToken: nil,
      operationalParameters: nil
    )
    dedupeProcessor.processManualEvent(
      .purchased,
      valueToSum: iapTransaction2.transaction.price?.currencyNumber ?? 0,
      parameters: [
        AppEvents.ParameterName.currency: "USD",
      ],
      accessToken: nil,
      operationalParameters: nil
    )
    let predicate = NSPredicate { _, _ -> Bool in
      var dedupedEvents: [EventStructForTests] = []
      guard self.eventLogger.capturedEvents.count == 9 else {
        return false
      }
      for event in self.eventLogger.capturedEvents {
        if event.eventName != .purchased {
          continue
        }
        guard let parameters = event.operationalParameters,
              let iapParameters = parameters[.iapParameters] else {
          continue
        }
        if iapParameters["fb_iap_actual_dedup_result"] as? String == "1" {
          dedupedEvents.append(event)
        }
      }
      guard dedupedEvents.count == 2 else {
        return false
      }
      return dedupedEvents.first?.parameters?[.contentID] as? String == productID &&
        dedupedEvents.last?.parameters?[.contentID] as? String == productID3
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 30.0)
  }
}

// MARK: - Store Kit 1

extension IAPDedupeProcessorTests {
  func testDedupWihtDuplicatePurchaseEventsStoreKit1() {
    dedupeProcessor.enable()
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.nonConsumableProduct1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    IAPTransactionObserver.shared.paymentQueue(queue, updatedTransactions: [transaction])
    dedupeProcessor.processManualEvent(
      .purchased,
      valueToSum: 0.99,
      parameters: [
        AppEvents.ParameterName.currency: "USD",
        AppEvents.ParameterName.contentID: productID.rawValue,
      ],
      accessToken: nil,
      operationalParameters: nil
    )
    let predicate = NSPredicate { _, _ -> Bool in
      guard let capturedParameters = self.eventLogger.capturedParameters else {
        return false
      }
      guard let capturedOperationalParameters = self.eventLogger.capturedOperationalParameters,
            let iapParameters = capturedOperationalParameters[.iapParameters] else {
        return false
      }
      return self.eventLogger.capturedEventName == .purchased &&
        self.eventLogger.capturedValueToSum == 0.99 &&
        capturedParameters[.currency] as? String == "USD" &&
        capturedParameters[.contentID] as? String == productID.rawValue &&
        iapParameters["fb_iap_actual_dedup_result"] as? String == "1" &&
        iapParameters["fb_iap_actual_dedup_key_used"] as? String == "fb_content_id" &&
        iapParameters["fb_iap_test_dedup_result"] == nil &&
        iapParameters["fb_iap_test_dedup_key_used"] == nil &&
        iapParameters["fb_iap_non_deduped_event_time"] != nil
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    wait(for: [expectation], timeout: 20.0)
  }

  func testDedupWithNonDuplicatePurchaseEventsWithStoreKit1() {
    dedupeProcessor.enable()
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.nonConsumableProduct1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    IAPTransactionObserver.shared.paymentQueue(queue, updatedTransactions: [transaction])
    dedupeProcessor.processManualEvent(
      .purchased,
      valueToSum: 0.99,
      parameters: [
        AppEvents.ParameterName.currency: "USD",
      ],
      accessToken: nil,
      operationalParameters: nil
    )
    let predicate = NSPredicate { _, _ -> Bool in
      guard let capturedParameters = self.eventLogger.capturedParameters else {
        return false
      }
      return self.eventLogger.capturedEventName == .purchased &&
        self.eventLogger.capturedValueToSum == 0.99 &&
        capturedParameters[.currency] as? String == "USD" &&
        self.eventLogger.capturedOperationalParameters == nil
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    wait(for: [expectation], timeout: 20.0)
  }
}
