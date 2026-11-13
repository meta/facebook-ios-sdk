/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSDKCoreKit

import Foundation
import TestTools

final class BridgeAPIProtocolNativeV1Tests: XCTestCase {
  let actionID = UUID().uuidString
  let scheme = "com.testscheme"
  let methodName = UUID().uuidString
  let methodVersion = UUID().uuidString
  let sampleURL = URL(string: "https://example.com")!
  // swiftlint:disable implicitly_unwrapped_optional
  var pasteboard: TestPasteboard!
  var errorFactory: TestErrorFactory!
  var protocolNativeV1: _BridgeAPIProtocolNativeV1!
  var bundle: TestBundle!
  var notificationCenter: TestNotificationCenter!
  var internalUtility: InternalUtilityProtocol!

  // swiftlint:enable implicitly_unwrapped_optional

  override func setUp() {
    super.setUp()
    pasteboard = TestPasteboard()
    errorFactory = TestErrorFactory()
    bundle = TestBundle()
    internalUtility = InternalUtility.shared
    notificationCenter = TestNotificationCenter()

    _BridgeAPIProtocolNativeV1.setDependencies(
      .init(
        errorFactory: errorFactory,
        bundle: bundle,
        notificationDeliverer: notificationCenter,
        internalUtility: internalUtility
      )
    )
    protocolNativeV1 = _BridgeAPIProtocolNativeV1(appScheme: scheme)
  }

  override func tearDown() {
    notificationCenter.capturedCompletions = []
    errorFactory = nil
    bundle = nil
    notificationCenter = nil
    internalUtility = nil
    pasteboard = nil
    protocolNativeV1 = nil
    _BridgeAPIProtocolNativeV1.resetDependencies()

    super.tearDown()
  }

  func testDefaultTypeDependencies() throws {
    _BridgeAPIProtocolNativeV1.resetDependencies()
    let dependencies = try _BridgeAPIProtocolNativeV1.getDependencies()

    XCTAssertTrue(
      dependencies.errorFactory is _ErrorFactory,
      .defaultDependency("an error factoring", for: "error creating")
    )

    XCTAssertIdentical(
      dependencies.bundle as AnyObject,
      Bundle.main,
      .defaultDependency("a dictionary provider", for: "providing dictionaries")
    )

    XCTAssertIdentical(
      dependencies.notificationDeliverer as AnyObject,
      NotificationCenter.default,
      .defaultDependency("a notification deliverer", for: "delivering notifications")
    )

    XCTAssertIdentical(
      dependencies.internalUtility as AnyObject,
      InternalUtility.shared,
      .defaultDependency("internal utility", for: "creating urls")
    )
  }

  func testCustomTypeDependencies() throws {
    let dependencies = try _BridgeAPIProtocolNativeV1.getDependencies()

    XCTAssertIdentical(
      dependencies.errorFactory as AnyObject,
      errorFactory,
      .customDependency(for: "error creating")
    )

    XCTAssertIdentical(
      dependencies.bundle as AnyObject,
      bundle,
      .customDependency(for: "providing dictionaries")
    )

    XCTAssertIdentical(
      dependencies.notificationDeliverer as AnyObject,
      notificationCenter,
      .customDependency(for: "delivering notifications")
    )

    XCTAssertIdentical(
      dependencies.internalUtility as AnyObject,
      internalUtility,
      .customDependency(for: "creating urls")
    )
  }

  func testRequestURL() {
    let parameters = [
      "api_key_1": "value1",
      "api_key_2": "value2",
    ]

    do {
      let requestURL = try protocolNativeV1.requestURL(
        actionID: actionID,
        scheme: scheme,
        methodName: methodName,
        parameters: parameters
      )

      let expectedPrefix = "\(scheme)://dialog/\(methodName)?"
      XCTAssertTrue(requestURL.absoluteString.hasPrefix(expectedPrefix))

      /* Due to the non-deterministic order of Dictionary->JSON serialization,
       we cannot do string comparisons to verify. */
      let queryParameters = Utility.dictionary(withQuery: requestURL.query ?? "")
      let expectedKeys = Set(["bridge_args", "method_args"])
      XCTAssertEqual(Set(queryParameters.keys), expectedKeys)
      do {
        let basicParameters = try BasicUtility.object(forJSONString: queryParameters["method_args", default: ""])
        XCTAssertEqual(basicParameters as? [String: String], parameters)
      } catch {
        XCTFail("Unexpected error thrown: \(error)")
      }
    } catch {
      XCTFail("Unexpected error thrown: \(error)")
    }
  }

