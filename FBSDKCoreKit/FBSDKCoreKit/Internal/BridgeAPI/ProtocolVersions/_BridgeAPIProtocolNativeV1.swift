/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import UIKit

/**
 Internal Type exposed to facilitate transition to Swift.
 API Subject to change or removal without warning. Do not use.

 @warning INTERNAL - DO NOT USE
 */
@objcMembers
@objc(FBSDKBridgeAPIProtocolNativeV1)
public final class _BridgeAPIProtocolNativeV1: NSObject, BridgeAPIProtocol {
  let appScheme: String?
  let dataLengthThreshold: UInt
  let shouldIncludeAppIcon: Bool
  let pasteboard: _Pasteboard?
  static let defaultMaxBase64DataLengthThreshold: UInt = 1024 * 16

  private struct PasteboardObservation {
    let identifier: UUID
    let notificationDeliverer: NotificationDelivering
    let token: NSObjectProtocol
  }

  private var pasteboardObservation: PasteboardObservation?

  var appIcon: UIImage? {
    guard
      shouldIncludeAppIcon,
      let bundle = try? Self.getDependencies().bundle,
      let icons = bundle.fb_object(forInfoDictionaryKey: InfoDictionaryKeys.icons) as? [String: [String: Any]],
      let primaryIcons = icons[InfoDictionaryKeys.primaryIcon],
      let iconNames = primaryIcons[InfoDictionaryKeys.iconFiles] as? [String],
      let iconName = iconNames.first
    else {
      return nil
    }

    return UIImage(named: iconName)
  }

  private enum DataTypeTags {
    static let data = "data"

    // we serialize jpegs but use png for backward compatibility - it is any image format that UIImage can handle
    static let image = "png"
  }

  private enum PasteboardKeys {
    static let isBase64 = "isBase64"
    static let isPasteboard = "isPasteboard"
    static let tag = "tag"
    static let value = "fbAppBridgeType_jsonReadyValue"
    static let pasteboard = "com.facebook.Facebook.FBAppBridgeType"
  }

  private enum InfoDictionaryKeys {
    static let icons = "CFBundleIcons"
    static let primaryIcon = "CFBundlePrimaryIcon"
    static let iconFiles = "CFBundleIconFiles"
  }

  private enum InputKeys {
    static let error = "error"
    static let methodResults = "method_results"
    static let completionGesture = "completionGesture"
    static let cancel = "cancel"
    static let dialog = "dialog"
  }

  private enum BridgeParameterOutputKeys {
    static let actionID = "action_id"
    static let appIcon = "app_icon"
    static let appName = "app_name"
    static let sdkVersion = "sdk_version"
  }

  private enum OutputKeys {
    static let bridge = "bridge_args"
    static let method = "method_args"
  }

  private enum ErrorKeys {
    static let code = "code"
    static let domain = "domain"
    static let userInfo = "user_info"
  }

  @objc(initWithAppScheme:)
  public convenience init(appScheme: String?) {
    self.init(
      appScheme: appScheme,
      pasteboard: UIPasteboard.general,
      dataLengthThreshold: Self.defaultMaxBase64DataLengthThreshold,
      shouldIncludeAppIcon: true
    )
  }

  @objc(initWithAppScheme:pasteboard:dataLengthThreshold:includeAppIcon:)
  public init(appScheme: String?, pasteboard: _Pasteboard?, dataLengthThreshold: UInt, shouldIncludeAppIcon: Bool) {
    self.appScheme = appScheme
    self.pasteboard = pasteboard
    self.dataLengthThreshold = dataLengthThreshold
    self.shouldIncludeAppIcon = shouldIncludeAppIcon
  }

  deinit {
    removePasteboardObserver()
  }

  public func requestURL(
    actionID: String,
    scheme: String,
    methodName: String,
    parameters: [String: Any]
  ) throws -> URL {

    var queryParameters = [String: String]()

    if !parameters.isEmpty {
      let parameterString = try getJSON(dictionary: parameters, enabledPasteboard: true)

      let escapedParameterString = parameterString.replacingOccurrences(
        of: "&",
        with: "%26",
        options: .caseInsensitive
      )
      queryParameters[OutputKeys.method] = escapedParameterString
    }

    let bridgeParameters = getBridgeParameters(actionID: actionID)
    let bridgeParametersString = try getJSON(dictionary: bridgeParameters, enabledPasteboard: false)

    queryParameters[OutputKeys.bridge] = bridgeParametersString

    let internalUtility = try Self.getDependencies().internalUtility
    return try internalUtility.url(
      withScheme: appScheme ?? "",
      host: InputKeys.dialog,
      path: "/\(methodName)",
      queryParameters: queryParameters
    )
  }

