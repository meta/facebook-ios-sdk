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

final class IAPDedupeProcessorTimerTests: XCTestCase {
  private let processor = IAPDedupeProcessor.shared
  private let eventLogger = TestEventLogger()
  private let configurationProvider = TestAppEventsConfigurationProvider()

  override func setUp() {
    super.setUp()
    processor.reset()
    IAPTransactionObserver.shared.stopObserving()
    configurationProvider.stubbedConfiguration = TestAppEventsConfiguration(iapManualAndAutoLogDedupWindow: 0)
    IAPDedupeProcessor.configuredDependencies = .init(
      eventLogger: eventLogger,
      appEventsConfigurationProvider: configurationProvider,
      dataStore: UserDefaults.standard
    )
  }

  override func tearDown() {
    processor.reset()
    super.tearDown()
  }

  @MainActor
  func testEventsQueuedBeforeTimerInstallationShareOneWindow() async {
    for value in 1 ... 3 {
      enqueueEvent(value: value)
    }
    await expectOneFlush()
    XCTAssertEqual(eventLogger.capturedEvents.count, 3)
  }

  @MainActor
  func testConcurrentEventsShareOneWindow() async {
    DispatchQueue.concurrentPerform(iterations: 10) { value in
      self.enqueueEvent(value: value)
    }
    await expectOneFlush()
    XCTAssertEqual(eventLogger.capturedEvents.count, 10)
  }

  @MainActor
  func testSavingEventsCancelsPendingTimerInstallation() async {
    enqueueEvent(value: 1)
    processor.saveNonProcessedEvents()

    let unexpectedFlush = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in self.eventLogger.flushCallCount > 0 }, object: nil
    )
    unexpectedFlush.isInverted = true
    await fulfillment(of: [unexpectedFlush], timeout: 1)
    XCTAssertEqual(eventLogger.flushCallCount, 0)
    XCTAssertTrue(eventLogger.capturedEvents.isEmpty)
    XCTAssertNotNil(UserDefaults.standard.data(forKey: IAPConstants.implicitlyLoggedDedupableEventsKey))
  }

  @MainActor
  func testNewEventsStartOneWindowAfterSavingPendingEvents() async {
    enqueueEvent(value: 1)
    processor.saveNonProcessedEvents()
    enqueueEvent(value: 2)
    enqueueEvent(value: 3)

    await expectOneFlush()
    XCTAssertEqual(eventLogger.capturedEvents.count, 2)
  }

  private func enqueueEvent(value: Int) {
    processor.processImplicitEvent(
      .purchased,
      valueToSum: NSNumber(value: value),
      parameters: nil,
      accessToken: nil,
      operationalParameters: nil
    )
  }

  @MainActor
  private func expectOneFlush() async {
    let flushed = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in self.eventLogger.flushCallCount > 0 }, object: nil
    )
    await fulfillment(of: [flushed], timeout: 5)
    let duplicateFlush = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in self.eventLogger.flushCallCount > 1 }, object: nil
    )
    duplicateFlush.isInverted = true
    await fulfillment(of: [duplicateFlush], timeout: 1)
    XCTAssertEqual(eventLogger.flushCallCount, 1)
  }
}