  func testNilResponseParameters() {
    var cancelled: ObjCBool = true

    do {
      let response = try protocolNativeV1.responseParameters(
        actionID: actionID,
        queryParameters: [:],
        cancelled: &cancelled
      )
      XCTAssertNil(response)
    } catch {
      XCTAssertNotNil(error)
    }
    XCTAssertFalse(cancelled.boolValue)

    do {
      let response = try protocolNativeV1.responseParameters(
        actionID: actionID,
        queryParameters: [:],
        cancelled: &cancelled
      )
      XCTAssertNil(response)
    } catch {
      XCTAssertNotNil(error)
    }
    XCTAssertFalse(cancelled.boolValue)
  }

  func testEmptyResponseParameters() {
    var cancelled: ObjCBool = true
    var queryParameters: [String: Any] = [
      "bridge_args": [
        "action_id": actionID,
      ],
      "method_results": [:],
    ]
    queryParameters = stubEncodeQueryParameters(queryParameters)

    do {
      let response = try protocolNativeV1.responseParameters(
        actionID: actionID,
        queryParameters: [:],
        cancelled: &cancelled
      )

      XCTAssertEqual(response as? [String: String], [:])
    } catch {
      XCTAssertNotNil(error)
    }
    XCTAssertFalse(cancelled.boolValue)
  }

  func testResponseParameters() {
    var cancelled: ObjCBool = true
    let responseParameters: [String: Any] = [
      "result_key_1": 1,
      "result_key_2": "two",
      "result_key_3": [
        "result_key_4": 4,
        "result_key_5": "five",
      ],
    ]
    var queryParameters: [String: Any] = [
      "bridge_args": [
        "action_id": actionID,
      ],
      "method_results": responseParameters,
    ]
    queryParameters = stubEncodeQueryParameters(queryParameters)

    do {
      let response: [String: Any] = try protocolNativeV1.responseParameters(
        actionID: actionID,
        queryParameters: queryParameters,
        cancelled: &cancelled
      )
      XCTAssertEqual(response as NSObject, responseParameters as NSObject)
    } catch {
      XCTFail("Unexpected error thrown: \(error)")
    }
  }

  func testInvalidActionID() {
    var cancelled: ObjCBool = true
    let responseParameters: [String: Any] = [
      "result_key_1": 1,
      "result_key_2": "two",
      "result_key_3": [
        "result_key_4": 4,
        "result_key_5": "five",
      ],
    ]
    var queryParameters: [String: Any] = [
      "bridge_args": [
        "action_id": UUID().uuidString,
      ],
      "method_results": responseParameters,
    ]
    queryParameters = stubEncodeQueryParameters(queryParameters)
    do {
      let response = try protocolNativeV1.responseParameters(
        actionID: actionID,
        queryParameters: [:],
        cancelled: &cancelled
      )
      XCTAssertNil(response)
    } catch {
      XCTAssertNotNil(error)
    }
    XCTAssertFalse(cancelled.boolValue)
  }

  func testInvalidBridgeArgs() throws {
    var cancelled: ObjCBool = true

    let bridgeArgs = "this is an invalid bridge_args value"
    var queryParameters: [String: Any] = [
      "bridge_args": bridgeArgs,
      "method_results": [
        "result_key_1": 1,
        "result_key_2": "two",
      ],
    ]
    queryParameters = stubEncodeQueryParameters(queryParameters)
    do {
      let response = try protocolNativeV1.responseParameters(
        actionID: actionID,
        queryParameters: queryParameters,
        cancelled: &cancelled
      )
      XCTAssertNil(response)
    } catch {
      let error = try XCTUnwrap(error as? TestSDKError)
      XCTAssertEqual(error.type, .invalidArgument)
      XCTAssertEqual(error.code, TestSDKError.testErrorCode)
      XCTAssertEqual(error.domain, TestSDKError.testErrorDomain)
      XCTAssertEqual(error.name, "bridge_args")
      XCTAssertEqual(error.value as? String, bridgeArgs)
      XCTAssertNotNil(error.message)
      XCTAssertNotNil(error.underlyingError)
    }
    XCTAssertFalse(cancelled.boolValue)
  }

