/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSDKCoreKit
@testable import IAPTestsHostApp

import StoreKitTest
import TestTools
import XCTest

final class IAPTransactionLoggerTests: StoreKitTestCase {

  // swiftlint:disable implicitly_unwrapped_optional
  var iapLogger: IAPTransactionLogger!
  var eventLogger: TestEventLogger!
  var dateFormatter: DateFormatter!
  var iapSKProductRequestFactory: TestIAPSKProductsRequestFactory!
  // swiftlint:enable implicitly_unwrapped_optional
  let autoLogSubscriptionGK = "app_events_if_auto_log_subs"

  override func setUp() async throws {
    try await super.setUp()
    dateFormatter = DateFormatter()
    dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
    IAPTransactionCache.shared.reset()
    TestGateKeeperManager.gateKeepers[autoLogSubscriptionGK] = true
    eventLogger = TestEventLogger()
    iapSKProductRequestFactory = TestIAPSKProductsRequestFactory()
    IAPTransactionLogger.configuredDependencies = .init(
      eventLogger: eventLogger,
      appStoreReceiptProvider: Bundle.main
    )
    IAPEventResolver.configuredDependencies = .init(
      gateKeeperManager: TestGateKeeperManager.self,
      iapSKProductRequestFactory: iapSKProductRequestFactory
    )
    iapLogger = IAPTransactionLogger()
  }
}

// MARK: - Store Kit 2

extension IAPTransactionLoggerTests {
  private func executeTransactionFor(_ productID: String) async -> (IAPTransaction, Product)? {
    guard let products =
      try? await Product.products(for: [productID]),
      let product = products.first else {
      return nil
    }
    guard let result = try? await product.purchase() else {
      return nil
    }
    guard let iapTransaction = try? getIAPTransactionForPurchaseResult(result: result) else {
      return nil
    }
    await iapTransaction.transaction.finish()
    return (iapTransaction, product)
  }

  // MARK: - New Subscriptions

