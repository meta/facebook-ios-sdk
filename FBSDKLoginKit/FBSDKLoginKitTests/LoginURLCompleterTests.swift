/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSDKCoreKit
@testable import FBSDKLoginKit

import FBSDKCoreKit_Basics
import TestTools
import XCTest

final class LoginURLCompleterTests: XCTestCase {

  enum Keys {
    static let accessToken = "access_token"
    static let dataAccessExpiration = "data_access_expiration_time"
    static let deniedScopes = "denied_scopes"
    static let expires = "expires"
    static let expiresAt = "expires_at"
    static let expiresIn = "expires_in"
    static let grantedScopes = "granted_scopes"
    static let graphDomain = "graph_domain"
    static let idToken = "id_token"
    static let nonce = "nonce"
    static let userID = "user_id"
    static let code = "code"
    static let error = "error"
  }

  enum Values {
    static let appID = "1234567"
    static let idToken = "abc123"
    static let nonce = "some_nonce"
    static let codeVerifier = "some_code_verifier"
    static let redirectURL = "https://www.example.com"
    static let accessToken = "some_token"
  }

  // swiftlint:disable implicitly_unwrapped_optional
  var profileFactory: ProfileFactory!
  var authenticationTokenFactory: TestAuthenticationTokenFactory!
  var graphRequestFactory: TestGraphRequestFactory!
  var internalUtility: TestInternalUtility!
  var errorFactory: _ErrorFactory!
  var urlCompleter: LoginURLCompleter!
  // swiftlint:enable implicitly_unwrapped_optional

  override func setUp() {
    super.setUp()

    profileFactory = ProfileFactory()
    authenticationTokenFactory = TestAuthenticationTokenFactory()
    graphRequestFactory = TestGraphRequestFactory()
    internalUtility = TestInternalUtility()
    errorFactory = _ErrorFactory()
    internalUtility.stubbedAppURL = URL(string: Values.redirectURL)

    LoginURLCompleter.setDependencies(
      .init(
        profileFactory: profileFactory,
        authenticationTokenCreator: authenticationTokenFactory,
        graphRequestFactory: graphRequestFactory,
        internalUtility: internalUtility,
        errorFactory: errorFactory
      )
    )

    urlCompleter = LoginURLCompleter(urlParameters: [:], appID: "")
  }

  override func tearDown() {
    LoginURLCompleter.resetDependencies()
    urlCompleter = nil
    profileFactory = nil
    authenticationTokenFactory = nil
    graphRequestFactory = nil
    errorFactory = nil
    internalUtility = nil

    super.tearDown()
  }

  func testDefaultTypeDependencies() throws {
    LoginURLCompleter.resetDependencies()

    let dependencies = try LoginURLCompleter.getDependencies()

    XCTAssertTrue(
      dependencies.profileFactory is ProfileFactory,
      .defaultDependency("ProfileFactory", for: "profile factory")
    )

    XCTAssertTrue(
      dependencies.authenticationTokenCreator is AuthenticationTokenFactory,
      .defaultDependency("_AuthenticationTokenFactory", for: "authentication token creator")
    )

    XCTAssertTrue(
      dependencies.graphRequestFactory is GraphRequestFactory,
      .defaultDependency("GraphRequestFactory", for: "graph request factory")
    )

    XCTAssertTrue(
      dependencies.internalUtility is InternalUtility,
      .defaultDependency("InternalUtility", for: "internal utility")
    )
  }

  func testCustomDependencies() throws {

    let dependencies = try LoginURLCompleter.getDependencies()

    XCTAssertIdentical(
      dependencies.profileFactory as AnyObject,
      profileFactory,
      .customDependency(for: "profile factory")
    )

    XCTAssertIdentical(
      dependencies.authenticationTokenCreator as AnyObject,
      authenticationTokenFactory,
      .customDependency(for: "authentication token creator")
    )

    XCTAssertIdentical(
      dependencies.graphRequestFactory,
      graphRequestFactory,
      .customDependency(for: "graph request factory")
    )

    XCTAssertIdentical(
      dependencies.internalUtility,
      internalUtility,
      .customDependency(for: "internal utility")
    )
  }

  // MARK: Creation

  func testInitWithAccessTokenWithIDToken() {
    let parameters = SampleRawLoginCompletionParameters.withAccessTokenWithIDToken

    urlCompleter = createLoginCompleter(parameters: parameters, appID: Values.appID)

    verifyParameters(actual: urlCompleter.parameters, expected: parameters)
  }

  func testInitWithAccessToken() {
    let parameters = SampleRawLoginCompletionParameters.withAccessToken
    urlCompleter = createLoginCompleter(parameters: parameters, appID: Values.appID)

    verifyParameters(actual: urlCompleter.parameters, expected: parameters)
  }