  func testInvalidMethodResults() throws {
    var cancelled: ObjCBool = true

    let methodResults = "this is an invalid method_results value"
    var queryParameters: [String: Any] = [
      "bridge_args": [
        "action_id": actionID,
      ],
      "method_results": methodResults,
    ]
    queryParameters = stubEncodeQueryParameters(queryParameters)
    do {
      let response = try protocolNativeV1.responseParameters(
        actionID: actionID,
        queryParameters: queryParameters,
        cancelled: &cancelled
      )
      XCTAssertNil(response)
    } catch {
      let error = try XCTUnwrap(error as? TestSDKError)
      XCTAssertEqual(error.type, .invalidArgument)
      XCTAssertEqual(error.code, TestSDKError.testErrorCode)
      XCTAssertEqual(error.domain, TestSDKError.testErrorDomain)
      XCTAssertEqual(error.name, "method_results")
      XCTAssertEqual(error.value as? String, methodResults)
      XCTAssertNotNil(error.message)
      XCTAssertNotNil(error.underlyingError)
    }
    XCTAssertFalse(cancelled.boolValue)
  }

  func testResultError() throws {
    var cancelled: ObjCBool = true

    let code = 42
    let domain = "my custom error domain"
    let userInfo: [String: Any] = [
      "key_1": 1,
      "key_2": "two",
    ]
    var queryParameters: [String: Any] = [
      "bridge_args": [
        "action_id": actionID,
        "error": [
          "code": code,
          "domain": domain,
          "user_info": userInfo,
        ],
      ],
      "method_results": [
        "result_key_1": 1,
        "result_key_2": "two",
      ],
    ]
    queryParameters = stubEncodeQueryParameters(queryParameters)
    do {
      let response = try protocolNativeV1.responseParameters(
        actionID: actionID,
        queryParameters: queryParameters,
        cancelled: &cancelled
      )
      XCTAssertNil(response)
    } catch {
      let error = try XCTUnwrap(error as? TestSDKError)
      XCTAssertEqual(error.code, code)
      XCTAssertEqual(error.domain, domain)
      XCTAssertEqual(error.userInfo["key_1"] as? Int, 1)
      XCTAssertEqual(error.userInfo["key_2"] as? String, "two")
    }
    XCTAssertFalse(cancelled.boolValue)
  }

  func testResultCancel() {
    var cancelled: ObjCBool = false

    var queryParameters: [String: Any] = [
      "bridge_args": [
        "action_id": actionID,
      ],
      "method_results": [
        "completionGesture": "cancel",
      ],
    ]
    queryParameters = stubEncodeQueryParameters(queryParameters)
    do {
      let response = try protocolNativeV1.responseParameters(
        actionID: actionID,
        queryParameters: queryParameters,
        cancelled: &cancelled
      )
      XCTAssertNotNil(response)
    } catch {
      XCTFail("Unexpected error thrown: \(error)")
    }
    XCTAssertTrue(cancelled.boolValue)
  }