  func testLogNewSubscriptionTransactionStartTrial() async {
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.autoRenewingSubscription2.rawValue) else {
      return
    }
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .startTrial)
    XCTAssertEqual(eventLogger.capturedValueToSum, 0)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.originalID),
        eventName: .startTrial,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "1")
    XCTAssertEqual(capturedParameters[.hasFreeTrial] as? String, "1")
    XCTAssertEqual(capturedParameters[.trialPeriod] as? String, "P6M")
    XCTAssertEqual(capturedParameters[.trialPrice] as? Double, 0)
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewSubscriptionTransactionNonRenewable() async {
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.nonRenewingSubscription1.rawValue) else {
      return
    }
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchased)
    XCTAssertEqual(eventLogger.capturedValueToSum, 5)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.originalID),
        eventName: .purchased,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewSubscriptionTransactionAutoRenewable() async {
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.autoRenewingSubscription1.rawValue) else {
      return
    }
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribe)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.originalID),
        eventName: .subscribe,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewSubscriptionTransactionWithStartTrialInCache() async {
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.autoRenewingSubscription1.rawValue) else {
      return
    }
    IAPTransactionCache.shared.addTransaction(
      transactionID: String(iapTransaction.transaction.id),
      eventName: .startTrial,
      productID: iapTransaction.transaction.productID
    )
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribe)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.originalID),
        eventName: .subscribe,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewSubscriptionTransactionGKDisabled() async {
    TestGateKeeperManager.gateKeepers[autoLogSubscriptionGK] = false
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.autoRenewingSubscription1.rawValue) else {
      return
    }
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchased)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.originalID),
        eventName: .purchased,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewSubscriptionTransactionStartTrialWithStartTrialInCache() async {
    guard let (iapTransaction, _) =
      await executeTransactionFor(Self.ProductIdentifiers.autoRenewingSubscription2.rawValue) else {
      return
    }
    IAPTransactionCache.shared.addTransaction(
      transactionID: String(iapTransaction.transaction.originalID),
      eventName: .startTrial,
      productID: iapTransaction.transaction.productID
    )
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertNil(eventLogger.capturedEventName)
    XCTAssertNil(eventLogger.capturedValueToSum)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.id),
        eventName: .startTrial,
        productID: iapTransaction.transaction.productID
      )
    )
    XCTAssertNil(eventLogger.capturedParameters)
  }

  func testLogNewSubscriptionTransactionWithSubscribeInCache() async {
    guard let (iapTransaction, _) =
      await executeTransactionFor(Self.ProductIdentifiers.autoRenewingSubscription1.rawValue) else {
      return
    }
    IAPTransactionCache.shared.addTransaction(
      transactionID: String(iapTransaction.transaction.originalID),
      eventName: .subscribe,
      productID: iapTransaction.transaction.productID
    )
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertNil(eventLogger.capturedEventName)
    XCTAssertNil(eventLogger.capturedValueToSum)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.id),
        eventName: .subscribe,
        productID: iapTransaction.transaction.productID
      )
    )
    XCTAssertNil(eventLogger.capturedParameters)
  }

  func testLogNewSubscriptionTransactionWithRestoreInCache() async {
    guard let (iapTransaction, _) =
      await executeTransactionFor(Self.ProductIdentifiers.autoRenewingSubscription1.rawValue) else {
      return
    }
    IAPTransactionCache.shared.addTransaction(
      transactionID: String(iapTransaction.transaction.originalID),
      eventName: .subscribeRestore,
      productID: iapTransaction.transaction.productID
    )
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertNil(eventLogger.capturedEventName)
    XCTAssertNil(eventLogger.capturedValueToSum)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.id),
        eventName: .subscribe,
        productID: iapTransaction.transaction.productID
      )
    )
    XCTAssertNil(eventLogger.capturedParameters)
  }

  @available(iOS 17.0, *)
  func testLogNewSubscriptionTransactionRenewal() async throws {
    testSession.timeRate = .realTime
    let identifier = Self.ProductIdentifiers.autoRenewingSubscription1.rawValue
    let products = try await Product.products(for: [identifier])
    let product = try XCTUnwrap(products.first { $0.id == identifier })
    let result = try await product.purchase()
    guard case let .success(originalResult) = result else {
      throw StoreKitTestCaseError.purchaseFailed
    }
    let original: Transaction
    switch originalResult {
    case let .verified(value): original = value
    case let .unverified(_, error): throw error
    }
    let isFreshLocalSubscription = original.environment == .xcode &&
      original.productID == identifier && original.id == original.originalID
    _ = try XCTUnwrap(
      isFreshLocalSubscription ? original : nil,
      "Renewal fixture requires a fresh verified local subscription"
    )
    let originalTransaction = originalResult.iapTransaction
    try await finishTestTransaction(original)
    await iapLogger.logNewTransaction(originalTransaction)

    // Test renewal logging with an actual controlled renewal, not clock timing or history order.
    try testSession.forceRenewalOfSubscription(productIdentifier: identifier)
    let deadline = Date().addingTimeInterval(3)
    var renewalResult: VerificationResult<Transaction>?
    repeat {
      if let result = await Transaction.latest(for: identifier) {
        switch result {
        case let .verified(value):
          let controllerMatch = testSession.allTransactions().contains {
            $0.identifier == .init(value.id) && $0.productIdentifier == identifier
          }
          if value.environment == .xcode,
             value.productID == identifier,
             value.originalID == original.id,
             value.id != original.id,
             controllerMatch,
             Date() <= deadline {
            renewalResult = result
          }
        case let .unverified(_, error): throw error
        }
      }
      if renewalResult != nil || Date() >= deadline { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < deadline
    let publishedRenewal = try XCTUnwrap(
      renewalResult,
      "Verified controlled renewal was not published within three seconds"
    )
    let renewalTransaction = publishedRenewal.iapTransaction
    logStoreKitPhase("controlled renewal original=\(original.id) new=\(renewalTransaction.transaction.id)")
    await iapLogger.logNewTransaction(renewalTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribe)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertEqual(originalTransaction.transaction.id, renewalTransaction.transaction.originalID)
    XCTAssertNotEqual(renewalTransaction.transaction.originalID, renewalTransaction.transaction.id)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(renewalTransaction.transaction.originalID),
        eventName: .subscribe,
        productID: renewalTransaction.transaction.productID
      )
    )
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(renewalTransaction.transaction.id),
        eventName: .subscribe,
        productID: renewalTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: originalTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(originalTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(originalTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  // MARK: - New Purchases

  func testLogNewPurchaseTransactionConsumable() async {
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.consumableProduct1.rawValue) else {
      return
    }
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchased)
    XCTAssertEqual(eventLogger.capturedValueToSum, 10)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.originalID),
        eventName: .purchased,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewPurchaseTransactionNonConsumable() async {
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.nonConsumableProduct1.rawValue) else {
      return
    }
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchased)
    XCTAssertEqual(eventLogger.capturedValueToSum, 0.99)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.originalID),
        eventName: .purchased,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewPurchaseTransactionWithPurchaseInCache() async {
    guard let (iapTransaction, _) =
      await executeTransactionFor(Self.ProductIdentifiers.nonConsumableProduct1.rawValue) else {
      return
    }
    IAPTransactionCache.shared.addTransaction(
      transactionID: String(iapTransaction.transaction.originalID),
      eventName: .purchased,
      productID: iapTransaction.transaction.productID
    )
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertNil(eventLogger.capturedEventName)
    XCTAssertNil(eventLogger.capturedValueToSum)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.id),
        eventName: .purchased,
        productID: iapTransaction.transaction.productID
      )
    )
    XCTAssertNil(eventLogger.capturedParameters)
  }

  // MARK: - Restored Subscriptions

  func testLogRestoredSubscriptionTransactionAutoRenewableStartTrial() async {
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.autoRenewingSubscription2.rawValue) else {
      return
    }
    await iapLogger.logRestoredTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribeRestore)
    XCTAssertEqual(eventLogger.capturedValueToSum, 0)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.originalID),
        eventName: .subscribeRestore,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "1")
    XCTAssertEqual(capturedParameters[.hasFreeTrial] as? String, "1")
    XCTAssertEqual(capturedParameters[.trialPeriod] as? String, "P6M")
    XCTAssertEqual(capturedParameters[.trialPrice] as? Double, 0)
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogRestoredSubscriptionTransactionNonRenewable() async {
    guard let (iapTransaction, _) =
      await executeTransactionFor(Self.ProductIdentifiers.nonRenewingSubscription1.rawValue) else {
      return
    }
    await iapLogger.logRestoredTransaction(iapTransaction)
    XCTAssertNil(eventLogger.capturedEventName)
    let capturedParameters = eventLogger.capturedParameters
    XCTAssertNil(capturedParameters)
    let capturedOperationalParameters = eventLogger.capturedOperationalParameters
    XCTAssertNil(capturedOperationalParameters)
  }

  func testLogRestoredSubscriptionTransactionAutoRenewable() async {
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.autoRenewingSubscription1.rawValue) else {
      return
    }
    await iapLogger.logRestoredTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribeRestore)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.originalID),
        eventName: .subscribeRestore,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogRestoredSubscriptionTransactionWithRestoredInCache() async {
    guard let (iapTransaction, _) =
      await executeTransactionFor(Self.ProductIdentifiers.autoRenewingSubscription1.rawValue) else {
      return
    }
    IAPTransactionCache.shared.addTransaction(
      transactionID: String(iapTransaction.transaction.originalID),
      eventName: .subscribeRestore,
      productID: iapTransaction.transaction.productID
    )
    await iapLogger.logRestoredTransaction(iapTransaction)
    XCTAssertNil(eventLogger.capturedEventName)
    XCTAssertNil(eventLogger.capturedValueToSum)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.id),
        eventName: .subscribeRestore,
        productID: iapTransaction.transaction.productID
      )
    )
    XCTAssertNil(eventLogger.capturedParameters)
  }

  func testLogRestoredSubscriptionTransactionGKDisabled() async {
    TestGateKeeperManager.gateKeepers[autoLogSubscriptionGK] = false
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.autoRenewingSubscription1.rawValue) else {
      return
    }
    await iapLogger.logRestoredTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchaseRestored)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.originalID),
        eventName: .purchaseRestored,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  // MARK: - Restored Purchases

  func testLogRestoredPurchaseTransactionConsumable() async {
    guard let (iapTransaction, _) =
      await executeTransactionFor(Self.ProductIdentifiers.consumableProduct1.rawValue) else {
      return
    }
    await iapLogger.logRestoredTransaction(iapTransaction)
    XCTAssertNil(eventLogger.capturedEventName)
    let capturedParameters = eventLogger.capturedParameters
    XCTAssertNil(capturedParameters)
    let capturedOperationalParameters = eventLogger.capturedOperationalParameters
    XCTAssertNil(capturedOperationalParameters)
  }

  func testLogRestoredPurchaseTransactionNonConsumable() async {
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.nonConsumableProduct1.rawValue) else {
      return
    }
    await iapLogger.logRestoredTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchaseRestored)
    XCTAssertEqual(eventLogger.capturedValueToSum, 0.99)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.originalID),
        eventName: .purchaseRestored,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogRestoredPurchaseTransactionRestoredInCache() async {
    guard let (iapTransaction, _) =
      await executeTransactionFor(Self.ProductIdentifiers.nonConsumableProduct1.rawValue) else {
      return
    }
    IAPTransactionCache.shared.addTransaction(
      transactionID: String(iapTransaction.transaction.originalID),
      eventName: .purchaseRestored,
      productID: iapTransaction.transaction.productID
    )
    await iapLogger.logRestoredTransaction(iapTransaction)
    XCTAssertNil(eventLogger.capturedEventName)
    XCTAssertNil(eventLogger.capturedValueToSum)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.id),
        eventName: .purchaseRestored,
        productID: iapTransaction.transaction.productID
      )
    )
    XCTAssertNil(eventLogger.capturedParameters)
  }

  // MARK: - Duplicates

  func testLogDuplicatePurchaseEventFirstOneShouldSucceed() async {
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.nonConsumableProduct1.rawValue) else {
      return
    }
    await iapLogger.logNewTransaction(iapTransaction)
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchased)
    XCTAssertEqual(eventLogger.capturedValueToSum, 0.99)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.id),
        eventName: .purchased,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogPurchaseRestoredEventAndThenPurchaseEventPurchaseRestoredShouldSucceed() async {
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.nonConsumableProduct1.rawValue) else {
      return
    }
    await iapLogger.logRestoredTransaction(iapTransaction)
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchaseRestored)
    XCTAssertEqual(eventLogger.capturedValueToSum, 0.99)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.originalID),
        eventName: .purchaseRestored,
        productID: iapTransaction.transaction.productID
      )
    )
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.id),
        eventName: .purchased,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogDuplicateSubscriptionEventFirstOneShouldSucceed() async {
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.autoRenewingSubscription1.rawValue) else {
      return
    }
    await iapLogger.logNewTransaction(iapTransaction)
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribe)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.id),
        eventName: .subscribe,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogSubscriptionRestoredEventAndThenSubscriptionEventSubscriptionRestoredShouldSucceed() async {
    guard let (iapTransaction, product) =
      await executeTransactionFor(Self.ProductIdentifiers.autoRenewingSubscription1.rawValue) else {
      return
    }
    await iapLogger.logRestoredTransaction(iapTransaction)
    await iapLogger.logNewTransaction(iapTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribeRestore)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.originalID),
        eventName: .subscribeRestore,
        productID: iapTransaction.transaction.productID
      )
    )
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: String(iapTransaction.transaction.id),
        eventName: .subscribe,
        productID: iapTransaction.transaction.productID
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, product.id)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: iapTransaction.transaction.purchaseDate)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, product.displayName)
    XCTAssertEqual(capturedParameters[.description] as? String, product.description)
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String,
      String(iapTransaction.transaction.id)
    )
    XCTAssertEqual(capturedParameters[.orderID] as? String, String(iapTransaction.transaction.id))
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version2.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogFailedPurchaseWithStoreKit2() async {
    let productID = Self.ProductIdentifiers.nonConsumableProduct1.rawValue
    guard let products = try? await Product.products(for: [productID]),
          let product = products.first else {
      return
    }
    iapLogger.logFailedStoreKit2Purchase(productID: productID)
    let predicate = NSPredicate { _, _ -> Bool in
      guard let capturedParameters = self.eventLogger.capturedParameters else {
        return false
      }
      guard let capturedOperationalParameters = self.eventLogger.capturedOperationalParameters,
            let iapParameters = capturedOperationalParameters[.iapParameters] else {
        XCTFail("We should have capture operational parameters")
        return false
      }
      return self.eventLogger.capturedEventName == .purchaseFailed &&
        self.eventLogger.capturedValueToSum == 0.99 &&
        capturedParameters[.contentID] as? String == product.id &&
        capturedParameters[.numItems] as? Int == 1 &&
        (capturedParameters[.transactionDate] as? String)?.isEmpty == true &&
        (capturedParameters[.productTitle] as? String)?.isEmpty == true &&
        (capturedParameters[.description] as? String)?.isEmpty == true &&
        capturedParameters[.currency] as? String == product.priceFormatStyle.currencyCode &&
        capturedParameters[.transactionID] == nil &&
        capturedParameters[.orderID] == nil &&
        capturedParameters[.implicitlyLoggedPurchase] as? String == "1" &&
        capturedParameters[.inAppPurchaseType] as? String == "inapp" &&
        capturedParameters[.subscriptionPeriod] == nil &&
        iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String ==
        IAPStoreKitVersion.version2.rawValue &&
        iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String ==
        IAPConstants.IAPSDKLibraryVersions
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testLogFailedSubscriptionWithStoreKit2() async {
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1.rawValue
    guard let products = try? await Product.products(for: [productID]),
          let product = products.first else {
      return
    }
    iapLogger.logFailedStoreKit2Purchase(productID: productID)
    let predicate = NSPredicate { _, _ -> Bool in
      guard let capturedParameters = self.eventLogger.capturedParameters else {
        return false
      }
      guard let capturedOperationalParameters = self.eventLogger.capturedOperationalParameters,
            let iapParameters = capturedOperationalParameters[.iapParameters] else {
        XCTFail("We should have capture operational parameters")
        return false
      }
      return self.eventLogger.capturedEventName == .subscribeFailed &&
        self.eventLogger.capturedValueToSum == 2.0 &&
        capturedParameters[.contentID] as? String == product.id &&
        capturedParameters[.numItems] as? Int == 1 &&
        (capturedParameters[.transactionDate] as? String)?.isEmpty == true &&
        (capturedParameters[.productTitle] as? String)?.isEmpty == true &&
        (capturedParameters[.description] as? String)?.isEmpty == true &&
        capturedParameters[.currency] as? String == product.priceFormatStyle.currencyCode &&
        capturedParameters[.transactionID] == nil &&
        capturedParameters[.orderID] == nil &&
        capturedParameters[.implicitlyLoggedPurchase] as? String == "1" &&
        capturedParameters[.inAppPurchaseType] as? String == "subs" &&
        capturedParameters[.subscriptionPeriod] as? String == "P1Y" &&
        iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String ==
        IAPStoreKitVersion.version2.rawValue &&
        iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String ==
        IAPConstants.IAPSDKLibraryVersions
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }
}

// MARK: - Store Kit 1

extension IAPTransactionLoggerTests {

  // MARK: - New Subscriptions

  func testLogNewSubscriptionTransactionStartTrialWithStoreKit1() {
    let productID = Self.ProductIdentifiers.autoRenewingSubscription2
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let sampleDiscount = SKPaymentDiscount(
      identifier: "FreeTrial",
      keyIdentifier: "key",
      nonce: UUID(),
      signature: "signature",
      timestamp: 1
    )
    let transactionID = "0"
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1, discount: sampleDiscount)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .startTrial)
    XCTAssertEqual(eventLogger.capturedValueToSum, 0)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .startTrial,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "1")
    XCTAssertEqual(capturedParameters[.hasFreeTrial] as? String, "1")
    XCTAssertEqual(capturedParameters[.trialPeriod] as? String, "P6M")
    XCTAssertEqual(capturedParameters[.trialPrice] as? Double, 0)
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewSubscriptionTransactionNonRenewableWithStoreKit1() {
    let productID = Self.ProductIdentifiers.nonRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transactionID = "0"
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchased)
    XCTAssertEqual(eventLogger.capturedValueToSum, 5)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .purchased,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewSubscriptionTransactionAutoRenewableWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribe)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .subscribe,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewSubscriptionTransactionWithStartTrialInCacheWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    IAPTransactionCache.shared.addTransaction(
      transactionID: transactionID,
      eventName: .startTrial,
      productID: productID.rawValue
    )
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribe)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .subscribe,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewSubscriptionTransactionGKDisabledWithStoreKit1() {
    TestGateKeeperManager.gateKeepers[autoLogSubscriptionGK] = false
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchased)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .purchased,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewSubscriptionTransactionStartTrialWithStartTrialInCacheWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.autoRenewingSubscription2
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let sampleDiscount = SKPaymentDiscount(
      identifier: "FreeTrial",
      keyIdentifier: "key",
      nonce: UUID(),
      signature: "signature",
      timestamp: 1
    )
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1, discount: sampleDiscount)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    IAPTransactionCache.shared.addTransaction(
      transactionID: transactionID,
      eventName: .startTrial,
      productID: productID.rawValue
    )
    iapLogger.logTransaction(transaction)
    XCTAssertNil(eventLogger.capturedEventName)
    XCTAssertNil(eventLogger.capturedValueToSum)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .startTrial,
        productID: productID.rawValue
      )
    )
    XCTAssertNil(eventLogger.capturedParameters)
  }

  func testLogNewSubscriptionTransactionWithSubscribeInCacheWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    IAPTransactionCache.shared.addTransaction(
      transactionID: transactionID,
      eventName: .subscribe,
      productID: productID.rawValue
    )
    iapLogger.logTransaction(transaction)
    XCTAssertNil(eventLogger.capturedEventName)
    XCTAssertNil(eventLogger.capturedValueToSum)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .subscribe,
        productID: productID.rawValue
      )
    )
    XCTAssertNil(eventLogger.capturedParameters)
  }

  func testLogNewSubscriptionTransactionWithRestoreInCacheWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    IAPTransactionCache.shared.addTransaction(
      transactionID: transactionID,
      eventName: .subscribeRestore,
      productID: productID.rawValue
    )
    iapLogger.logTransaction(transaction)
    XCTAssertNil(eventLogger.capturedEventName)
    XCTAssertNil(eventLogger.capturedValueToSum)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .subscribe,
        productID: productID.rawValue
      )
    )
    XCTAssertNil(eventLogger.capturedParameters)
  }

  // MARK: - New Purchases

  func testLogNewPurchaseTransactionConsumableWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.consumableProduct1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 2)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchased)
    XCTAssertEqual(eventLogger.capturedValueToSum, 20)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .purchased,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 2)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewPurchaseTransactionNonConsumableWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.nonRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchased)
    XCTAssertEqual(eventLogger.capturedValueToSum, 5.0)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .purchased,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogNewPurchaseTransactionWithPurchaseInCacheWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.nonConsumableProduct1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    IAPTransactionCache.shared.addTransaction(
      transactionID: transactionID,
      eventName: .purchased,
      productID: productID.rawValue
    )
    iapLogger.logTransaction(transaction)
    XCTAssertNil(eventLogger.capturedEventName)
    XCTAssertNil(eventLogger.capturedValueToSum)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .purchased,
        productID: productID.rawValue
      )
    )
    XCTAssertNil(eventLogger.capturedParameters)
  }

  // MARK: - Restored Subscriptions

  func testLogRestoredSubscriptionTransactionAutoRenewableStartTrialWithStoreKit1() {
    let productID = Self.ProductIdentifiers.autoRenewingSubscription2
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let sampleDiscount = SKPaymentDiscount(
      identifier: "FreeTrial",
      keyIdentifier: "key",
      nonce: UUID(),
      signature: "signature",
      timestamp: 1
    )
    let transactionID = "0"
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1, discount: sampleDiscount)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .restored, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribeRestore)
    XCTAssertEqual(eventLogger.capturedValueToSum, 0)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .subscribeRestore,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "1")
    XCTAssertEqual(capturedParameters[.hasFreeTrial] as? String, "1")
    XCTAssertEqual(capturedParameters[.trialPeriod] as? String, "P6M")
    XCTAssertEqual(capturedParameters[.trialPrice] as? Double, 0)
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogRestoredSubscriptionTransactionNonRenewableWithStoreKit1() {
    let productID = Self.ProductIdentifiers.nonRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transactionID = "0"
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .restored, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchaseRestored)
    XCTAssertEqual(eventLogger.capturedValueToSum, 5)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .purchaseRestored,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogRestoredSubscriptionTransactionAutoRenewableWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .restored, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribeRestore)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .subscribeRestore,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogRestoredSubscriptionTransactionWithRestoredInCacheWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .restored, date: now, payment: payment)
    IAPTransactionCache.shared.addTransaction(
      transactionID: transactionID,
      eventName: .subscribeRestore,
      productID: productID.rawValue
    )
    iapLogger.logTransaction(transaction)
    XCTAssertNil(eventLogger.capturedEventName)
    XCTAssertNil(eventLogger.capturedValueToSum)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .subscribeRestore,
        productID: productID.rawValue
      )
    )
    XCTAssertNil(eventLogger.capturedParameters)
  }

  func testLogRestoredSubscriptionTransactionGKDisabledWithStoreKit1() {
    TestGateKeeperManager.gateKeepers[autoLogSubscriptionGK] = false
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .restored, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchaseRestored)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .purchaseRestored,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  // MARK: - Restored Purchases

  func testLogRestoredPurchaseTransactionConsumableWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.consumableProduct1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .restored, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchaseRestored)
    XCTAssertEqual(eventLogger.capturedValueToSum, 10)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .purchaseRestored,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogRestoredPurchaseTransactionNonConsumableWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.nonConsumableProduct1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .restored, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchaseRestored)
    XCTAssertEqual(eventLogger.capturedValueToSum, 0.99)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .purchaseRestored,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogRestoredPurchaseTransactionRestoredInCacheWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.nonConsumableProduct1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .restored, date: now, payment: payment)
    IAPTransactionCache.shared.addTransaction(
      transactionID: transactionID,
      eventName: .purchaseRestored,
      productID: productID.rawValue
    )
    iapLogger.logTransaction(transaction)
    XCTAssertNil(eventLogger.capturedEventName)
    XCTAssertNil(eventLogger.capturedValueToSum)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .purchaseRestored,
        productID: productID.rawValue
      )
    )
    XCTAssertNil(eventLogger.capturedParameters)
  }

  // MARK: - Duplicates

  func testLogDuplicatePurchaseEventFirstOneShouldSucceedWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.nonConsumableProduct1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchased)
    XCTAssertEqual(eventLogger.capturedValueToSum, 0.99)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .purchased,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogPurchaseRestoredEventAndThenPurchaseEventPurchaseRestoredShouldSucceedWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.nonConsumableProduct1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let restoredTransaction = TestPaymentTransaction(
      identifier: transactionID,
      state: .restored,
      date: now,
      payment: payment
    )
    let newTransaction = TestPaymentTransaction(
      identifier: transactionID,
      state: .purchased,
      date: now,
      payment: payment
    )
    iapLogger.logTransaction(restoredTransaction)
    iapLogger.logTransaction(newTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchaseRestored)
    XCTAssertEqual(eventLogger.capturedValueToSum, 0.99)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .purchaseRestored,
        productID: productID.rawValue
      )
    )
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .purchased,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogDuplicateSubscriptionEventFirstOneShouldSucceedWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(identifier: transactionID, state: .purchased, date: now, payment: payment)
    iapLogger.logTransaction(transaction)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribe)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .subscribe,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogSubscriptionRestoredEventAndThenSubscriptionEventRestoredShouldSucceedWithStoreKit1() {
    let transactionID = "0"
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let now = Date()
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let restoredTransaction = TestPaymentTransaction(
      identifier: transactionID,
      state: .restored,
      date: now,
      payment: payment
    )
    let newTransaction = TestPaymentTransaction(
      identifier: transactionID,
      state: .purchased,
      date: now,
      payment: payment
    )
    iapLogger.logTransaction(restoredTransaction)
    iapLogger.logTransaction(newTransaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribeRestore)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .subscribeRestore,
        productID: productID.rawValue
      )
    )
    XCTAssertTrue(
      IAPTransactionCache.shared.contains(
        transactionID: transactionID,
        eventName: .subscribe,
        productID: productID.rawValue
      )
    )
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(
      capturedParameters[.transactionDate] as? String,
      dateFormatter.string(from: now)
    )
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertEqual(iapParameters[AppEvents.ParameterName.transactionID.rawValue] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.orderID] as? String, transactionID)
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  // MARK: - Initiated Checkout

  func testLogInitiatedCheckoutPurchaseEvent() {
    let productID = Self.ProductIdentifiers.nonConsumableProduct1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(state: .purchasing, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .initiatedCheckout)
    XCTAssertEqual(eventLogger.capturedValueToSum, 0.99)
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(capturedParameters[.transactionDate] as? String, "")
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertNil(capturedParameters[.transactionID])
    XCTAssertNil(capturedParameters[.orderID])
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogInitiatedCheckoutSubscriptionEvent() {
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(state: .purchasing, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribeInitiatedCheckout)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2.0)
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(capturedParameters[.transactionDate] as? String, "")
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertNil(capturedParameters[.transactionID])
    XCTAssertNil(capturedParameters[.orderID])
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogInitiatedCheckoutSubscriptionEventGKDisabled() {
    TestGateKeeperManager.gateKeepers[autoLogSubscriptionGK] = false
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(state: .purchasing, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .initiatedCheckout)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(capturedParameters[.transactionDate] as? String, "")
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertNil(capturedParameters[.transactionID])
    XCTAssertNil(capturedParameters[.orderID])
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  // MARK: - Failed

  func testLogFailedPurchaseEvent() {
    let productID = Self.ProductIdentifiers.nonConsumableProduct1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(state: .failed, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchaseFailed)
    XCTAssertEqual(eventLogger.capturedValueToSum, 0.99)
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(capturedParameters[.transactionDate] as? String, "")
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertNil(capturedParameters[.transactionID])
    XCTAssertNil(capturedParameters[.orderID])
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "inapp")
    XCTAssertNil(capturedParameters[.subscriptionPeriod])
    XCTAssertNil(capturedParameters[.isStartTrial])
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogFailedSubscriptionEvent() {
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(state: .failed, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .subscribeFailed)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2.0)
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(capturedParameters[.transactionDate] as? String, "")
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertNil(capturedParameters[.transactionID])
    XCTAssertNil(capturedParameters[.orderID])
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }

  func testLogFailedSubscriptionEventGKDisabled() {
    TestGateKeeperManager.gateKeepers[autoLogSubscriptionGK] = false
    let productID = Self.ProductIdentifiers.autoRenewingSubscription1
    iapSKProductRequestFactory.stubbedResponse = SampleSKProductsResponse.getResponseFor(productID: productID)
    let payment = TestPayment(productIdentifier: productID.rawValue, quantity: 1)
    let transaction = TestPaymentTransaction(state: .failed, payment: payment)
    iapLogger.logTransaction(transaction)
    XCTAssertEqual(eventLogger.capturedEventName, .purchaseFailed)
    XCTAssertEqual(eventLogger.capturedValueToSum, 2)
    guard let capturedParameters = eventLogger.capturedParameters else {
      XCTFail("We should have capturedParameters")
      return
    }
    guard let capturedOperationalParameters = eventLogger.capturedOperationalParameters,
          let iapParameters = capturedOperationalParameters[.iapParameters] else {
      XCTFail("We should have capture operational parameters")
      return
    }
    XCTAssertEqual(capturedParameters[.contentID] as? String, productID.rawValue)
    XCTAssertEqual(capturedParameters[.numItems] as? Int, 1)
    XCTAssertEqual(capturedParameters[.transactionDate] as? String, "")
    XCTAssertEqual(capturedParameters[.productTitle] as? String, "")
    XCTAssertEqual(capturedParameters[.description] as? String, "")
    XCTAssertEqual(capturedParameters[.currency] as? String, "USD")
    XCTAssertNil(capturedParameters[.transactionID])
    XCTAssertNil(capturedParameters[.orderID])
    XCTAssertEqual(capturedParameters[.implicitlyLoggedPurchase] as? String, "1")
    XCTAssertEqual(capturedParameters[.inAppPurchaseType] as? String, "subs")
    XCTAssertEqual(capturedParameters[.subscriptionPeriod] as? String, "P1Y")
    XCTAssertEqual(capturedParameters[.isStartTrial] as? String, "0")
    XCTAssertNil(capturedParameters[.hasFreeTrial])
    XCTAssertNil(capturedParameters[.trialPeriod])
    XCTAssertNil(capturedParameters[.trialPrice])
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapClientLibraryVersion.rawValue] as? String,
      IAPStoreKitVersion.version1.rawValue
    )
    XCTAssertEqual(
      iapParameters[AppEvents.ParameterName.iapsdkLibraryVersions.rawValue] as? String,
      IAPConstants.IAPSDKLibraryVersions
    )
  }
}
