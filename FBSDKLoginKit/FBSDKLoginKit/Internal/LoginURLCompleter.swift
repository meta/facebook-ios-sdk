/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBSDKCoreKit
import FBSDKCoreKit_Basics
import Foundation

/**
 Extracts the log in completion parameters from the parameters dictionary,
 which must contain the parsed result of the return URL query string.

 The  user_id key is first used to derive the User ID. If that fails,  signed_request
 is used.

 Completion occurs synchronously.
 */

struct LoginURLCompleter: LoginCompleting {
  let parameters = _LoginCompletionParameters()

  init(urlParameters: [String: Any], appID: String) {
    let nonce = urlParameters["nonce"] as? String ?? ""
    let idToken = urlParameters["id_token"] as? String ?? ""
    let accessToken = urlParameters["access_token"] as? String ?? ""
    let code = urlParameters["code"] as? String ?? ""

    let hasNonEmptyNonceString = !nonce.isEmpty
    let hasNonEmptyIdTokenString = !idToken.isEmpty
    let hasNonEmptyAccessTokenString = !accessToken.isEmpty
    let hasNonEmptyCodeString = !code.isEmpty

    // Code and id token are mutually exclusive parameters
    let hasBothCodeAndIdToken = hasNonEmptyCodeString && hasNonEmptyIdTokenString
    let hasEitherCodeOrIdToken = hasNonEmptyCodeString || hasNonEmptyIdTokenString

    // Nonce and id token are mutually exclusive parameters
    let hasBothNonceAndIdToken = hasNonEmptyNonceString && hasNonEmptyIdTokenString
    let hasEitherNonceOrIdToken = hasNonEmptyNonceString || hasNonEmptyIdTokenString

    if hasNonEmptyAccessTokenString ||
      (hasEitherCodeOrIdToken && !hasBothCodeAndIdToken) ||
      (hasEitherNonceOrIdToken && !hasBothNonceAndIdToken) {
      setParameters(values: urlParameters, appID: appID)
    } else if urlParameters["error"] as? String != nil ||
      urlParameters["error_message"] as? String != nil {
      parameters.error = error(from: urlParameters)
    } else if hasBothCodeAndIdToken,
              let errorFactory = try? Self.getDependencies().errorFactory {
      // If no Access Token is returned with ID Token, we assume that
      // tracking perference is limited. We currently cannot perform
      // code exchange with limit tracking, thus this is not a valid
      // state
      parameters.error = errorFactory.error(
        code: LoginError.unknown.rawValue,
        userInfo: nil,
        message: "Invalid server response. Please try to login again",
        underlyingError: nil
      )
    }
  }

  /// Performs the work needed to populate the login completion parameters before they
  /// are used to determine login success, failure or cancellation.
  func completeLogin(handler: @escaping LoginCompletionParametersBlock) {
    completeLogin(nonce: nil, codeVerifier: nil, handler: handler)
  }

  func completeLogin(
    nonce: String?,
    codeVerifier: String?,
    handler: @escaping LoginCompletionParametersBlock
  ) {
    if parameters.code != nil {
      exchangeCodeForTokensWith(nonce: nonce, codeVerifier: codeVerifier, handler: handler)
    } else if parameters.nonceString != nil {
      exchangeNonceForTokenWith(handler: handler, authenticationNonce: nonce ?? "")
    } else if parameters.authenticationTokenString != nil,
              nonce == nil,
              let errorFactory = try? Self.getDependencies().errorFactory {

      parameters.error = errorFactory.error(
        code: LoginError.unknown.rawValue,
        userInfo: nil,
        message: "Please try to login again",
        underlyingError: nil
      )
      handler(parameters)
    } else if parameters.authenticationTokenString != nil, let nonce = nonce {
      fetchAndSetPropertiesFor(parameters: parameters, nonce: nonce, handler: handler)
    } else {
      handler(parameters)
    }
  }

  func fetchAndSetPropertiesFor(
    parameters: _LoginCompletionParameters,
    nonce: String,
    handler: @escaping LoginCompletionParametersBlock
  ) {
    guard
      let dependencies = try? Self.getDependencies()
    else {
      return
    }

    dependencies.authenticationTokenCreator.createToken(
      tokenString: parameters.authenticationTokenString ?? "",
      nonce: nonce,
      graphDomain: parameters.graphDomain ?? ""
    ) { token in
      if let token = token {
        parameters.authenticationToken = token
        if let claims = token.claims() {
          let permissionsStringSet = FBPermission.rawPermissions(from: parameters.permissions ?? Set<FBPermission>())
          parameters.profile = self.profile(with: claims, permissions: permissionsStringSet)
        }
      } else {
        parameters.error = dependencies.errorFactory.error(
          code: LoginError.invalidIDToken.rawValue,
          userInfo: nil,
          message: "Invalid ID token from login response.",
          underlyingError: nil
        )
      }

      handler(parameters)
    }
  }