  func testRequestParametersWithDataJSON() {
    let protocolNative = _BridgeAPIProtocolNativeV1(
      appScheme: scheme,
      pasteboard: nil,
      dataLengthThreshold: UInt.max,
      shouldIncludeAppIcon: false
    )

    let parameters: [String: Any] = [
      "api_key_1": "value1",
      "api_key_2": "value2",
      "data": stubData(),
    ]

    do {
      let requestURL = try protocolNative.requestURL(
        actionID: actionID,
        scheme: scheme,
        methodName: methodName,
        parameters: parameters
      )

      let expectedPrefix = "\(scheme)://dialog/\(methodName)?"
      XCTAssertTrue(requestURL.absoluteString.hasPrefix(expectedPrefix))
      /* Due to the non-deterministic order of Dictionary->JSON serialization,
       we cannot do string comparisons to verify. */
      let queryParameters = Utility.dictionary(withQuery: requestURL.query ?? "")
      let expectedKeys = Set(["bridge_args", "method_args"])
      XCTAssertEqual(Set(queryParameters.keys), expectedKeys)
      var expectedMethodArgs = parameters
      expectedMethodArgs["data"] = stubDataSerialized(parameters["data"] as? Data)

      do {
        let methodArgs = try BasicUtility.object(forJSONString: queryParameters["method_args"] ?? "") as? [String: Any]
        XCTAssertEqual(methodArgs as NSObject?, expectedMethodArgs as NSObject)
        if let parseMethodData = methodArgs?["data"] as? [String: Any],
           let decodedData = parseMethodData["fbAppBridgeType_jsonReadyValue"] {
          let baseDecodedData = Base64.decode(asData: decodedData as? String)
          XCTAssertNotNil(baseDecodedData)
          XCTAssertEqual(baseDecodedData, parameters["data"] as? Data)
        } else {
          XCTFail("Failed to parse method arguments")
        }
      } catch {
        XCTFail("Unexpected error thrown: \(error)")
      }
    } catch {
      XCTFail("Unexpected error thrown: \(error)")
    }
  }

  func testRequestParametersWithImageJSON() {
    let protocolNative = _BridgeAPIProtocolNativeV1(
      appScheme: scheme,
      pasteboard: nil,
      dataLengthThreshold: UInt.max,
      shouldIncludeAppIcon: false
    )

    let parameters: [String: Any] = [
      "api_key_1": "value1",
      "api_key_2": "value2",
      "image": stubImage(),
    ]

    do {
      let requestURL = try protocolNative.requestURL(
        actionID: actionID,
        scheme: scheme,
        methodName: methodName,
        parameters: parameters
      )

      let expectedPrefix = "\(scheme)://dialog/\(methodName)?"
      XCTAssertTrue(requestURL.absoluteString.hasPrefix(expectedPrefix))
      /* Due to the non-deterministic order of Dictionary->JSON serialization,
       we cannot do string comparisons to verify. */
      let queryParameters = Utility.dictionary(withQuery: requestURL.query ?? "")
      let expectedKeys = Set(["bridge_args", "method_args"])
      XCTAssertEqual(Set(queryParameters.keys), expectedKeys)
      var expectedMethodArgs = parameters
      expectedMethodArgs["image"] = stubImageSerialized(parameters["image"] as? UIImage)
      do {
        let methodArgs = try BasicUtility.object(
          forJSONString: queryParameters["method_args"] ?? "") as? [String: Any]
        XCTAssertEqual(methodArgs as NSObject?, expectedMethodArgs as NSObject)
        if let parseMethodData = methodArgs?["image"] as? [String: Any],
           let decodedData = parseMethodData["fbAppBridgeType_jsonReadyValue"] {
          guard let baseDecodedData = Base64.decode(asData: decodedData as? String) else {
            return XCTAssertNil("Failed to decode data from Base64")
          }
          XCTAssertNotNil(UIImage(data: baseDecodedData))
        } else {
          XCTFail("Failed to parse method arguments")
        }
      } catch {
        XCTFail("Unexpected error thrown: \(error)")
      }
    } catch {
      XCTFail("Unexpected error thrown: \(error)")
    }
  }

