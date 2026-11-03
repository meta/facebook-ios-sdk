/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import StoreKit

final class IAPTransactionObserver: NSObject {

  var configuredDependencies: ObjectDependencies?
  var defaultDependencies: ObjectDependencies? = .init(
    iapTransactionLoggingFactory: IAPTransactionLoggingFactory(),
    paymentQueue: SKPaymentQueue.default(),
    appEventsConfigurationProvider: _AppEventsConfigurationManager.shared
  )

  private var isObservingStoreKit1Transactions = false
  private var isObservingStoreKit2Transactions = false
  private var isProcessingNewTransactions = false
  private var anyTransactionListenerTask: Any?
  private var observationTime: UInt64 = IAPConstants.defaultIAPObservationTime
  private var releaseDate: Date

  static let shared = IAPTransactionObserver()

  private static func getReleaseDate() -> Date {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    if let date = dateFormatter.date(from: IAPConstants.sk2ReleaseDate) {
      return date
    }
    return IAPTransactionCache.shared.newCandidatesDate ?? Date()
  }

  private override init() {
    releaseDate = Self.getReleaseDate()
    super.init()
  }

  deinit {
    stopObserving()
  }
}

// MARK: - DependentAsObject

extension IAPTransactionObserver: DependentAsObject {
  struct ObjectDependencies {
    var iapTransactionLoggingFactory: IAPTransactionLoggingCreating
    var paymentQueue: SKPaymentQueue
    var appEventsConfigurationProvider: _AppEventsConfigurationProviding
  }
}

// MARK: - Public APIs

extension IAPTransactionObserver: _TransactionObserving {
  func startObserving() {
    if IAPTransactionCache.shared.newCandidatesDate == nil {
      IAPTransactionCache.shared.newCandidatesDate = Date()
    }
    startObservingStoreKit2()
    startObservingStoreKit1()
  }

  func stopObserving() {
    stopObservingStoreKit2()
    stopObservingStoreKit1()
  }
}

// MARK: - Store Kit 2

extension IAPTransactionObserver {
  // The listener catches sleep cancellation, so the stored task is nonthrowing.
  private var transactionListenerTask: Task<Void, Never>? {
    anyTransactionListenerTask as? Task<Void, Never>
  }

  private func checkForRestoredPurchases() async {
    guard isObservingStoreKit2Transactions else {
      return
    }
    guard !IAPTransactionCache.shared.hasRestoredPurchases else {
      return
    }
    var candidateRestoredTransactions = await Transaction.currentEntitlements.getValues()
    candidateRestoredTransactions = candidateRestoredTransactions.filter { result in
      let transaction = result.iapTransaction.transaction
      return transaction.purchaseDate > releaseDate
    }
    for transactionResult in candidateRestoredTransactions {
      await handleRestoredTransaction(transaction: transactionResult.iapTransaction)
    }
    IAPTransactionCache.shared.hasRestoredPurchases = true
  }

  func observeNewTransactions() async {
    guard isObservingStoreKit2Transactions else {
      return
    }
    var alreadyProcessing = false
    synchronized(self) {
      alreadyProcessing = isProcessingNewTransactions
      if !alreadyProcessing {
        isProcessingNewTransactions = true
      }
    }
    guard !alreadyProcessing else {
      return
    }
    defer {
      synchronized(self) {
        isProcessingNewTransactions = false
      }
    }
    let newTransactions = await Transaction.getNewCandidateTransactions().sorted { lhs, rhs in
      lhs.iapTransaction.transaction.purchaseDate < rhs.iapTransaction.transaction.purchaseDate
    }
    guard !newTransactions.isEmpty else {
      return
    }
    for transactionResult in newTransactions {
      await handleNewTransaction(transaction: transactionResult.iapTransaction)
    }
    if let latest = newTransactions.last {
      synchronized(self) {
        IAPTransactionCache.shared.newCandidatesDate = latest.iapTransaction.transaction.purchaseDate
      }
    }
  }

  private func handleRestoredTransaction(transaction: IAPTransaction) async {
    guard let dependencies = try? getDependencies() else {
      return
    }
    let logger = dependencies.iapTransactionLoggingFactory.createIAPTransactionLogging()
    await logger.logRestoredTransaction(transaction)
  }

  private func handleNewTransaction(transaction: IAPTransaction) async {
    guard let dependencies = try? getDependencies() else {
      return
    }
    let logger = dependencies.iapTransactionLoggingFactory.createIAPTransactionLogging()
    await logger.logNewTransaction(transaction)
  }

  private func startObservingStoreKit2() {
    synchronized(self) {
      guard !isObservingStoreKit2Transactions else {
        return
      }
      observationTime = IAPConstants.defaultIAPObservationTime
      if let dependencies = try? getDependencies() {
        observationTime = dependencies.appEventsConfigurationProvider.cachedAppEventsConfiguration.iapObservationTime
      }
      isObservingStoreKit2Transactions = true
      anyTransactionListenerTask = Task {
        await checkForRestoredPurchases()
        while !Task.isCancelled {
          await observeNewTransactions()
          do {
            try await Task.sleep(nanoseconds: observationTime)
          } catch {
            break
          }
        }
      }
    }
  }

  private func stopObservingStoreKit2() {
    synchronized(self) {
      guard isObservingStoreKit2Transactions else {
        return
      }
      transactionListenerTask?.cancel()
      isObservingStoreKit2Transactions = false
    }
  }
}

// MARK: - Store Kit 1

extension IAPTransactionObserver: SKPaymentTransactionObserver {
  private func startObservingStoreKit1() {
    synchronized(self) {
      guard !isObservingStoreKit1Transactions else {
        return
      }
      guard let dependencies = try? getDependencies() else {
        return
      }
      dependencies.paymentQueue.add(self)
      isObservingStoreKit1Transactions = true
    }
  }

  private func stopObservingStoreKit1() {
    synchronized(self) {
      guard isObservingStoreKit1Transactions else {
        return
      }
      guard let dependencies = try? getDependencies() else {
        return
      }
      dependencies.paymentQueue.remove(self)
      isObservingStoreKit1Transactions = false
    }
  }

  private func handleTransaction(_ transaction: SKPaymentTransaction) {
    guard let dependencies = try? getDependencies() else {
      return
    }
    let logger = dependencies.iapTransactionLoggingFactory.createIAPTransactionLogging()
    logger.logTransaction(transaction)
  }

  func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
    for transaction in transactions {
      switch transaction.transactionState {
      case .purchasing, .purchased, .failed, .restored:
        handleTransaction(transaction)
      case .deferred:
        break
      @unknown default:
        break
      }
    }
  }
}

// MARK: - Testing

#if DEBUG
extension IAPTransactionObserver {
  func reset() {
    stopObserving()
    isObservingStoreKit2Transactions = false
    isProcessingNewTransactions = false
    anyTransactionListenerTask = nil
    observationTime = IAPConstants.defaultIAPObservationTime
    releaseDate = Self.getReleaseDate()
  }

  func setReleaseDate(_ date: Date) {
    releaseDate = date
  }

  var transactionListenerTaskForTesting: Task<Void, Never>? {
    anyTransactionListenerTask as? Task<Void, Never>
  }

  var configuredObservationTime: UInt64 {
    observationTime
  }
}
#endif