  func setParameters(values: [String: Any], appID: String) {
    parameters.accessTokenString = values["access_token"] as? String
    parameters.nonceString = values["nonce"] as? String
    parameters.authenticationTokenString = values["id_token"] as? String
    parameters.code = values["code"] as? String
    parameters.userTokenNonce = values["user_token_nonce"] as? String

    let grantedPermissionsString = values["granted_scopes"] as? String ?? ""
    let declinedPermissionsString = values["denied_scopes"] as? String ?? ""

    let grantedPermissionSet = FBPermission.permissions(
      fromRawPermissions: Set(grantedPermissionsString.components(separatedBy: ","))
    )
    let declinedPermissionSet = FBPermission.permissions(
      fromRawPermissions: Set(declinedPermissionsString.components(separatedBy: ","))
    )

    // check the string length so that we assign an empty set rather than a set with an empty string
    parameters.permissions = grantedPermissionsString.isEmpty ? Set<FBPermission>() : grantedPermissionSet
    parameters.declinedPermissions = declinedPermissionsString.isEmpty ? Set<FBPermission>() : declinedPermissionSet
    parameters.expiredPermissions = []
    parameters.appID = appID

    let userID = values["user_id"] as? String

    if let userID = userID,
       userID.isEmpty,
       let signedRequest = values["signed_request"] as? String,
       !signedRequest.isEmpty {
      parameters.userID = LoginUtility.getUserID(from: signedRequest)
    } else {
      parameters.userID = userID
    }

    if let domain = values["graph_domain"] as? String,
       !domain.isEmpty {
      parameters.graphDomain = domain
    }

    parameters.expirationDate = expirationDateFrom(parameters: values)
    parameters.dataAccessExpirationDate = dataAccessExpirationDateFrom(parameters: values)
    parameters.challenge = challenge(from: values)
  }

  func exchangeNonceForTokenWith(handler: @escaping LoginCompletionParametersBlock, authenticationNonce: String) {
    let nonce = parameters.nonceString ?? ""
    let appID = parameters.appID ?? ""

    guard let dependencies = try? Self.getDependencies() else {
      return
    }

    guard
      !nonce.isEmpty,
      !appID.isEmpty
    else {
      parameters.error = dependencies.errorFactory.error(
        code: CoreError.errorInvalidArgument.rawValue,
        userInfo: nil,
        message: "Missing required parameters to exchange nonce for access token.",
        underlyingError: nil
      )
      handler(parameters)
      return
    }

    let request = dependencies.graphRequestFactory.createGraphRequest(
      withGraphPath: "oauth/access_token",
      parameters: [
        "grant_type": "fb_exchange_nonce",
        "fb_exchange_nonce": nonce,
        "client_id": appID,
        "fields": "",
      ],
      flags: [.doNotInvalidateTokenOnError, .disableErrorRecovery]
    )

    request.start { [self] _, result, graphRequestError in
      guard
        graphRequestError == nil
      else {
        parameters.error = graphRequestError
        handler(parameters)
        return
      }

      if let result = result as? [String: Any] {
        parameters.accessTokenString = result["access_token"] as? String
        parameters.expirationDate = expirationDateFrom(parameters: result)
        parameters.dataAccessExpirationDate = dataAccessExpirationDateFrom(parameters: result)
        parameters.authenticationTokenString = result["id_token"] as? String
      }

      if parameters.authenticationTokenString != nil {
        fetchAndSetPropertiesFor(parameters: parameters, nonce: authenticationNonce, handler: handler)
        return
      }

      handler(parameters)
    }
  }

  func exchangeCodeForTokensWith(
    nonce: String?,
    codeVerifier: String?,
    handler: @escaping LoginCompletionParametersBlock
  ) {
    let code = parameters.code ?? ""
    let appID = parameters.appID ?? ""

    guard let dependencies = try? Self.getDependencies() else {
      return
    }

    guard
      !code.isEmpty,
      !appID.isEmpty,
      let codeVerifier = codeVerifier,
      !codeVerifier.isEmpty
    else {
      parameters.error = dependencies.errorFactory.error(
        code: CoreError.errorInvalidArgument.rawValue,
        userInfo: nil,
        message: "Missing required parameters to exchange nonce for access token.",
        underlyingError: nil
      )
      handler(parameters)
      return
    }

    let redirectURL = try? dependencies.internalUtility.appURL(withHost: "authorize", path: "", queryParameters: [:])
    let request = dependencies.graphRequestFactory.createGraphRequest(
      withGraphPath: "oauth/access_token",
      parameters: [
        "client_id": appID,
        "redirect_uri": redirectURL?.absoluteString as Any,
        "code_verifier": codeVerifier,
        "code": code,
      ],
      flags: [.doNotInvalidateTokenOnError, .disableErrorRecovery]
    )

    request.start { [self] _, result, graphRequestError in
      parameters.code = nil

      guard
        graphRequestError == nil,
        let result = result as? [String: Any]
      else {
        parameters.error = graphRequestError
        completeLogin(nonce: nonce, codeVerifier: nil, handler: handler)
        return
      }

      if result["error"] != nil,
         let errorFactory = try? Self.getDependencies().errorFactory {
        parameters.error = errorFactory.error(
          code: CoreError.errorInvalidArgument.rawValue,
          userInfo: nil,
          message: "Failed to exchange code for Access Token",
          underlyingError: nil
        )
      } else {
        parameters.accessTokenString = result["access_token"] as? String
        parameters.expirationDate = expirationDateFrom(parameters: result)
        parameters.authenticationTokenString = result["id_token"] as? String
      }

      completeLogin(nonce: nonce, codeVerifier: nil, handler: handler)
    }
  }