  func testRequestParametersWithDataPasteboard() {
    let pasteboardName = UUID().uuidString
    pasteboard.name = pasteboardName
    let data = stubData()

    let protocolNative = _BridgeAPIProtocolNativeV1(
      appScheme: scheme,
      pasteboard: pasteboard,
      dataLengthThreshold: 0,
      shouldIncludeAppIcon: false
    )

    let parameters: [String: Any] = [
      "api_key_1": "value1",
      "api_key_2": "value2",
      "data": data,
    ]

    do {
      let requestURL = try protocolNative.requestURL(
        actionID: actionID,
        scheme: scheme,
        methodName: methodName,
        parameters: parameters
      )

      XCTAssertEqual(pasteboard.capturedData, data as Data?)
      XCTAssertEqual(pasteboard.capturedPasteboardType, "com.facebook.Facebook.FBAppBridgeType")

      let expectedPrefix = "\(scheme)://dialog/\(methodName)?"
      XCTAssertTrue(requestURL.absoluteString.hasPrefix(expectedPrefix))
      /* Due to the non-deterministic order of Dictionary->JSON serialization,
       we cannot do string comparisons to verify. */
      let queryParameters = Utility.dictionary(withQuery: requestURL.query ?? "")
      let expectedKeys = Set(["bridge_args", "method_args"])
      XCTAssertEqual(Set(queryParameters.keys), expectedKeys)
      var expectedMethodArgs = parameters
      expectedMethodArgs["data"] = stubDataContainer(withPasteboardName: pasteboardName, tag: "data")
      do {
        let methodArgs = try BasicUtility.object(
          forJSONString: queryParameters["method_args"] ?? "") as? [String: Any]
        XCTAssertEqual(methodArgs as NSObject?, expectedMethodArgs as NSObject)
      } catch {
        XCTFail("Unexpected error thrown: \(error)")
      }
    } catch {
      XCTFail("Unexpected error thrown: \(error)")
    }
  }

  func testRequestParametersWithImagePasteboard() {
    let pasteboardName = UUID().uuidString
    pasteboard.name = pasteboardName
    let image = stubImage()
    let data = stubData(with: image)

    let protocolNative = _BridgeAPIProtocolNativeV1(
      appScheme: scheme,
      pasteboard: pasteboard,
      dataLengthThreshold: 0,
      shouldIncludeAppIcon: false
    )

    let parameters: [String: Any] = [
      "api_key_1": "value1",
      "api_key_2": "value2",
      "image": image,
    ]

    do {
      let requestURL = try protocolNative.requestURL(
        actionID: actionID,
        scheme: scheme,
        methodName: methodName,
        parameters: parameters
      )

      XCTAssertEqual(pasteboard.capturedData, data as Data?)
      XCTAssertEqual(pasteboard.capturedPasteboardType, "com.facebook.Facebook.FBAppBridgeType")

      let expectedPrefix = "\(scheme)://dialog/\(methodName)?"
      XCTAssertTrue(requestURL.absoluteString.hasPrefix(expectedPrefix))
      /* Due to the non-deterministic order of Dictionary->JSON serialization,
       we cannot do string comparisons to verify. */
      let queryParameters = Utility.dictionary(withQuery: requestURL.query ?? "")
      let expectedKeys = Set(["bridge_args", "method_args"])
      XCTAssertEqual(Set(queryParameters.keys), expectedKeys)
      var expectedMethodArgs = parameters
      expectedMethodArgs["image"] = stubDataContainer(withPasteboardName: pasteboardName, tag: "png")
      do {
        let methodArgs = try BasicUtility.object(
          forJSONString: queryParameters["method_args"] ?? "") as? [String: Any]
        XCTAssertEqual(methodArgs as NSObject?, expectedMethodArgs as NSObject)
      } catch {
        XCTFail("Unexpected error thrown: \(error)")
      }
    } catch {
      XCTFail("Unexpected error thrown: \(error)")
    }
  }

  func testReplacingPasteboardPayloadRemovesPreviousObserver() throws {
    let protocolNative = makeGeneralPasteboardProtocol()
    try requestPasteboardData(Data([1]), using: protocolNative)
    try requestPasteboardData(Data([2]), using: protocolNative)

    XCTAssertEqual(notificationCenter.capturedCompletions.count, 2)
    XCTAssertEqual(notificationCenter.capturedRemovedObservers.count, 1)
  }

