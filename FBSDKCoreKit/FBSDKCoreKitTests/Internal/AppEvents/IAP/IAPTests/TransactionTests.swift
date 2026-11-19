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
import XCTest

final class TransactionTests: StoreKitTestCase {

  // StoreKit does not promise that `Product.products(for:)` returns products in
  // the order they were requested, and on iOS 27 it does not. Look each product
  // up by identifier instead of indexing into the result.
  private func product(
    _ identifier: ProductIdentifiers,
    in products: [Product]
  ) throws -> Product {
    try XCTUnwrap(
      products.first { $0.id == identifier.rawValue },
      "No product for \(identifier.rawValue) in \(products.map(\.id))"
    )
  }

  private func purchaseAndFinish(_ product: Product) async throws -> IAPTransaction {
    let result = try await product.purchase()
    let iapTransaction = try getIAPTransactionForPurchaseResult(result: result)
    await iapTransaction.transaction.finish()
    return iapTransaction
  }

  /// Skips, rather than silently passing, when the StoreKit test session cannot
  /// vend the configured products. On some simulator runtimes `Product.products(for:)`
  /// returns nothing at all, and the previous `guard ... else { return }` form
  /// reported those runs as passes while asserting nothing.
  private func allProducts() async throws -> [Product] {
    let products = try await Product.products(for: Self.allIdentifiers)
    try XCTSkipUnless(
      products.count == Self.allIdentifiers.count,
      "StoreKit test session vended \(products.count) of \(Self.allIdentifiers.count) "
        + "configured products; skipping rather than reporting a vacuous pass"
    )
    return products
  }

  private func verifiedHistoryTransaction(
    _ id: UInt64,
    in history: [VerificationResult<Transaction>]
  ) throws -> Transaction {
    let result = try XCTUnwrap(history.first { $0.iapTransaction.transaction.id == id })
    switch result {
    case let .verified(value): return value
    case let .unverified(_, error): throw error
    }
  }

  func testGetAllTransactions() async throws {
    let products = try await allProducts()
    for product in products {
      _ = try await purchaseAndFinish(product)
    }
    let transactions = await Transaction.all.getValues()
    let expectedCount = products.count - 1 // Cannot observe Consumables by default
    XCTAssertEqual(transactions.count, expectedCount)
  }

  func testGetCurrentEntitlements() async throws {
    let products = try await allProducts()
    for product in products {
      _ = try await purchaseAndFinish(product)
    }
    let transactions = await Transaction.currentEntitlements.getValues()
    let expectedCount = products.count - 1 // Cannot observe Consumables by default
    XCTAssertEqual(transactions.count, expectedCount)
  }

  func testGetNewCandidateTransactions() async throws {
    let products = try await allProducts()
    let purchasedBeforeCutoff = try product(.nonRenewingSubscription1, in: products)
    let refunded = try product(.nonConsumableProduct1, in: products)
    let neverFinished = try product(.nonConsumableProduct2, in: products)
    let expected = try product(.autoRenewingSubscription1, in: products)

    let olderTransaction = try await purchaseAndFinish(purchasedBeforeCutoff)
    IAPTransactionCache.shared.newCandidatesDate = Date()
    let cutoff = try XCTUnwrap(IAPTransactionCache.shared.newCandidatesDate)

    let refundedTransaction = try await purchaseAndFinish(refunded)
    try testSession.refundTransaction(identifier: UInt(refundedTransaction.transaction.id))

    // Finish the positive candidate before creating the deliberately unfinished
    // purchase, so preparing one receipt can't change the other's fixture state.
    let expectedResult = try await expected.purchase()
    guard case let .success(.verified(expectedReceipt)) = expectedResult else {
      throw StoreKitTestCaseError.purchaseFailed
    }
    try await finishTestTransaction(expectedReceipt)

    let unfinishedResult = try await neverFinished.purchase()
    guard case let .success(.verified(unfinishedReceipt)) = unfinishedResult else {
      throw StoreKitTestCaseError.purchaseFailed
    }

    let history = await Transaction.all.getValues()
    let olderHistory = try verifiedHistoryTransaction(olderTransaction.transaction.id, in: history)
    XCTAssertLessThanOrEqual(olderHistory.purchaseDate, cutoff)
    XCTAssertNil(olderHistory.revocationDate)
    if let expirationDate = olderHistory.expirationDate {
      XCTAssertGreaterThan(expirationDate, Date())
    }
    let refundedHistory = try verifiedHistoryTransaction(refundedTransaction.transaction.id, in: history)
    XCTAssertGreaterThan(refundedHistory.purchaseDate, cutoff)
    XCTAssertNotNil(refundedHistory.revocationDate)
    let positiveHistory = try verifiedHistoryTransaction(expectedReceipt.id, in: history)
    XCTAssertGreaterThan(positiveHistory.purchaseDate, cutoff)
    XCTAssertNil(positiveHistory.revocationDate)
    XCTAssertGreaterThan(try XCTUnwrap(positiveHistory.expirationDate), Date())

    let unfinishedIDs = await Transaction.unfinished.getValues().map(\.iapTransaction.transaction.id)
    XCTAssertTrue(unfinishedIDs.contains(unfinishedReceipt.id), "Unfinished control is missing")
    XCTAssertFalse(unfinishedIDs.contains(expectedReceipt.id), "Finished candidate is still unfinished")
    XCTAssertFalse(unfinishedIDs.contains(olderTransaction.transaction.id))
    XCTAssertFalse(unfinishedIDs.contains(refundedTransaction.transaction.id))
    XCTAssertGreaterThan(unfinishedReceipt.purchaseDate, cutoff)
    XCTAssertNil(unfinishedReceipt.revocationDate)

    var candidateTransactions = await Transaction.getNewCandidateTransactions()
    XCTAssertEqual(candidateTransactions.map(\.iapTransaction.transaction.id), [expectedReceipt.id])

    IAPTransactionCache.shared.addTransaction(
      transactionID: String(expectedReceipt.id),
      eventName: .purchased,
      productID: expectedReceipt.productID
    )
    XCTAssertTrue(IAPTransactionCache.shared.contains(
      transactionID: String(expectedReceipt.id),
      productID: expectedReceipt.productID
    ))
    candidateTransactions = await Transaction.getNewCandidateTransactions()
    XCTAssertTrue(candidateTransactions.isEmpty)
  }