  func profile(with claims: AuthenticationTokenClaims, permissions: Set<String>?) -> Profile? {
    guard
      !claims.sub.isEmpty,
      let profileFactory = try? Self.getDependencies().profileFactory
    else {
      return nil
    }

    var imageURL: URL?
    if let picture = claims.picture {
      imageURL = URL(string: picture)
    }

    var birthday: Date?
    if let userBirthday = claims.userBirthday {
      let dateFormatter = DateFormatter()
      dateFormatter.dateFormat = "MM/dd/yyyy"
      birthday = dateFormatter.date(from: userBirthday)
    }

    return profileFactory.createProfile(
      userID: claims.sub,
      firstName: claims.givenName,
      middleName: claims.middleName,
      lastName: claims.familyName,
      name: claims.name,
      linkURL: URL(string: claims.userLink ?? ""),
      refreshDate: nil,
      imageURL: imageURL,
      email: claims.email,
      friendIDs: claims.userFriends,
      birthday: birthday,
      ageRange: UserAgeRange(from: claims.userAgeRange ?? [:]),
      hometown: Location(from: claims.userHometown ?? [:]),
      location: Location(from: claims.userLocation ?? [:]),
      gender: claims.userGender,
      permissions: permissions,
      isLimited: true
    )
  }

  func expirationDateFrom(parameters: [String: Any]) -> Date {
    let expires = timeInterval(from: parameters["expires"])
    let expiresAt = timeInterval(from: parameters["expires_at"])
    let expiresIn = timeInterval(from: parameters["expires_in"])

    let expirationDate = expires ?? expiresAt

    if let expirationDate = expirationDate,
       expirationDate > 0 {
      return Date(timeIntervalSince1970: expirationDate)
    } else if let expiresIn = expiresIn,
              expiresIn > 0 {
      return Date(timeIntervalSinceNow: expiresIn)
    } else {
      return Date.distantFuture
    }
  }

  func dataAccessExpirationDateFrom(parameters: [String: Any]) -> Date {
    guard
      let dataAccessExpirationDate = timeInterval(from: parameters["data_access_expiration_time"]),
      dataAccessExpirationDate > 0
    else {
      return Date.distantFuture
    }

    return Date(timeIntervalSince1970: dataAccessExpirationDate)
  }

  private func timeInterval(from value: Any?) -> TimeInterval? {
    // Graph responses contain numbers, whereas login URL query values are strings.
    guard let interval = (value as? TimeInterval) ?? (value as? String).flatMap({ TimeInterval($0) }),
          interval.isFinite else {
      return nil
    }
    return interval
  }

  func challenge(from parameters: [String: Any]) -> String? {
    guard
      let stateString = parameters["state"] as? String,
      let state = try? BasicUtility.object(forJSONString: stateString) as? [String: Any],
      let challenge = state["challenge"] as? String,
      !challenge.isEmpty
    else {
      return nil
    }

    return Utility.decode(urlString: challenge)
  }

  func error(from urlParameters: [String: Any]) -> Error? {
    guard let errorMessage = urlParameters["error_message"] as? String else {
      return nil
    }

    var userInfo = [String: Any]()
    userInfo[ErrorDeveloperMessageKey] = errorMessage

    if let error = urlParameters["error"] as? String {
      userInfo[ErrorDeveloperMessageKey] = error
    }

    if let errorCode = urlParameters["error_code"] as? String {
      userInfo[GraphRequestErrorGraphErrorCodeKey] = errorCode
    }

    if userInfo[ErrorDeveloperMessageKey] == nil,
       let errorReason = urlParameters["error_reason"] as? String {
      userInfo[ErrorDeveloperMessageKey] = errorReason
    }

    userInfo[GraphRequestErrorKey] = GraphRequestError.other

    return NSError(
      domain: ErrorDomain,
      code: CoreError.errorGraphRequestGraphAPI.rawValue,
      userInfo: userInfo
    )
  }
}

extension LoginURLCompleter: DependentAsType {
  struct TypeDependencies {
    var profileFactory: ProfileCreating
    var authenticationTokenCreator: AuthenticationTokenCreating
    var graphRequestFactory: GraphRequestFactoryProtocol
    var internalUtility: URLHosting
    var errorFactory: ErrorCreating
  }

  static var configuredDependencies: TypeDependencies?
  static var defaultDependencies: TypeDependencies? = TypeDependencies(
    profileFactory: ProfileFactory(),
    authenticationTokenCreator: AuthenticationTokenFactory(),
    graphRequestFactory: GraphRequestFactory(),
    internalUtility: InternalUtility.shared,
    errorFactory: _ErrorFactory()
  )
}
