/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSDKCoreKit

import XCTest

final class TimeSpentDataTests: XCTestCase {

  let applicationName = "someApplication"
  let eventLogger = TestEventLogger()
  lazy var timeSpentData = _TimeSpentData(
    eventLogger: eventLogger,
    serverConfigurationProvider: TestServerConfigurationProvider()
  )

  func testCreatingWithDependencies() {
    XCTAssertEqual(
      timeSpentData.eventLogger as? TestEventLogger,
      eventLogger,
      "Should store the provided event logger"
    )
  }

  func testSetSourceApplication() {
    timeSpentData.setSourceApplication(applicationName, isFromAppLink: true)
    XCTAssertEqual(timeSpentData.getSourceApplication(), "AppLink(someApplication)")

    timeSpentData.resetSourceApplication()
    XCTAssertEqual(timeSpentData.getSourceApplication(), "Unclassified")
  }

  func testAppEventsParametersForDeactivate() {
    timeSpentData.setSourceApplication(applicationName, isFromAppLink: true)
    let params = timeSpentData.appEventsParametersForDeactivate()
    XCTAssertNotNil(params["_session_id"])
    XCTAssertNotNil(params["fb_mobile_app_interruptions"])
    XCTAssertNotNil(params["fb_mobile_launch_source"])
    XCTAssertNotNil(params["fb_mobile_time_between_sessions"])
  }

  func testRepeatedSuspendDoesNotCountTheSameForegroundTimeTwice() {
    let now = Date().timeIntervalSince1970.rounded()
    configureLoadedSession(lastRestoreTime: now - 10)

    timeSpentData.suspendTimeSpentData()
    timeSpentData.suspendTimeSpentData()

    XCTAssertEqual(timeSpentData.secondsSpentInCurrentSession, 15, accuracy: 1)
    XCTAssertFalse(timeSpentData.isCurrentlyLoaded)
  }

  func testResumeBeforePersistenceCompletesRestoresLatestSession() {
    let now = Date().timeIntervalSince1970.rounded()
    configureLoadedSession(lastRestoreTime: now - 10)

    timeSpentData.suspendTimeSpentData()
    timeSpentData.restoreTimeSpentData(calledFromActivateApp: false)

    XCTAssertTrue(timeSpentData.isCurrentlyLoaded)
    XCTAssertEqual(timeSpentData.sessionID, "current-session")
    XCTAssertEqual(timeSpentData.secondsSpentInCurrentSession, 15, accuracy: 1)
    XCTAssertEqual(timeSpentData.numInterruptionsInCurrentSession, 3)
    XCTAssertEqual(timeSpentData.lastRestoreTime, now, accuracy: 1)
    XCTAssertEqual(timeSpentData.lastSuspendTime, now, accuracy: 1)
  }

  func testConsecutiveResumesUseTheLatestSessionSnapshot() {
    let now = Date().timeIntervalSince1970.rounded()
    configureLoadedSession(lastRestoreTime: now - 10)
    timeSpentData.suspendTimeSpentData()
    timeSpentData.restoreTimeSpentData(calledFromActivateApp: false)
    let secondsAfterFirstResume = timeSpentData.secondsSpentInCurrentSession
    timeSpentData.lastRestoreTime = Date().timeIntervalSince1970.rounded() - 4

    timeSpentData.suspendTimeSpentData()
    timeSpentData.restoreTimeSpentData(calledFromActivateApp: false)

    XCTAssertTrue(timeSpentData.isCurrentlyLoaded)
    XCTAssertEqual(timeSpentData.sessionID, "current-session")
    XCTAssertEqual(timeSpentData.secondsSpentInCurrentSession, secondsAfterFirstResume + 4, accuracy: 1)
    XCTAssertEqual(timeSpentData.numInterruptionsInCurrentSession, 4)
  }

  private func configureLoadedSession(lastRestoreTime: TimeInterval) {
    XCTAssertTrue(Thread.isMainThread)
    timeSpentData.isCurrentlyLoaded = true
    timeSpentData.lastRestoreTime = lastRestoreTime
    timeSpentData.secondsSpentInCurrentSession = 5
    timeSpentData.numInterruptionsInCurrentSession = 2
    timeSpentData.sessionID = "current-session"
  }
}