  func testInitWithNonce() {
    let parameters = SampleRawLoginCompletionParameters.withNonce
    urlCompleter = createLoginCompleter(parameters: parameters, appID: Values.appID)

    verifyParameters(actual: urlCompleter.parameters, expected: parameters)
  }

  func testInitWithCode() {
    let parameters = SampleRawLoginCompletionParameters.withCode
    urlCompleter = createLoginCompleter(parameters: parameters, appID: Values.appID)

    verifyParameters(actual: urlCompleter.parameters, expected: parameters)
  }

  func testInitWithIDToken() {
    let parameters = SampleRawLoginCompletionParameters.withIDToken
    urlCompleter = createLoginCompleter(parameters: parameters, appID: Values.appID)

    verifyParameters(actual: urlCompleter.parameters, expected: parameters)
  }

  func testInitWithStringExpirations() throws {
    let parameters = SampleRawLoginCompletionParameters.withStringExpirations
    let before = Date()
    urlCompleter = createLoginCompleter(parameters: parameters, appID: Values.appID)
    let after = Date()

    verifyParameters(actual: urlCompleter.parameters, expected: parameters)
    let expiration = try XCTUnwrap(urlCompleter.parameters.expirationDate)
    let interval = TimeInterval(SampleRawLoginCompletionParameters.secondsInDay * 60)
    XCTAssertGreaterThanOrEqual(expiration, before.addingTimeInterval(interval))
    XCTAssertLessThanOrEqual(expiration, after.addingTimeInterval(interval))
    XCTAssertEqual(
      urlCompleter.parameters.dataAccessExpirationDate,
      Date(timeIntervalSince1970: SampleRawLoginCompletionParameters.dataExpirationDate)
    )
  }

  func testInitWithStringAbsoluteExpirations() {
    for key in [Keys.expires, Keys.expiresAt] {
      for (value, timestamp) in [("1700000000", 1700000000.0), ("1700000000.5", 1700000000.5)] {
        let completer = createLoginCompleter(
          parameters: [Keys.accessToken: Values.accessToken, key: value],
          appID: Values.appID
        )
        XCTAssertEqual(
          completer.parameters.expirationDate,
          Date(timeIntervalSince1970: timestamp),
          "Should parse \(key)=\(value)"
        )
      }
    }
  }

  func testInitWithNumericExpirations() {
    let timestamp = 1700000000.5
    for key in [Keys.expires, Keys.expiresAt] {
      let completer = createLoginCompleter(
        parameters: [Keys.accessToken: Values.accessToken, key: timestamp],
        appID: Values.appID
      )
      XCTAssertEqual(completer.parameters.expirationDate, Date(timeIntervalSince1970: timestamp))
    }
    XCTAssertEqual(
      urlCompleter.dataAccessExpirationDateFrom(parameters: [Keys.dataAccessExpiration: timestamp]),
      Date(timeIntervalSince1970: timestamp)
    )
    let before = Date()
    let relative = urlCompleter.expirationDateFrom(parameters: [Keys.expiresIn: 60.5])
    let after = Date()
    XCTAssertGreaterThanOrEqual(relative, before.addingTimeInterval(60.5))
    XCTAssertLessThanOrEqual(relative, after.addingTimeInterval(60.5))
  }

  func testExpirationPrecedence() {
    let parameters: [String: Any] = [
      Keys.expires: "1700000000",
      Keys.expiresAt: 1800000000.0,
      Keys.expiresIn: "60",
    ]
    XCTAssertEqual(
      urlCompleter.expirationDateFrom(parameters: parameters),
      Date(timeIntervalSince1970: 1700000000)
    )
    XCTAssertEqual(
      urlCompleter.expirationDateFrom(parameters: [Keys.expiresAt: "1800000000", Keys.expiresIn: 60.0]),
      Date(timeIntervalSince1970: 1800000000)
    )
    XCTAssertEqual(
      urlCompleter.expirationDateFrom(parameters: [Keys.expires: "invalid", Keys.expiresAt: "1800000000"]),
      Date(timeIntervalSince1970: 1800000000)
    )
  }

  func testNonpositiveAbsoluteExpirationRetainsRelativeFallback() {
    // A present nonpositive expires value has always suppressed expires_at.
    let nonpositiveValues: [Any] = [0.0, "0", -1.0, "-1"]
    for value in nonpositiveValues {
      let before = Date()
      let expiration = urlCompleter.expirationDateFrom(parameters: [
        Keys.expires: value,
        Keys.expiresAt: 1800000000.0,
        Keys.expiresIn: 60.5,
      ])
      let after = Date()
      XCTAssertGreaterThanOrEqual(expiration, before.addingTimeInterval(60.5))
      XCTAssertLessThanOrEqual(expiration, after.addingTimeInterval(60.5))
    }
  }