  func testPasteboardCleanupIsOneShot() throws {
    let protocolNative = makeGeneralPasteboardProtocol()
    let data = Data([1])
    pasteboard.stubbedData = data
    try requestPasteboardData(data, using: protocolNative)
    let callback = try XCTUnwrap(notificationCenter.capturedCompletions.first)

    callback(Notification(name: .FBSDKApplicationDidBecomeActive))
    XCTAssertEqual(pasteboard.capturedData, Data())
    XCTAssertEqual(notificationCenter.capturedRemovedObservers.count, 1)

    pasteboard.capturedData = nil
    callback(Notification(name: .FBSDKApplicationDidBecomeActive))
    XCTAssertNil(pasteboard.capturedData, "A completed observation must not clear later clipboard contents")
    XCTAssertEqual(notificationCenter.capturedRemovedObservers.count, 1)
  }

  func testChangedPasteboardEndsObservationWithoutClearing() throws {
    let protocolNative = makeGeneralPasteboardProtocol()
    try requestPasteboardData(Data([1]), using: protocolNative)
    pasteboard.stubbedData = Data([2])
    pasteboard.capturedData = nil
    let callback = try XCTUnwrap(notificationCenter.capturedCompletions.first)

    callback(Notification(name: .FBSDKApplicationDidBecomeActive))
    XCTAssertNil(pasteboard.capturedData)
    XCTAssertEqual(notificationCenter.capturedRemovedObservers.count, 1)

    pasteboard.stubbedData = Data([1])
    callback(Notification(name: .FBSDKApplicationDidBecomeActive))
    XCTAssertNil(pasteboard.capturedData, "An old payload appearing later must not reactivate cleanup")
  }

  func testStaleCallbackDoesNotConsumeReplacementObservation() throws {
    let protocolNative = makeGeneralPasteboardProtocol()
    let data = Data([1])
    try requestPasteboardData(data, using: protocolNative)
    let staleCallback = try XCTUnwrap(notificationCenter.capturedCompletions.first)
    try requestPasteboardData(data, using: protocolNative)
    let currentCallback = try XCTUnwrap(notificationCenter.capturedCompletions.last)
    pasteboard.stubbedData = data
    pasteboard.capturedData = nil

    staleCallback(Notification(name: .FBSDKApplicationDidBecomeActive))
    XCTAssertNil(pasteboard.capturedData)
    XCTAssertEqual(notificationCenter.capturedRemovedObservers.count, 1)

    currentCallback(Notification(name: .FBSDKApplicationDidBecomeActive))
    XCTAssertEqual(pasteboard.capturedData, Data())
    XCTAssertEqual(notificationCenter.capturedRemovedObservers.count, 2)
  }

  func testPasteboardObservationDoesNotRetainProtocol() throws {
    weak var weakProtocol: _BridgeAPIProtocolNativeV1?
    try autoreleasepool {
      let protocolNative = makeGeneralPasteboardProtocol()
      weakProtocol = protocolNative
      try requestPasteboardData(Data([1]), using: protocolNative)
    }

    XCTAssertNil(weakProtocol)
    XCTAssertEqual(notificationCenter.capturedRemovedObservers.count, 1)
  }

  func testCleanupUnregistersFromTheOriginalNotificationCenter() throws {
    let protocolNative = makeGeneralPasteboardProtocol()
    try requestPasteboardData(Data([1]), using: protocolNative)
    let callback = try XCTUnwrap(notificationCenter.capturedCompletions.first)
    let replacementCenter = TestNotificationCenter()
    _BridgeAPIProtocolNativeV1.setDependencies(
      .init(
        errorFactory: errorFactory,
        bundle: bundle,
        notificationDeliverer: replacementCenter,
        internalUtility: internalUtility
      )
    )

    callback(Notification(name: .FBSDKApplicationDidBecomeActive))

    XCTAssertEqual(notificationCenter.capturedRemovedObservers.count, 1)
    XCTAssertTrue(replacementCenter.capturedRemovedObservers.isEmpty)
  }

  func testCustomPasteboardDoesNotRegisterCleanup() throws {
    let protocolNative = makeGeneralPasteboardProtocol()
    pasteboard._isGeneralPasteboard = false
    try requestPasteboardData(Data([1]), using: protocolNative)

    XCTAssertTrue(notificationCenter.capturedCompletions.isEmpty)
    XCTAssertEqual(pasteboard.capturedData, Data([1]))
  }

