/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSDKCoreKit
@testable import IAPTestsHostApp

import Foundation
import StoreKitTest
import UIKit
import XCTest

// swiftlint:disable:this test_classes_should_be_final
// swiftlint:disable:next prefer_final_classes
class StoreKitTestCase: XCTestCase {

  static let configFileName = "FBSDKStoreKitConfigurationUnitTests"

  enum ProductIdentifiers: String, CaseIterable {
    case consumableProduct1 = "com.fbsdk.consumable.p1"
    case nonConsumableProduct1 = "com.fbsdk.nonconsumable.p1"
    case nonConsumableProduct2 = "com.fbsdk.nonconsumable.p2"
    case autoRenewingSubscription1 = "com.fbsdk.autorenewing.s1"
    case autoRenewingSubscription2 = "com.fbsdk.autorenewing.s2"
    case nonRenewingSubscription1 = "com.fbsdk.nonrenewing.s1"
  }

  enum StoreKitTestCaseError: Error {
    case purchaseFailed
  }

  static var allIdentifiers = ProductIdentifiers.allCases.map { id in
    id.rawValue
  }

  private var anyTestSession: Any?

  func getIAPTransactionForPurchaseResult(result: Product.PurchaseResult) throws -> IAPTransaction {
    switch result {
    case let .success(verificationResult):
      return verificationResult.iapTransaction
    default:
      throw StoreKitTestCaseError.purchaseFailed
    }
  }

  private var transactionUpdatesTask: Task<Void, Never>?

  override func setUp() async throws {
    try await super.setUp()
    // Configure local StoreKit before the first StoreKit or SDK operation.
    logStoreKitPhase("session setup started")
    try setupTestSession()
    logStoreKitPhase("session setup completed")
    IAPTransactionCache.shared.reset()
    startObservingTransactionUpdates()
  }

  override func tearDown() {
    transactionUpdatesTask?.cancel()
    transactionUpdatesTask = nil
    tearDownTestSession()
    super.tearDown()
  }

  /// StoreKit emits "Making a purchase without listening for transaction updates
  /// risks missing successful purchases. Create a Task to iterate
  /// Transaction.updates at launch." on every `Product.purchase()` in this target,
  /// because nothing here iterated that sequence. Drain it for the lifetime of
  /// each test so updates have a consumer.
  ///
  /// Deliberately does not call `finish()` on what it receives: several tests
  /// depend on specific transactions staying unfinished, and finishing them here
  /// would silently change what they are asserting.
  private func startObservingTransactionUpdates() {
    transactionUpdatesTask = Task.detached {
      // Draining is the whole point; cancelling the task in tearDown ends the
      // iteration, so there is nothing to do per element.
      for await _ in Transaction.updates {}
    }
  }
}

extension StoreKitTestCase {
  // Flush phase boundaries so a stalled CI read can identify the suspended call.
  func logStoreKitPhase(_ phase: String) {
    FileHandle.standardError.write(Data("StoreKit test \(name): \(phase)\n".utf8))
  }

  // Supply the hosted app's visible scene instead of relying on an implicit UI anchor.
  @MainActor
  func purchaseTestProduct(_ product: Product) async throws -> Product.PurchaseResult {
    guard #available(iOS 17.0, *) else {
      return try await product.purchase()
    }
    let deadline = Date().addingTimeInterval(5)
    var purchaseScene: UIWindowScene?
    repeat {
      let candidate = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
        ($0.activationState == .foregroundActive || $0.activationState == .foregroundInactive) &&
          $0.windows.contains { window in
            !window.isHidden && window.rootViewController?.viewIfLoaded?.window === window
          }
      }
      if Date() <= deadline { purchaseScene = candidate }
      if purchaseScene != nil || Date() >= deadline { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < deadline
    let scene = try XCTUnwrap(purchaseScene, "The StoreKit test host has no foreground purchase scene")
    logStoreKitPhase("explicit purchase scene available")
    return try await product.purchase(confirmIn: scene)
  }

  // iOS 27.1 StoreKit tests can leave repeated purchases unfinished after finish().
  // Enumerating first worked around this in a StoreKit-only repro. Use only when
  // preparing finished purchases; don't bypass tests of unfinished transactions.
  func finishTestTransaction(_ transaction: Transaction) async throws {
    logStoreKitPhase("unfinished enumeration before finish started")
    // Require the exact verified ID, allowing bounded publication across fresh snapshots.
    // Absence alone isn't evidence that a purchase was already finished.
    let deadline = Date().addingTimeInterval(5)
    var observedID: UInt64?
    var attempt = 0
    repeat {
      attempt += 1
      let before = try await verifiedUnfinishedIDs()
      if before.contains(transaction.id), Date() <= deadline {
        observedID = transaction.id
        break
      }
      if attempt == 1 {
        logStoreKitPhase("unfinished state not ready: target=\(transaction.id) ids=\(before)")
      }
      if Date() >= deadline { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < deadline
    logStoreKitPhase("unfinished enumeration before finish completed after \(attempt) reads")
    _ = try XCTUnwrap(observedID, "Fresh purchase missing from Transaction.unfinished within five seconds")

    logStoreKitPhase("finish started")
    await transaction.finish()
    logStoreKitPhase("finish completed")

    logStoreKitPhase("unfinished enumeration after finish started")
    let finishDeadline = Date().addingTimeInterval(5)
    var finished = false
    var finishReads = 0
    repeat {
      finishReads += 1
      let after = try await verifiedUnfinishedIDs()
      if !after.contains(transaction.id), Date() <= finishDeadline {
        finished = true
        break
      }
      if finishReads == 1 {
        logStoreKitPhase("finished state not ready: target=\(transaction.id) ids=\(after)")
      }
      if Date() >= finishDeadline { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    } while Date() < finishDeadline
    logStoreKitPhase("unfinished enumeration after finish completed after \(finishReads) reads")
    _ = try XCTUnwrap(finished ? transaction : nil, "Finished purchase remained unfinished within five seconds")
  }

  private func verifiedUnfinishedIDs() async throws -> [UInt64] {
    var ids: [UInt64] = []
    for await result in Transaction.unfinished {
      switch result {
      case let .verified(value): ids.append(value.id)
      case let .unverified(_, error): throw error
      }
    }
    return ids
  }

  var testSession: SKTestSession {
    anyTestSession as! SKTestSession // swiftlint:disable:this force_cast
  }

  func setupTestSession() throws {
    anyTestSession = try SKTestSession(configurationFileNamed: Self.configFileName)
    testSession.resetToDefaultState()
    testSession.clearTransactions()
    testSession.disableDialogs = true
  }

  func tearDownTestSession() {
    anyTestSession = nil
  }
}
