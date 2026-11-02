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

final class IAPTransactionObserverTests: StoreKitTestCase {

  // swiftlint:disable implicitly_unwrapped_optional
  private var queue: TestPaymentQueue!
  private var appEventsConfigurationProvider: TestAppEventsConfigurationProvider!
  // swiftlint:enable implicitly_unwrapped_optiona

  override func setUp() async throws {
    try await super.setUp()
    appEventsConfigurationProvider = TestAppEventsConfigurationProvider()
    appEventsConfigurationProvider.stubbedConfiguration = TestAppEventsConfiguration(iapObservationTime: 10000000000)
    queue = TestPaymentQueue()
    IAPTransactionObserver.shared.reset()
    IAPTransactionObserver.shared.configuredDependencies = .init(
      iapTransactionLoggingFactory: TestIAPTransactionLoggingFactory(),
      paymentQueue: queue,
      appEventsConfigurationProvider: appEventsConfigurationProvider
    )
    IAPTransactionCache.shared.reset()
    TestIAPTransactionLogger.reset()
  }
}

// MARK: - Store Kit 2

extension IAPTransactionObserverTests {
  func testIAPObservationTime() async {
    IAPTransactionObserver.shared.startObserving()
    XCTAssertEqual(IAPTransactionObserver.shared.configuredObservationTime, 10000000000)
    IAPTransactionObserver.shared.stopObserving()
  }

  func testStopCancelsStoreKit2Listener() async throws {
    IAPTransactionObserver.shared.startObserving()
    let task = try XCTUnwrap(IAPTransactionObserver.shared.transactionListenerTaskForTesting)
    IAPTransactionObserver.shared.stopObserving()
    XCTAssertTrue(task.isCancelled)
    // Ensure the pre-fix listener also terminates instead of leaking out of this test.
    task.cancel()
    await task.value
  }