  // MARK: - Helpers

  private func makeGeneralPasteboardProtocol() -> _BridgeAPIProtocolNativeV1 {
    pasteboard._isGeneralPasteboard = true
    return _BridgeAPIProtocolNativeV1(
      appScheme: scheme,
      pasteboard: pasteboard,
      dataLengthThreshold: 0,
      shouldIncludeAppIcon: false
    )
  }

  private func requestPasteboardData(_ data: Data, using protocolNative: _BridgeAPIProtocolNativeV1) throws {
    _ = try protocolNative.requestURL(
      actionID: actionID,
      scheme: scheme,
      methodName: methodName,
      parameters: ["data": data]
    )
  }

  func stubEncodeQueryParameters(_ queryParameters: [String: Any]) -> [String: Any] {
    let encoded = [:] as NSMutableDictionary
    for (key, value) in queryParameters {
      do {
        try BasicUtility.dictionary(
          encoded,
          setJSONStringFor: value,
          forKey: key as NSCopying
        )
      } catch {
        TypeUtility.dictionary(
          encoded,
          setObject: value,
          forKey: key as NSCopying
        )
      }
    }
    return encoded as? [String: Any] ?? [:]
  }

  func stubData() -> NSMutableData {
    if let data = NSMutableData(length: 1024) {
      arc4random_buf(data.mutableBytes, data.count)
      return data
    }
    return NSMutableData()
  }

  func stubDataContainer(withPasteboardName pasteboardName: String?, tag: String?) -> [String: Any]? {
    [
      "isPasteboard": NSNumber(value: true),
      "tag": tag ?? "",
      "fbAppBridgeType_jsonReadyValue": pasteboardName ?? "",
    ]
  }

  func stubDataSerialized(_ data: Data?) -> [String: Any]? {
    stubDataSerialized(data, tag: "data")
  }

  func stubDataSerialized(_ data: Data?, tag: String?) -> [String: Any]? {
    guard let string = data?.base64EncodedString() else { return nil }

    return [
      "isBase64": NSNumber(value: true),
      "tag": tag ?? "",
      "fbAppBridgeType_jsonReadyValue": string,
    ]
  }

  func stubData(with image: UIImage?) -> Data? {
    image?.jpegData(compressionQuality: Settings.shared.jpegCompressionQuality)
  }

  func stubImage() -> UIImage {
    UIGraphicsBeginImageContext(CGSize(width: 10.0, height: 10.0))
    let context = UIGraphicsGetCurrentContext()
    UIColor.red.setFill()
    context?.fill(CGRect(x: 0.0, y: 0.0, width: 5.0, height: 5.0))
    UIColor.green.setFill()
    context?.fill(CGRect(x: 5.0, y: 0.0, width: 5.0, height: 5.0))
    UIColor.blue.setFill()
    context?.fill(CGRect(x: 5.0, y: 5.0, width: 5.0, height: 5.0))
    UIColor.yellow.setFill()
    context?.fill(CGRect(x: 0.0, y: 5.0, width: 5.0, height: 5.0))
    let imageRef = context?.makeImage()
    UIGraphicsEndImageContext()
    var image = UIImage()
    if let imageRef: CGImage = imageRef {
      image = UIImage(cgImage: imageRef)
    }
    return image
  }

  func stubImageSerialized(_ image: UIImage?) -> [String: Any]? {
    let data = stubData(with: image)
    return stubDataSerialized(data, tag: "png")
  }
}

// MARK: - Assumptions

// swiftformat:disable extensionaccesscontrol
fileprivate extension String {
  static func defaultDependency(_ dependency: String, for type: String) -> String {
    "The _BridgeAPIProtocolNativeV1 type uses \(dependency) as its \(type) dependency by default"
  }

  static func customDependency(for type: String) -> String {
    "The _BridgeAPIProtocolNativeV1 type uses a custom \(type) dependency when provided"
  }
}