  func testInvalidAndNonfiniteExpirations() {
    let values: [Any] = [
      "", "invalid", "0", "-1", "nan", "inf", "-inf", "1e9999",
      0.0, -1.0, Double.nan, Double.infinity, -Double.infinity, NSNull(),
    ]
    for key in [Keys.expires, Keys.expiresAt, Keys.expiresIn] {
      for value in values {
        XCTAssertEqual(
          urlCompleter.expirationDateFrom(parameters: [key: value]),
          Date.distantFuture,
          "Should ignore invalid \(key)=\(value)"
        )
      }
    }
    for value in values {
      XCTAssertEqual(
        urlCompleter.dataAccessExpirationDateFrom(parameters: [Keys.dataAccessExpiration: value]),
        Date.distantFuture,
        "Should ignore invalid data-access expiration \(value)"
      )
    }
    XCTAssertEqual(urlCompleter.expirationDateFrom(parameters: [:]), Date.distantFuture)
    XCTAssertEqual(urlCompleter.dataAccessExpirationDateFrom(parameters: [:]), Date.distantFuture)
  }

  func testInitWithoutAccessTokenWithoutIDTokenWithoutCode() {
    let parameters = SampleRawLoginCompletionParameters.withoutAccessTokenWithoutIDTokenWithoutCode
    urlCompleter = createLoginCompleter(parameters: parameters, appID: Values.appID)

    verifyEmptyParameters(urlCompleter.parameters)
  }

  func testInitWithEmptyStrings() {
    let parameters = SampleRawLoginCompletionParameters.withEmptyStrings
    urlCompleter = createLoginCompleter(parameters: parameters, appID: Values.appID)

    verifyEmptyParameters(urlCompleter.parameters)
  }

  func testInitWithEmptyParameters() {
    urlCompleter = createLoginCompleter(parameters: [:], appID: Values.appID)

    verifyEmptyParameters(urlCompleter.parameters)
  }

  func testInitWithError() {
    let parameters = SampleRawLoginCompletionParameters.withError
    urlCompleter = createLoginCompleter(
      parameters: parameters,
      appID: Values.appID
    )

    XCTAssertNotNil(urlCompleter.parameters.error)
  }

  func testInitWithFuzzyParameters() {
    (0 ..< 100).forEach { _ in
      let parameters = SampleRawLoginCompletionParameters.defaultParameters
      if let fuzzyParameters = Fuzzer.randomize(json: parameters) as? [String: Any] {
        _ = createLoginCompleter(parameters: fuzzyParameters, appID: Values.appID)
      }
    }
  }

  // MARK: Completion

  func testCompleteWithNonceGraphRequestCreation() throws {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withNonce,
      appID: Values.appID
    )
    let handler: LoginCompletionParametersBlock = { _ in }

    urlCompleter.completeLogin(handler: handler)