  func testObserveRestoredPurchases() async {
    IAPTransactionObserver.shared.setReleaseDate(Date())
    guard let products =
      try? await Product.products(for: [Self.ProductIdentifiers.nonConsumableProduct1.rawValue]) else {
      return
    }
    guard let result = try? await products.first?.purchase() else {
      return
    }
    guard let iapTransaction = try? getIAPTransactionForPurchaseResult(result: result) else {
      return
    }
    await iapTransaction.transaction.finish()
    IAPTransactionObserver.shared.startObserving()
    let predicate = NSPredicate { _, _ -> Bool in
      let hasRestored = IAPTransactionCache.shared.hasRestoredPurchases
      let didRestore = TestIAPTransactionLogger.restoredStoreKit2Transactions.contains {
        $0.transaction.id == iapTransaction.transaction.id
      }
      return hasRestored && didRestore && TestIAPTransactionLogger.newStoreKit2Transactions.isEmpty
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testObserveEmptyRestoredPurchases() async {
    IAPTransactionObserver.shared.startObserving()
    let predicate = NSPredicate { _, _ -> Bool in
      let hasRestored = IAPTransactionCache.shared.hasRestoredPurchases
      let noTransactions = TestIAPTransactionLogger.restoredStoreKit2Transactions.isEmpty &&
        TestIAPTransactionLogger.newStoreKit2Transactions.isEmpty
      return hasRestored && noTransactions
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testAlreadyObservedRestoredPurchases() async {
    IAPTransactionCache.shared.newCandidatesDate = Date()
    IAPTransactionCache.shared.hasRestoredPurchases = true
    guard let products =
      try? await Product.products(for: [Self.ProductIdentifiers.nonConsumableProduct1.rawValue]) else {
      return
    }
    guard let result = try? await products.first?.purchase() else {
      return
    }
    guard let iapTransaction = try? getIAPTransactionForPurchaseResult(result: result) else {
      return
    }
    await iapTransaction.transaction.finish()
    IAPTransactionObserver.shared.startObserving()
    let predicate = NSPredicate { _, _ -> Bool in
      TestIAPTransactionLogger.restoredStoreKit2Transactions.isEmpty &&
        !TestIAPTransactionLogger.newStoreKit2Transactions.isEmpty
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testObserveNewTransactionsAfterTransactionMade() async {
    IAPTransactionCache.shared.newCandidatesDate = Date()
    IAPTransactionCache.shared.hasRestoredPurchases = true
    guard let products =
      try? await Product.products(for: [Self.ProductIdentifiers.nonConsumableProduct1.rawValue]) else {
      return
    }
    guard let result = try? await products.first?.purchase() else {
      return
    }
    guard let iapTransaction = try? getIAPTransactionForPurchaseResult(result: result) else {
      return
    }
    await iapTransaction.transaction.finish()
    IAPTransactionObserver.shared.startObserving()
    let predicate = NSPredicate { _, _ -> Bool in
      let didLog = TestIAPTransactionLogger.newStoreKit2Transactions.contains {
        $0.transaction.id == iapTransaction.transaction.id
      }
      guard let newCandidateDate = IAPTransactionCache.shared.newCandidatesDate else {
        return false
      }
      let dateCheck = newCandidateDate == iapTransaction.transaction.purchaseDate
      return TestIAPTransactionLogger.restoredStoreKit2Transactions.isEmpty && didLog && dateCheck
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testObserveNewTransactionsBeforeTransactionMade() async {
    IAPTransactionCache.shared.hasRestoredPurchases = true
    IAPTransactionObserver.shared.startObserving()
    guard let products =
      try? await Product.products(for: [Self.ProductIdentifiers.nonConsumableProduct1.rawValue]) else {
      return
    }
    guard let result = try? await products.first?.purchase() else {
      return
    }
    guard let iapTransaction = try? getIAPTransactionForPurchaseResult(result: result) else {
      return
    }
    await iapTransaction.transaction.finish()
    let predicate = NSPredicate { _, _ -> Bool in
      let didLog = TestIAPTransactionLogger.newStoreKit2Transactions.contains {
        $0.transaction.id == iapTransaction.transaction.id
      }
      guard let newCandidateDate = IAPTransactionCache.shared.newCandidatesDate else {
        return false
      }
      let dateCheck = newCandidateDate == iapTransaction.transaction.purchaseDate
      return TestIAPTransactionLogger.restoredStoreKit2Transactions.isEmpty && didLog && dateCheck
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testObserveEmptyNewTransactions() async {
    let now = Date()
    IAPTransactionCache.shared.hasRestoredPurchases = true
    IAPTransactionObserver.shared.startObserving()
    let predicate = NSPredicate { _, _ -> Bool in
      let didNotObserve = TestIAPTransactionLogger.newStoreKit2Transactions.isEmpty
      guard let newCandidateDate = IAPTransactionCache.shared.newCandidatesDate else {
        return false
      }
      return didNotObserve && newCandidateDate > now
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testObserveNewTransactionsOldDate() async {
    IAPTransactionCache.shared.hasRestoredPurchases = true
    guard let products =
      try? await Product.products(for: [Self.ProductIdentifiers.nonConsumableProduct1.rawValue]) else {
      return
    }
    guard let result = try? await products.first?.purchase() else {
      return
    }
    guard let iapTransaction = try? getIAPTransactionForPurchaseResult(result: result) else {
      return
    }
    await iapTransaction.transaction.finish()
    let now = Date()
    IAPTransactionCache.shared.newCandidatesDate = now
    IAPTransactionObserver.shared.startObserving()
    let predicate = NSPredicate { _, _ -> Bool in
      let didNotObserve = TestIAPTransactionLogger.newStoreKit2Transactions.isEmpty
      let newCandidateDate = IAPTransactionCache.shared.newCandidatesDate
      return didNotObserve && newCandidateDate == now
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testObserveRestoredAndNewTransactions() async {
    IAPTransactionObserver.shared.setReleaseDate(Date())
    let productIDs = [
      Self.ProductIdentifiers.nonConsumableProduct1.rawValue,
      Self.ProductIdentifiers.nonRenewingSubscription1.rawValue,
    ]
    guard let products = try? await Product.products(for: productIDs) else {
      return
    }
    guard let result1 = try? await products.first?.purchase() else {
      return
    }
    guard let iapTransaction1 = try? getIAPTransactionForPurchaseResult(result: result1) else {
      return
    }
    await iapTransaction1.transaction.finish()
    IAPTransactionObserver.shared.startObserving()
    guard let result2 = try? await products.last?.purchase() else {
      return
    }
    guard let iapTransaction2 = try? getIAPTransactionForPurchaseResult(result: result2) else {
      return
    }
    await iapTransaction2.transaction.finish()
    let predicate = NSPredicate { _, _ -> Bool in
      let didRestore = TestIAPTransactionLogger.restoredStoreKit2Transactions.contains {
        $0.transaction.id == iapTransaction1.transaction.id
      }
      let didObserveNew = TestIAPTransactionLogger.newStoreKit2Transactions.contains {
        $0.transaction.id == iapTransaction2.transaction.id
      }
      let hasRestored = IAPTransactionCache.shared.hasRestoredPurchases
      var dateCheck = false
      if let newCandidateDate = IAPTransactionCache.shared.newCandidatesDate {
        dateCheck = newCandidateDate == iapTransaction2.transaction.purchaseDate
      }
      return didRestore && hasRestored && didObserveNew && dateCheck
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 30.0)
  }

  func testShouldNotObserveOldTransactions() async {
    let now = Date()
    IAPTransactionCache.shared.hasRestoredPurchases = true
    guard let products =
      try? await Product.products(for: [Self.ProductIdentifiers.nonConsumableProduct1.rawValue]) else {
      return
    }
    guard let result = try? await products.first?.purchase() else {
      return
    }
    guard let iapTransaction = try? getIAPTransactionForPurchaseResult(result: result) else {
      return
    }
    await iapTransaction.transaction.finish()
    IAPTransactionObserver.shared.startObserving()
    let predicate = NSPredicate { _, _ -> Bool in
      guard let newCandidateDate = IAPTransactionCache.shared.newCandidatesDate else {
        return false
      }
      return TestIAPTransactionLogger.restoredStoreKit2Transactions.isEmpty &&
        TestIAPTransactionLogger.newStoreKit2Transactions.isEmpty &&
        newCandidateDate > now
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }

  func testShouldNotObserveOldRestoredTransactions() async {
    guard let products =
      try? await Product.products(for: [Self.ProductIdentifiers.nonConsumableProduct1.rawValue]) else {
      return
    }
    guard let result = try? await products.first?.purchase() else {
      return
    }
    guard let iapTransaction = try? getIAPTransactionForPurchaseResult(result: result) else {
      return
    }
    await iapTransaction.transaction.finish()
    let now = Date()
    IAPTransactionCache.shared.newCandidatesDate = now
    IAPTransactionObserver.shared.setReleaseDate(now)
    IAPTransactionObserver.shared.startObserving()
    let predicate = NSPredicate { _, _ -> Bool in
      TestIAPTransactionLogger.restoredStoreKit2Transactions.isEmpty &&
        TestIAPTransactionLogger.newStoreKit2Transactions.isEmpty
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    await fulfillment(of: [expectation], timeout: 20.0)
  }
}

// MARK: - Store Kit 1

extension IAPTransactionObserverTests {
  func testStartObserving() {
    IAPTransactionObserver.shared.startObserving()
    XCTAssertTrue(queue.addTransactionObserverWasCalled)
  }

  func testStopObserving() {
    IAPTransactionObserver.shared.startObserving()
    IAPTransactionObserver.shared.stopObserving()
    XCTAssertTrue(queue.removeTransactionObserverWasCalled)
  }

  func testStopObservingWhenNotAlreadyObserving() {
    IAPTransactionObserver.shared.stopObserving()
    XCTAssertFalse(queue.removeTransactionObserverWasCalled)
  }

  func testObserveNewPurchasedTransaction() {
    let transaction = TestPaymentTransaction(state: .purchased)
    IAPTransactionObserver.shared.paymentQueue(queue, updatedTransactions: [transaction])
    XCTAssertEqual(TestIAPTransactionLogger.storeKit1Transactions.count, 1)
    XCTAssertEqual(TestIAPTransactionLogger.storeKit1Transactions.first, transaction)
  }

  func testObserveNewRestoredTransaction() {
    let transaction = TestPaymentTransaction(state: .restored)
    IAPTransactionObserver.shared.paymentQueue(queue, updatedTransactions: [transaction])
    XCTAssertEqual(TestIAPTransactionLogger.storeKit1Transactions.count, 1)
    XCTAssertEqual(TestIAPTransactionLogger.storeKit1Transactions.first, transaction)
  }

  func testObserveNewPurchasingTransaction() {
    let transaction = TestPaymentTransaction(state: .purchasing)
    IAPTransactionObserver.shared.paymentQueue(queue, updatedTransactions: [transaction])
    XCTAssertEqual(TestIAPTransactionLogger.storeKit1Transactions.count, 1)
    XCTAssertEqual(TestIAPTransactionLogger.storeKit1Transactions.first, transaction)
  }

  func testObserveNewFailedTransaction() {
    let transaction = TestPaymentTransaction(state: .failed)
    IAPTransactionObserver.shared.paymentQueue(queue, updatedTransactions: [transaction])
    XCTAssertEqual(TestIAPTransactionLogger.storeKit1Transactions.count, 1)
    XCTAssertEqual(TestIAPTransactionLogger.storeKit1Transactions.first, transaction)
  }

  func testObserveNewDeferredTransaction() {
    let transaction = TestPaymentTransaction(state: .deferred)
    IAPTransactionObserver.shared.paymentQueue(queue, updatedTransactions: [transaction])
    XCTAssertTrue(TestIAPTransactionLogger.storeKit1Transactions.isEmpty)
  }

  func testObserveEmptyUpdatedTransactions() {
    IAPTransactionObserver.shared.paymentQueue(queue, updatedTransactions: [])
    XCTAssertTrue(TestIAPTransactionLogger.storeKit1Transactions.isEmpty)
  }

  func testObserveMultipleNewTransactions() {
    let transactions = [
      TestPaymentTransaction(state: .failed),
      TestPaymentTransaction(state: .purchasing),
      TestPaymentTransaction(state: .purchased),
      TestPaymentTransaction(state: .restored),
      TestPaymentTransaction(state: .deferred),
    ]
    IAPTransactionObserver.shared.paymentQueue(queue, updatedTransactions: transactions)
    XCTAssertEqual(TestIAPTransactionLogger.storeKit1Transactions.count, 4)
  }
}
