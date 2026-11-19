/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSDKCoreKit

import XCTest

final class AsyncSequenceTests: XCTestCase {

  // Test the generic collector with finite sequences; StoreKit purchase/history
  // behavior is covered by TransactionTests and must not gate this unit test.
  func testGetValues() async {
    let expected = [3, 1, 3, -2]
    let sequence = AsyncStream<Int> { continuation in
      for value in expected {
        continuation.yield(value)
      }
      continuation.finish()
    }

    let values = await sequence.getValues()

    XCTAssertEqual(values, expected)
  }

  func testGetValuesFromEmptySequence() async {
    let sequence = AsyncStream<Int> { continuation in
      continuation.finish()
    }

    let values = await sequence.getValues()

    XCTAssertTrue(values.isEmpty)
  }

  func testGetValuesPropagatesSequenceError() async {
    enum TestError: Error {
      case sequenceFailed
    }
    let sequence = AsyncThrowingStream<Int, Error> { continuation in
      continuation.finish(throwing: TestError.sequenceFailed)
    }

    do {
      _ = try await sequence.getValues()
      XCTFail("Expected the sequence error to propagate")
    } catch TestError.sequenceFailed {
      // The original sequence error is preserved.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}