  func testGetNewCandidateTransactionsWithExpiredSubscription() async throws {
    guard #available(iOS 17.0, *) else {
      throw XCTSkip("SKTestSession.buyProduct / expireSubscription require iOS 17")
    }

    let identifier = ProductIdentifiers.autoRenewingSubscription1.rawValue
    let transaction = try await testSession.buyProduct(identifier: identifier)
    try await finishTestTransaction(transaction)

    let activeCandidates = await Transaction.getNewCandidateTransactions()
    XCTAssertTrue(activeCandidates.contains { $0.iapTransaction.transaction.id == transaction.id })

    try testSession.disableAutoRenewForTransaction(identifier: .init(transaction.id))
    let testTransaction = try XCTUnwrap(testSession.allTransactions().first {
      $0.identifier == .init(transaction.id) && $0.productIdentifier == identifier
    })
    XCTAssertFalse(testTransaction.autoRenewingEnabled)
    try testSession.expireSubscription(productIdentifier: identifier)
    let expiredTestTransaction = try XCTUnwrap(testSession.allTransactions().first {
      $0.identifier == .init(transaction.id) && $0.productIdentifier == identifier
    })
    let controllerExpiration = try XCTUnwrap(expiredTestTransaction.expirationDate)
    logStoreKitPhase("controller expiry=\(controllerExpiration)")
    XCTAssertLessThanOrEqual(controllerExpiration, Date(), "Test controller did not apply expiry")
    _ = try XCTUnwrap(
      transaction.environment == .xcode ? transaction : nil,
      "Expiry synchronization requires the local Xcode StoreKit environment"
    )
    // Refresh the local test receipt after mutating the test controller's expiry.
    try await AppStore.sync()

    // Query the current receipt before checking that transaction history agrees.
    // Expiry need not emit a Transaction.updates event.
    let deadline = Date().addingTimeInterval(5)
    var expiredTransaction: Transaction?
    var lastReceiptState = "no receipt"
    repeat {
      if let result = await Transaction.latest(for: identifier) {
        switch result {
        case let .verified(value):
          lastReceiptState = "verified id=\(value.id) original=\(value.originalID) expiry=\(String(describing: value.expirationDate))"
          if value.id == transaction.id,
             let expirationDate = value.expirationDate,
             expirationDate <= Date(),
             Date() <= deadline {
            expiredTransaction = value
          }
        case let .unverified(_, error): throw error
        }
      }
      if expiredTransaction != nil || Date() >= deadline { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < deadline
    logStoreKitPhase("expiry target=\(transaction.id) controller=\(controllerExpiration) latest=\(lastReceiptState)")
    let expired = try XCTUnwrap(expiredTransaction, "StoreKit did not apply the requested expiry: \(lastReceiptState)")
    let expirationDate = try XCTUnwrap(expired.expirationDate)
    XCTAssertLessThanOrEqual(expirationDate, Date())
    let history = await Transaction.all.getValues()
    let historyResult = try XCTUnwrap(history.first {
      $0.iapTransaction.transaction.id == transaction.id
    })
    let historyTransaction: Transaction
    switch historyResult {
    case let .verified(value): historyTransaction = value
    case let .unverified(_, error): throw error
    }
    let historyExpiration = try XCTUnwrap(historyTransaction.expirationDate)
    XCTAssertLessThanOrEqual(historyExpiration, Date(), "History still reports an active subscription")
    await expired.finish()
    let unfinished = await Transaction.unfinished.getValues()
    XCTAssertFalse(unfinished.contains { $0.iapTransaction.transaction.id == transaction.id })

    let candidateTransactions = await Transaction.getNewCandidateTransactions()
    let details = candidateTransactions.map { result in
      let value = result.iapTransaction.transaction
      return "id=\(value.id) product=\(value.productID) expiration=\(String(describing: value.expirationDate))"
    }
    XCTAssertEqual(candidateTransactions.count, 0, "Expired-subscription candidates: \(details)")
  }
}