  public func responseParameters(
    actionID: String,
    queryParameters: [String: Any],
    cancelled cancelledRef: UnsafeMutablePointer<ObjCBool>?
  ) throws -> [String: Any] {

    if let cancelled = cancelledRef {
      cancelled.pointee = false
    }

    let errorFactory = try Self.getDependencies().errorFactory

    let bridgeParametersJSON = queryParameters[OutputKeys.bridge] as? String ?? ""
    var bridgeParameters = [String: Any]()

    do {
      guard
        let parameters = try BasicUtility.object(forJSONString: bridgeParametersJSON) as? [String: Any],
        let responseActionID = parameters[BridgeParameterOutputKeys.actionID] as? String,
        responseActionID == actionID
      else {
        return [:]
      }
      bridgeParameters = parameters
    } catch {
      throw errorFactory.invalidArgumentError(
        name: OutputKeys.bridge,
        value: bridgeParametersJSON,
        message: "Invalid bridge_args.",
        underlyingError: error
      )
    }

    if let errorDictionary = bridgeParameters[InputKeys.error] as? [String: Any] {
      throw try getError(dictionary: errorDictionary)
    }

    let resultParametersJSON = queryParameters[InputKeys.methodResults] as? String ?? ""

    do {
      guard
        let resultParameters = try BasicUtility.object(forJSONString: resultParametersJSON) as? [String: Any]
      else {
        return [:]
      }

      if let cancelled = cancelledRef,
         let completionGesture = resultParameters[InputKeys.completionGesture] as? String {
        cancelled.pointee = ObjCBool(completionGesture == InputKeys.cancel)
      }

      return resultParameters
    } catch {
      throw errorFactory.invalidArgumentError(
        name: InputKeys.methodResults,
        value: resultParametersJSON,
        message: "Invalid method_results.",
        underlyingError: error
      )
    }
  }

  private func getBridgeParameters(actionID: String) -> [String: Any] {
    [
      BridgeParameterOutputKeys.actionID: actionID,
      BridgeParameterOutputKeys.appIcon: appIcon as Any,
      BridgeParameterOutputKeys.appName: Settings.shared.displayName as Any,
      BridgeParameterOutputKeys.sdkVersion: Settings.shared.sdkVersion,
    ]
  }

  private func getError(dictionary: [String: Any]) throws -> Error {
    let errorFactory = try Self.getDependencies().errorFactory

    let domain = dictionary[ErrorKeys.domain] as? String ?? ErrorDomain
    let code = dictionary[ErrorKeys.code] as? Int ?? CoreError.errorUnknown.rawValue
    let userInfo = dictionary[ErrorKeys.userInfo] as? [String: Any]
    return errorFactory.error(domain: domain, code: code, userInfo: userInfo, message: nil, underlyingError: nil)
  }

  private func getJSON(dictionary: [String: Any], enabledPasteboard: Bool) throws -> String {
    var didAddToPasteboard = false
    return try BasicUtility.jsonString(for: dictionary) { [self] invalidObject, _ in
      var dataTag = DataTypeTags.data
      var invalidObject = invalidObject

      if let image = invalidObject as? UIImage {
        // due to backward compatibility, we must send UIImage as Data even though UIPasteboard can handle UIImage
        invalidObject = image.jpegData(compressionQuality: Settings.shared.jpegCompressionQuality) as Any
        dataTag = DataTypeTags.image
      }

      if let data = invalidObject as? Data {
        var dictionary = [String: Any]()
        if didAddToPasteboard || !enabledPasteboard || pasteboard == nil || data.count < dataLengthThreshold {
          dictionary[PasteboardKeys.isBase64] = true
          dictionary[PasteboardKeys.tag] = dataTag
          dictionary[PasteboardKeys.value] = data.base64EncodedString(options: [])
        } else {
          dictionary[PasteboardKeys.isPasteboard] = true
          dictionary[PasteboardKeys.tag] = dataTag
          dictionary[PasteboardKeys.value] = pasteboard?.name
          pasteboard?.setData(data, forPasteboardType: PasteboardKeys.pasteboard)

          // this version of the protocol only supports a single item on the pasteboard, so if when we add an item, make
          // sure we don't add another item
          didAddToPasteboard = true

          // if we are adding this to the general pasteboard, then we want to remove it when we are done with the share.
          // the Facebook app will not clear the value with this version of the protocol, so we should do it when the app
          // becomes active again
          if pasteboard?._isGeneralPasteboard ?? false {
            clearPasteboardDataOnActivation(matching: data)
          }
        }
        return dictionary
      } else if let url = invalidObject as? URL {
        return url.absoluteString
      }

      return invalidObject
    }
  }

  private func clearPasteboardDataOnActivation(matching data: Data) {
    removePasteboardObserver()
    guard
      let notificationDeliverer = try? Self.getDependencies().notificationDeliverer
    else {
      return
    }

    let identifier = UUID()
    let token = notificationDeliverer.fb_addObserver(
      forName: .FBSDKApplicationDidBecomeActive,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      // A removed registration may already have a callback queued for delivery.
      guard let self = self,
            self.pasteboardObservation?.identifier == identifier else {
        return
      }
      self.removePasteboardObserver()
      let pasteboardData = self.pasteboard?.data(forPasteboardType: PasteboardKeys.pasteboard)
      if data == pasteboardData {
        self.pasteboard?.setData(Data(), forPasteboardType: PasteboardKeys.pasteboard)
      }
    }
    pasteboardObservation = PasteboardObservation(
      identifier: identifier,
      notificationDeliverer: notificationDeliverer,
      token: token
    )
  }

  private func removePasteboardObserver() {
    guard let observation = pasteboardObservation else {
      return
    }
    pasteboardObservation = nil
    observation.notificationDeliverer.fb_removeObserver(observation.token)
  }
}

extension _BridgeAPIProtocolNativeV1: DependentAsType {
  struct TypeDependencies {
    var errorFactory: ErrorCreating
    var bundle: InfoDictionaryProviding
    var notificationDeliverer: NotificationDelivering
    var internalUtility: InternalUtilityProtocol
  }

  static var configuredDependencies: TypeDependencies?

  static var defaultDependencies: TypeDependencies? = TypeDependencies(
    errorFactory: _ErrorFactory(),
    bundle: Bundle.main,
    notificationDeliverer: NotificationCenter.default,
    internalUtility: InternalUtility.shared
  )
}
