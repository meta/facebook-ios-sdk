/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

extension Profile {
  /// Defines the aspect ratio mode for the source image of the profile picture.
  @objc(FBSDKProfilePictureMode)
  public enum PictureMode: UInt {
    /// A square cropped version of the image will be included in the view.
    case square

    /// The original picture's aspect ratio will be used for the source image in the view.
    case normal

    /// The original picture's aspect ratio will be used for the source image in the view.
    case album

    /// The original picture's aspect ratio will be used for the source image in the view.
    case small

    /// The original picture's aspect ratio will be used for the source image in the view.
    case large
  }

  /**
   A convenience method for returning a complete `URL` for retrieving the user's profile image.

   For limited-login profiles, returns the existing `imageURL` without applying the requested
   picture mode or size. Returns `nil` when the profile has no image URL.

   - Parameters:
     - pictureMode: The picture mode.
     - size: The height and width. This will be rounded to integer precision.
   */
  @objc(imageURLForPictureMode:size:)
  public func imageURL(forMode pictureMode: PictureMode, size: CGSize) -> URL? {
    if isLimited {
      return imageURL
    }
    return Self.getImageURL(profileID: userID, pictureMode: pictureMode, size: size)
  }

  static func getImageURL(
    profileID: String,
    pictureMode: PictureMode,
    size: CGSize
  ) -> URL? {
    guard let dependencies = try? Self.getDependencies() else { return nil }

    var queryItems: [ImageURL.QueryItemName: String] = [
      .pictureMode: ImageURL.PictureMode(mode: pictureMode).rawValue,
      .width: String(Int(size.width)),
      .height: String(Int(size.height)),
    ]

    if let token = dependencies.accessTokenProvider.current {
      queryItems[.accessToken] = token.tokenString
    } else if let token = dependencies.settings.clientToken {
      queryItems[.accessToken] = token
    } else {
      print(
        """
        As of Graph API v8.0, profile images may not be retrieved without a token. This can be the current access \
        token from logging in with Facebook or it can be set via the plist or in code. Providing neither will cause \
        this call to return a silhouette image.
        """
      )
    }

    let stringlyKeyedItems = queryItems.reduce(into: [String: String]()) { values, item in
      values[item.key.rawValue] = item.value
    }

    var hostPrefix = ImageURL.hostPrefix
    if _DomainHandler.sharedInstance().isDomainHandlingEnabled() {
      let domainConfig = _DomainConfigurationManager.sharedInstance().cachedDomainConfiguration()
      if let domainHandlingHostPrefix =
        domainConfig.domainInfo?["default_config"]?["default_alternative_domain_prefix"] as? String {
        hostPrefix = domainHandlingHostPrefix
      } else {
        hostPrefix = ImageURL.defaultDomainHandlingHostPrefix
      }
    }
    return try? dependencies.urlHoster.facebookURL(
      hostPrefix: hostPrefix,
      path: "\(profileID)/\(ImageURL.path)",
      queryParameters: stringlyKeyedItems
    )
  }

  private enum ImageURL {
    static let hostPrefix = "graph"
    static let path = "picture"
    static let defaultDomainHandlingHostPrefix = "ep1"

    enum QueryItemName: String {
      case accessToken = "access_token"
      case pictureMode = "type"
      case width
      case height
    }

    enum PictureMode: String {
      case normal
      case square
      case small
      case album
      case large

      init(mode: Profile.PictureMode) {
        switch mode {
        case .normal: self = .normal
        case .square: self = .square
        case .small: self = .small
        case .album: self = .album
        case .large: self = .large
        }
      }
    }
  }
}
