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

final class GraphErrorRecoveryProcessorTests: XCTestCase {

  private enum Keys {
    static let errorKey = "com.facebook.sdk:FBSDKGraphRequestErrorKey"
  }

  private enum SampleErrors {

    static let recoverableCode = Int(GraphRequestError.recoverable.rawValue)
    static let transientCode = Int(GraphRequestError.transient.rawValue)
    static let transient = NSError(
      domain: "test",
      code: transientCode,
      userInfo: [Keys.errorKey: transientCode]
    )

    static func createRecoverable(attempter: ErrorRecoveryAttempting) -> NSError {
      NSError(
        domain: "test",
        code: recoverableCode,
        userInfo: [
          Keys.errorKey: recoverableCode,
          NSRecoveryAttempterErrorKey: attempter,
        ]
      )
    }
  }

  let processor = GraphErrorRecoveryProcessor(accessTokenString: "Foo")
  private let delegate = TestGraphErrorRecoveryProcessorDelegate()
  private let attempter = TestErrorRecoveryAttempter()

  func testProcessingRandomErrorCategories() {
    (1 ..< 100).forEach { _ in
      let error = NSError(domain: "test", code: 0, userInfo: [Keys.errorKey: Fuzzer.random])
      processor.processError(error, request: TestGraphRequest(), delegate: delegate)
    }
  }

  func testProcessingTransientError() {
    XCTAssertTrue(
      processor.processError(SampleErrors.transient, request: TestGraphRequest(), delegate: delegate),
      "Should successfully process a transient graph request error"
    )
    XCTAssertEqual(
      delegate.capturedProcessor,
      processor,
      "Should invoke the delegate with the expected recovery processor"
    )
    XCTAssertTrue(
      delegate.capturedDidRecover,
      "Should inform the delegate about the successful recovery"
    )
    XCTAssertNil(
      delegate.capturedError
    )
  }

  func testProcessingRecoverableErrorWithIdenticalAccessTokenString() throws {
    let processor = GraphErrorRecoveryProcessor(accessTokenString: name)
    let error = SampleErrors.createRecoverable(attempter: attempter)

    XCTAssertTrue(
      processor.processError(
        error,
        request: createGraphRequest(tokenString: name),
        delegate: delegate
      ),
      "Should successfully process a recoverable graph request error"
    )

    let completion = try XCTUnwrap(attempter.capturedCompletion)
    let wasRecoverySuccessful = Bool.random()
    completion(wasRecoverySuccessful)

    XCTAssertEqual(
      delegate.capturedProcessor,
      processor,
      "Should invoke the delegate with the expected recovery processor"
    )
    XCTAssertEqual(
      delegate.capturedDidRecover,
      wasRecoverySuccessful,
      "Should inform the delegate about the status of the recovery"
    )
    XCTAssertIdentical(
      delegate.capturedError,
      error,
      "Should invoke the delegate with the expected error"
    )
  }

  func testProcessingRecoverableErrorWithDifferentAccessTokenStrings() throws {
    XCTAssertFalse(
      processor.processError(
        SampleErrors.createRecoverable(attempter: attempter),
        request: createGraphRequest(tokenString: name),
        delegate: delegate
      ),
      "Should not attempt to recover a graph request error if the access token strings do not match"
    )
    XCTAssertFalse(
      delegate.wasRecoveryAttempted,
      "Should not invoke the delegate when recovery is not attempted"
    )
  }

  func testProcessingRecoverableErrorWithoutRecoveryAttempter() {
    let error = NSError(
      domain: "test",
      code: SampleErrors.recoverableCode,
      userInfo: [Keys.errorKey: SampleErrors.recoverableCode]
    )

    XCTAssertFalse(
      processor.processError(error, request: createGraphRequest(tokenString: "Foo"), delegate: delegate),
      "Should leave errors without a recovery attempter for the caller to handle"
    )
    XCTAssertFalse(delegate.wasRecoveryAttempted)
  }

  // MARK: - Helpers

  func createGraphRequest(tokenString: String) -> GraphRequestProtocol {
    TestGraphRequest(
      graphPath: "me",
      parameters: [:],
      tokenString: tokenString
    )
  }
}