    XCTAssertNil(urlCompleter.parameters.error)
    XCTAssertNil(authenticationTokenFactory.capturedTokenString)
    let capturedRequest = try XCTUnwrap(graphRequestFactory.capturedRequests.first)
    XCTAssertEqual(
      capturedRequest.graphPath,
      "oauth/access_token",
      "Should create a graph request with the expected graph path"
    )
    XCTAssertEqual(
      capturedRequest.parameters["grant_type"] as? String,
      "fb_exchange_nonce",
      "Should create a graph request with the expected grant type parameter"
    )
    XCTAssertEqual(
      capturedRequest.parameters["fb_exchange_nonce"] as? String,
      urlCompleter.parameters.nonceString,
      "Should create a graph request with the expected nonce parameter"
    )
    XCTAssertEqual(
      capturedRequest.parameters["client_id"] as? String,
      Values.appID,
      "Should create a graph request with the expected app id parameter"
    )
    XCTAssertEqual(
      capturedRequest.parameters["fields"] as? String,
      "",
      "Should create a graph request with the expected fields parameter"
    )
    XCTAssertEqual(
      capturedRequest.flags,
      [.doNotInvalidateTokenOnError, .disableErrorRecovery],
      "The graph request should not invalidate the token on error or disable error recovery"
    )
  }

  func testNonceExchangeCompletionWithError() {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withNonce,
      appID: Values.appID
    )

    var completionWasInvoked = false
    var capturedParameters: _LoginCompletionParameters?
    urlCompleter.completeLogin { parameters in
      capturedParameters = parameters
      completionWasInvoked = true
    }

    graphRequestFactory.capturedRequests.first?.capturedCompletionHandler?(nil, nil, SampleError())

    XCTAssertEqual(
      urlCompleter.parameters,
      capturedParameters,
      "Should call the completion with the provided parameters"
    )
    XCTAssertTrue(
      urlCompleter.parameters.error is SampleError,
      "Should pass through the error from the graph request"
    )

    XCTAssertTrue(completionWasInvoked)
  }

  func testNonceExchangeCompletionWithAccessTokenString() {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withNonce,
      appID: Values.appID
    )
    let stubbedResult = [Keys.accessToken: name]

    var completionWasInvoked = false
    var capturedParameters: _LoginCompletionParameters?
    urlCompleter.completeLogin { parameters in
      capturedParameters = parameters
      completionWasInvoked = true
    }

    graphRequestFactory.capturedRequests.first?.capturedCompletionHandler?(nil, stubbedResult, nil)

    XCTAssertEqual(
      urlCompleter.parameters,
      capturedParameters,
      "Should call the completion with the provided parameters"
    )
    XCTAssertEqual(
      urlCompleter.parameters.accessTokenString,
      name,
      "Should set the access token string from the graph request's result"
    )
    XCTAssertTrue(completionWasInvoked)
  }

  func testNonceExchangeCompletionWithAccessTokenStringAndAuthenticationTokenString() {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withNonce,
      appID: Values.appID
    )
    let nonce = Values.nonce
    let stubbedResult = [
      Keys.accessToken: name,
      Keys.idToken: Values.idToken,
    ]

    urlCompleter.completeLogin(
      nonce: nonce,
      codeVerifier: Values.codeVerifier
    ) { _ in }

    graphRequestFactory.capturedRequests.first?.capturedCompletionHandler?(nil, stubbedResult, nil)

    XCTAssertEqual(
      urlCompleter.parameters.accessTokenString,
      name,
      "Should set the access token string from the graph request's result"
    )
    XCTAssertEqual(
      urlCompleter.parameters.authenticationTokenString,
      Values.idToken,
      "Should set the authentication token string from the graph request's result"
    )
    XCTAssertEqual(
      authenticationTokenFactory.capturedTokenString,
      Values.idToken,
      "Should call AuthenticationTokenFactory with the expected token string"
    )
    XCTAssertEqual(
      authenticationTokenFactory.capturedNonce,
      nonce,
      "Should call AuthenticationTokenFactory with the expected nonce"
    )
  }

  func testNonceExchangeWithRandomResults() {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withNonce,
      appID: Values.appID
    )

    let stubbedResult: [String: Any] = [
      Keys.accessToken: name,
      "expires_in": "10000",
      "data_access_expiration_time": 1,
    ]

    var completionWasInvoked = false
    urlCompleter.completeLogin { _ in
      // Basically just making sure that nothing crashes here when we feed it garbage results
      completionWasInvoked = true
    }

    (0 ..< 100).forEach { _ in
      let mangledResult = stubbedResult
      let parameters = Fuzzer.randomize(json: mangledResult)

      graphRequestFactory.capturedRequests.first?.capturedCompletionHandler?(nil, parameters, nil)

      XCTAssertTrue(completionWasInvoked)
      completionWasInvoked = false
    }
  }

  func testCompleteWithCodeGraphRequestCreation() throws {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withCode,
      appID: Values.appID
    )
    let handler: LoginCompletionParametersBlock = { _ in }

    urlCompleter.completeLogin(
      nonce: Values.nonce,
      codeVerifier: Values.codeVerifier,
      handler: handler
    )

    XCTAssertNil(urlCompleter.parameters.error)
    XCTAssertNil(authenticationTokenFactory.capturedTokenString)
    let capturedRequest = try XCTUnwrap(graphRequestFactory.capturedRequests.first)
    XCTAssertEqual(
      capturedRequest.graphPath,
      "oauth/access_token",
      "Should create a graph request with the expected graph path"
    )
    XCTAssertEqual(
      capturedRequest.parameters["client_id"] as? String,
      Values.appID,
      "Should create a graph request with the expected app ID"
    )
    XCTAssertEqual(
      capturedRequest.parameters["redirect_uri"] as? String,
      Values.redirectURL,
      "Should create a graph request with the expected redirect URL"
    )
    XCTAssertEqual(
      capturedRequest.parameters["code_verifier"] as? String,
      Values.codeVerifier,
      "Should create a graph request with the expected code verifier parameter"
    )
    XCTAssertEqual(
      capturedRequest.parameters[Keys.code] as? String,
      SampleRawLoginCompletionParameters.withCode[Keys.code] as? String,
      "Should create a graph request with the expected code parameter"
    )
    XCTAssertEqual(
      capturedRequest.flags,
      [.doNotInvalidateTokenOnError, .disableErrorRecovery],
      "The graph request should not invalidate the token on error or disable error recovery"
    )
  }

  func testCodeExchangeCompletionWithGraphError() {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withCode,
      appID: Values.appID
    )

    var completionWasInvoked = false
    var capturedParameters: _LoginCompletionParameters?
    let handler: LoginCompletionParametersBlock = { parameters in
      capturedParameters = parameters
      completionWasInvoked = true
    }

    urlCompleter.completeLogin(
      nonce: Values.nonce,
      codeVerifier: Values.codeVerifier,
      handler: handler
    )

    graphRequestFactory.capturedRequests.first?.capturedCompletionHandler?(nil, nil, SampleError())

    XCTAssertEqual(
      urlCompleter.parameters,
      capturedParameters,
      "Should call the completion with the provided parameters"
    )
    XCTAssertTrue(
      urlCompleter.parameters.error is SampleError,
      "Should pass through the error from the graph request"
    )

    XCTAssertTrue(completionWasInvoked)
  }

  func testCodeExchangeCompletionWithError() {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withCode,
      appID: Values.appID
    )
    let stubbedResult = [Keys.error: name]

    var completionWasInvoked = false
    var capturedParameters: _LoginCompletionParameters?
    let handler: LoginCompletionParametersBlock = { parameters in
      capturedParameters = parameters
      completionWasInvoked = true
    }

    urlCompleter.completeLogin(
      nonce: Values.nonce,
      codeVerifier: Values.codeVerifier,
      handler: handler
    )

    graphRequestFactory.capturedRequests.first?.capturedCompletionHandler?(nil, stubbedResult, nil)

    XCTAssertEqual(
      urlCompleter.parameters,
      capturedParameters,
      "Should call the completion with the provided parameters"
    )
    XCTAssertNotNil(
      urlCompleter.parameters.error,
      "Should set error from the graph request's result"
    )
    XCTAssertTrue(completionWasInvoked)
  }

  func testCodeExchangeCompletionWithAccessTokenString() {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withCode,
      appID: Values.appID
    )
    let stubbedResult = [Keys.accessToken: name]

    var completionWasInvoked = false
    var capturedParameters: _LoginCompletionParameters?
    let handler: LoginCompletionParametersBlock = { parameters in
      capturedParameters = parameters
      completionWasInvoked = true
    }

    urlCompleter.completeLogin(
      nonce: Values.nonce,
      codeVerifier: Values.codeVerifier,
      handler: handler
    )

    graphRequestFactory.capturedRequests.first?.capturedCompletionHandler?(nil, stubbedResult, nil)

    XCTAssertEqual(
      urlCompleter.parameters,
      capturedParameters,
      "Should call the completion with the provided parameters"
    )
    XCTAssertEqual(
      urlCompleter.parameters.accessTokenString,
      name,
      "Should set the access token string from the graph request's result"
    )
    XCTAssertTrue(completionWasInvoked)
  }

  func testCodeExchangeCompletionWithAccessTokenStringAndAuthenticationTokenString() {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withCode,
      appID: Values.appID
    )
    let stubbedResult = [
      Keys.accessToken: Values.accessToken,
      Keys.idToken: Values.idToken,
    ]

    urlCompleter.completeLogin(
      nonce: Values.nonce,
      codeVerifier: Values.codeVerifier
    ) { _ in }

    graphRequestFactory.capturedRequests.first?.capturedCompletionHandler?(nil, stubbedResult, nil)

    XCTAssertEqual(
      urlCompleter.parameters.accessTokenString,
      Values.accessToken,
      "Should set the access token string from the graph request's result"
    )
    XCTAssertEqual(
      urlCompleter.parameters.authenticationTokenString,
      Values.idToken,
      "Should set the authentication token string from the graph request's result"
    )
    XCTAssertEqual(
      authenticationTokenFactory.capturedTokenString,
      Values.idToken,
      "Should call AuthenticationTokenFactory with the expected token string"
    )
    XCTAssertEqual(
      authenticationTokenFactory.capturedNonce,
      Values.nonce,
      "Should call AuthenticationTokenFactory with the expected nonce"
    )
  }

  func testCodeExchangeWithRandomResults() {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withCode,
      appID: Values.appID
    )

    let stubbedResult: [String: Any] = [
      Keys.accessToken: Values.accessToken,
      "expires_in": "10000",
      "data_access_expiration_time": 1,
    ]

    var completionWasInvoked = false
    urlCompleter.completeLogin(
      nonce: Values.nonce,
      codeVerifier: Values.codeVerifier
    ) { _ in
      // Basically just making sure that nothing crashes here when we feed it garbage results
      completionWasInvoked = true
    }

    (0 ..< 100).forEach { _ in
      let mangledResult = stubbedResult
      let parameters = Fuzzer.randomize(json: mangledResult)

      graphRequestFactory.capturedRequests.first?.capturedCompletionHandler?(nil, parameters, nil)

      XCTAssertTrue(completionWasInvoked)
      completionWasInvoked = false
    }
  }

  func testCompleteWithAuthenticationTokenWithoutNonce() {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withIDToken,
      appID: Values.appID
    )

    urlCompleter.completeLogin { _ in }

    XCTAssertNotNil(urlCompleter.parameters.error)
    XCTAssertEqual(graphRequestFactory.capturedRequests.count, 0)
    XCTAssertNil(authenticationTokenFactory.capturedTokenString)
  }

  func testCompleteWithAuthenticationTokenWithNonce() {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withIDToken,
      appID: Values.appID
    )

    let nonce = Values.nonce

    urlCompleter.completeLogin(
      nonce: nonce,
      codeVerifier: Values.codeVerifier
    ) { _ in }

    XCTAssertNil(urlCompleter.parameters.error)
    XCTAssertEqual(graphRequestFactory.capturedRequests.count, 0)
    XCTAssertEqual(
      authenticationTokenFactory.capturedTokenString,
      SampleRawLoginCompletionParameters.withIDToken[Keys.idToken] as? String,
      "Should call AuthenticationTokenFactory with the expected token string"
    )
    XCTAssertEqual(
      authenticationTokenFactory.capturedNonce,
      nonce,
      "Should call AuthenticationTokenFactory with the expected nonce"
    )
  }

  func testAuthenticationTokenCreationCompleteWithEmptyResult() {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withIDToken,
      appID: Values.appID
    )

    var completionWasInvoked = false
    var capturedParameters: _LoginCompletionParameters?
    urlCompleter.completeLogin { parameters in
      capturedParameters = parameters
      completionWasInvoked = true
    }

    authenticationTokenFactory.capturedCompletion?(nil)

    XCTAssertNotNil(capturedParameters?.error)
    XCTAssertNil(capturedParameters?.authenticationToken)
    XCTAssert(
      completionWasInvoked,
      "Handler should be invoked"
    )
  }

  func testAuthenticationTokenCreationCompleteWithToken() throws {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withIDToken,
      appID: Values.appID
    )
    let nonce = Values.nonce

    var completionWasInvoked = false
    var capturedParameters: _LoginCompletionParameters?
    urlCompleter.completeLogin(
      nonce: nonce,
      codeVerifier: Values.codeVerifier
    ) { parameters in
      capturedParameters = parameters
      completionWasInvoked = true
    }

    let tokenString = try XCTUnwrap(SampleRawLoginCompletionParameters.withIDToken[Keys.idToken] as? String)
    let token = AuthenticationToken(
      tokenString: tokenString,
      nonce: nonce
    )

    authenticationTokenFactory.capturedCompletion?(token)

    XCTAssertNil(urlCompleter.parameters.error)
    let capturedToken = try XCTUnwrap(capturedParameters?.authenticationToken)
    XCTAssertEqual(
      capturedToken.tokenString,
      SampleRawLoginCompletionParameters.withIDToken[Keys.idToken] as? String
    )
    XCTAssertEqual(capturedToken.nonce, nonce)
    XCTAssert(
      completionWasInvoked,
      "Handler should be invoked"
    )
  }

  func testCompleteWithAccessToken() throws {
    urlCompleter = createLoginCompleter(
      parameters: SampleRawLoginCompletionParameters.withAccessToken,
      appID: Values.appID
    )

    var completionWasInvoked = false
    var capturedParameters: _LoginCompletionParameters?
    urlCompleter.completeLogin(
      nonce: Values.nonce,
      codeVerifier: Values.codeVerifier
    ) { parameters in
      capturedParameters = parameters
      completionWasInvoked = true
    }

    let parameters = try XCTUnwrap(capturedParameters)
    verifyParameters(
      actual: parameters,
      expected: SampleRawLoginCompletionParameters.withAccessToken
    )

    XCTAssertTrue(completionWasInvoked, "Handler should be invoked")
    XCTAssertNil(urlCompleter.parameters.error)
    XCTAssertEqual(graphRequestFactory.capturedRequests.count, 0)
    XCTAssertNil(authenticationTokenFactory.capturedTokenString)
  }

  func testCompleteWithEmptyParameters() {
    urlCompleter = createLoginCompleter(parameters: [:], appID: Values.appID)

    var completionWasInvoked = false
    urlCompleter.completeLogin(
      nonce: Values.nonce,
      codeVerifier: Values.codeVerifier
    ) { _ in
      completionWasInvoked = true
    }

    XCTAssert(completionWasInvoked, "Handler should be invoked")
    XCTAssertNil(urlCompleter.parameters.error)
    XCTAssertEqual(graphRequestFactory.capturedRequests.count, 0)
    XCTAssertNil(authenticationTokenFactory.capturedTokenString)
  }

  func testErrorFromURLParametersWithEmptyParameters() throws {
    let parameters = [String: Any]()
    let error = urlCompleter.error(from: parameters)

    XCTAssertNil(error, .noErrorForEmptyParameters)
  }

  func testErrorFromURLParametersWithParameters() throws {
    let parameters = ["error_message": "foo"]
    let returnedError = try XCTUnwrap(
      urlCompleter.error(from: parameters),
      .errorForParameters
    )
    let error = try XCTUnwrap(returnedError as NSError, .errorForParameters)

    XCTAssertEqual(error.code, 8, .errorCodeMatches)
    XCTAssertEqual(error.domain, "com.facebook.sdk.core", .errorDomainMatches)
    XCTAssertFalse(error.userInfo.isEmpty, .hasNoValuesForUserInfo)
  }

  // MARK: Profile

  func testCreateProfileWithClaims() throws {
    let factory = TestProfileFactory(stubbedProfile: SampleUserProfiles.createValid())
    let parameters = SampleRawLoginCompletionParameters.withAccessTokenWithIDToken

    urlCompleter = createLoginCompleter(parameters: parameters, appID: Values.appID)
    LoginURLCompleter.setDependencies(
      .init(
        profileFactory: factory,
        authenticationTokenCreator: authenticationTokenFactory,
        graphRequestFactory: graphRequestFactory,
        internalUtility: internalUtility,
        errorFactory: errorFactory
      )
    )

    let claim = try XCTUnwrap(
      AuthenticationTokenClaims(
        jti: "some_jti",
        iss: "some_iss",
        aud: "some_aud",
        nonce: Values.nonce,
        exp: 1234,
        iat: 1234,
        sub: "some_sub",
        name: "some_name",
        givenName: "first",
        middleName: "middle",
        familyName: "last",
        email: "example@example.com",
        picture: "www.facebook.com",
        userFriends: ["123", "456"],
        userBirthday: "01/01/1990",
        userAgeRange: ["min": 21],
        userHometown: ["id": "112724962075996", "name": "Martinez, California"],
        userLocation: ["id": "110843418940484", "name": "Seattle, Washington"],
        userGender: "male",
        userLink: "facebook.com"
      )
    )
    let profile = urlCompleter.profile(
      with: claim,
      permissions: [
        "public_profile",
        "user_link",
        "email",
        "user_friends",
        "user_birthday",
        "user_age_range",
        "user_hometown",
        "user_location",
        "user_gender",
      ]
    )

    XCTAssertEqual(
      factory.capturedUserID,
      claim.sub,
      "Should request a profile with the claims sub as the user identifier"
    )
    XCTAssertEqual(
      factory.capturedName,
      claim.name,
      "Should request a profile using the name from the claims"
    )
    XCTAssertEqual(
      factory.capturedFirstName,
      claim.givenName,
      "Should request a profile using the first name from the claims"
    )
    XCTAssertEqual(
      factory.capturedMiddleName,
      claim.middleName,
      "Should request a profile using the middle name from the claims"
    )
    XCTAssertEqual(
      factory.capturedLastName,
      claim.familyName,
      "Should request a profile using the last name from the claims"
    )
    XCTAssertEqual(
      factory.capturedImageURL?.absoluteString,
      claim.picture,
      "Should request an image URL from the claims"
    )
    XCTAssertEqual(
      factory.capturedEmail,
      claim.email,
      "Should request a profile using the email from the claims"
    )
    XCTAssertEqual(
      factory.capturedFriendIDs,
      claim.userFriends,
      "Should request a profile using the friend identifiers from the claims"
    )
    XCTAssertEqual(
      factory.capturedPermissions,
      profile?.permissions,
      "Should request a profile using the friend identifiers from the claims"
    )
    // @lint-ignore FBOBJCDISCOURAGEDFUNCTION
    let formatter = DateFormatter()
    formatter.dateFormat = "MM/dd/yyyy"
    let capturedBirthday = try XCTUnwrap(factory.capturedBirthday)
    XCTAssertEqual(
      formatter.string(from: capturedBirthday),
      claim.userBirthday,
      "Should request a profile using the user birthday from the claims"
    )
    let rawAgeRange = try XCTUnwrap(claim.userAgeRange)
    XCTAssertEqual(
      factory.capturedAgeRange,
      UserAgeRange(from: rawAgeRange),
      "Should request a profile using the user age range from the claims"
    )
    let rawHometownLocation = try XCTUnwrap(claim.userHometown)
    XCTAssertEqual(
      factory.capturedHometown,
      Location(from: rawHometownLocation),
      "Should request a profile using the user hometown from the claims"
    )
    let rawUserLocation = try XCTUnwrap(claim.userLocation)
    XCTAssertEqual(
      factory.capturedLocation,
      Location(from: rawUserLocation),
      "Should request a profile using the user location from the claims"
    )
    XCTAssertEqual(
      factory.capturedGender,
      claim.userGender,
      "Should request a profile using the gender from the claims"
    )
    let rawUserLink = try XCTUnwrap(claim.userLink)
    XCTAssertEqual(
      factory.capturedLinkURL,
      URL(string: rawUserLink),
      "Should request a profile using the link from the claims"
    )
    XCTAssertTrue(
      factory.capturedIsLimited,
      "Should request a profile with limited information"
    )
  }

  // MARK: - Helpers

  func createLoginCompleter(parameters: [String: Any], appID: String) -> LoginURLCompleter {
    LoginURLCompleter(
      urlParameters: parameters,
      appID: appID
    )
  }

  func verifyParameters(
    actual: _LoginCompletionParameters,
    expected: [String: Any],
    _ file: StaticString = #file,
    _ line: UInt = #line
  ) {
    XCTAssertEqual(
      actual.accessTokenString,
      expected[Keys.accessToken] as? String,
      file: file,
      line: line
    )
    XCTAssertEqual(
      actual.authenticationTokenString,
      expected[Keys.idToken] as? String,
      file: file,
      line: line
    )
    XCTAssertEqual(
      actual.appID,
      Values.appID,
      file: file,
      line: line
    )
    XCTAssertEqual(
      actual.challenge,
      SampleRawLoginCompletionParameters.fakeChallenge,
      file: file,
      line: line
    )
    if let rawGrantedPermissions = expected[Keys.grantedScopes] as? String {
      let grantedPermissions = Set(
        rawGrantedPermissions
          .split(separator: ",")
          .compactMap { FBPermission(string: String($0)) }
      )

      XCTAssertEqual(
        actual.permissions,
        grantedPermissions,
        file: file,
        line: line
      )
    }
    if let rawDeclinedPermissions = expected[Keys.deniedScopes] as? String {
      let declinedPermissions = Set(
        rawDeclinedPermissions
          .split(separator: ",")
          .compactMap { FBPermission(string: String($0)) }
      )

      XCTAssertEqual(
        actual.declinedPermissions,
        declinedPermissions,
        file: file,
        line: line
      )
    }
    XCTAssertEqual(
      actual.userID,
      expected[Keys.userID] as? String,
      file: file,
      line: line
    )
    XCTAssertEqual(
      actual.graphDomain,
      expected[Keys.graphDomain] as? String,
      file: file,
      line: line
    )

    if let expectedExpires = expected[Keys.expires] as? Double,
       let expires = actual.expirationDate?.timeIntervalSince1970 {
      XCTAssertEqual(
        expires,
        expectedExpires,
        accuracy: 100,
        file: file,
        line: line
      )
    }
    if let expectedExpiresAt = expected[Keys.expiresAt] as? Double,
       let expiresAt = actual.expirationDate?.timeIntervalSince1970 {
      XCTAssertEqual(
        expiresAt,
        expectedExpiresAt,
        accuracy: 100,
        file: file,
        line: line
      )
    }
    if let expectedExpiresIn = expected[Keys.expiresIn] as? Double,
       let expiresIn = actual.expirationDate?.timeIntervalSinceNow {
      XCTAssertEqual(
        expiresIn,
        expectedExpiresIn,
        accuracy: 100,
        file: file,
        line: line
      )
    }
    if let expectedDataAccessExpiration = expected[Keys.dataAccessExpiration] as? TimeInterval,
       let dataExpiration = actual.dataAccessExpirationDate?.timeIntervalSince1970 {
      XCTAssertEqual(
        dataExpiration,
        expectedDataAccessExpiration,
        accuracy: 100,
        file: file,
        line: line
      )
    }

    XCTAssertEqual(
      actual.nonceString,
      expected[Keys.nonce] as? String,
      file: file,
      line: line
    )
    XCTAssertNil(actual.error, file: file, line: line)
  }

  func verifyEmptyParameters(
    _ parameters: _LoginCompletionParameters,
    _ file: StaticString = #file,
    _ line: UInt = #line
  ) {
    XCTAssertNil(parameters.accessTokenString, file: file, line: line)
    XCTAssertNil(parameters.authenticationTokenString, file: file, line: line)
    XCTAssertNil(parameters.appID, file: file, line: line)
    XCTAssertNil(parameters.challenge, file: file, line: line)
    XCTAssertNil(parameters.permissions, file: file, line: line)
    XCTAssertNil(parameters.declinedPermissions, file: file, line: line)
    XCTAssertNil(parameters.userID, file: file, line: line)
    XCTAssertNil(parameters.graphDomain, file: file, line: line)
    XCTAssertNil(parameters.expirationDate, file: file, line: line)
    XCTAssertNil(parameters.dataAccessExpirationDate, file: file, line: line)
    XCTAssertNil(parameters.nonceString, file: file, line: line)
    XCTAssertNil(parameters.error, file: file, line: line)
  }
}

// swiftformat:disable extensionaccesscontrol

// MARK: - Assumptions

fileprivate extension String {
  static func defaultDependency(_ dependency: String, for type: String) -> String {
    "The LoginURLCompleter type uses \(dependency) as its \(type) dependency by default"
  }

  static func customDependency(for type: String) -> String {
    "The LoginURLCompleter type uses a custom \(type) dependency when provided"
  }

  static let noErrorForEmptyParameters = "No error is returned if empty parameters are passed"
  static let errorForParameters = "An error is returned if some parameters are passed"
  static let errorCodeMatches = "The returned error code matches the error code passed"
  static let errorDomainMatches = "The returned error domain matches the expected domain"
  static let hasNoValuesForUserInfo = "User info does not contain any values"
}
