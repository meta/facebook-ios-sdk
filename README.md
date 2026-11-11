# Facebook SDK for iOS

[![Platforms](https://img.shields.io/badge/platform-iOS-lightgrey.svg)](https://developers.facebook.com/docs/ios)

[![Swift Package Manager compatible](https://img.shields.io/badge/SPM-compatible-4BC51D.svg?style=flat)](https://swift.org/package-manager/)
[![Carthage compatible](https://img.shields.io/badge/Carthage-compatible-4BC51D.svg?style=flat)](https://github.com/Carthage/Carthage)

This open-source library allows you to integrate Facebook into your iOS app.

Learn more about the provided samples, documentation, integrating the SDK into your app, accessing source code, and more
at https://developers.facebook.com/docs/ios

Please take a moment and [subscribe to releases](https://docs.github.com/en/enterprise/2.15/user/articles/watching-and-unwatching-repositories) so that you can be notified about new features, deprecations, and critical fixes. To see information about the latest release, consult our [changelog](CHANGELOG.md).

|:warning: Be Advised :warning:|
|:---|
|<p>**CocoaPods is no longer supported, starting with v19.0.1.** The CocoaPods Specs repo is [becoming read-only](https://blog.cocoapods.org/CocoaPods-Specs-Repo/), so v19.0.0 is the last version of the Facebook SDK published to CocoaPods. Future releases, including bug fixes, will not be published to CocoaPods.</p><p>Existing CocoaPods integrations will keep working on v19.0.0 and earlier, but will not receive updates. Please migrate to Swift Package Manager. See [Migrating from CocoaPods](#migrating-from-cocoapods).</p>|

|:warning: Be Advised :warning:|
|:---|
|<p>We have begun rewriting the iOS SDK in Swift in order to modernize the code base.</p><p>Please monitor the changelog for updates to existing interfaces but keep in mind that some interfaces will be unstable during this process. As such, updating to a minor version may introduce compilation issues related to language interoperability. Using symbols now defined in Swift may require using `@import` syntax from Objective-C and using C++ will likely require workarounds like creating wrappers in Objective-C.</p>Please bear with us as we work towards providing an improved experience for integrating with the Facebook platform.|

## TRY IT OUT

### Swift Package Manager

1. In Xcode, select File > Add Package Dependencies.
1. Enter the URL for this repository: `https://github.com/meta/facebook-ios-sdk`
1. Select the `Facebook`-prefixed libraries you want to use
1. Check-out the tutorials available online at: <https://developers.facebook.com/docs/ios/getting-started>
1. Start coding! Visit <https://developers.facebook.com/docs/ios> for tutorials and reference documentation.

### Migrating from CocoaPods

CocoaPods is not supported starting with v19.0.1. To keep receiving updates, move to Swift Package Manager:

1. Remove the Facebook SDK pods (`FBSDKCoreKit`, `FBSDKLoginKit`, etc.) from your `Podfile`.
1. Run `pod install`. If the Facebook SDK was your only pod, run `pod deintegrate` instead and open your `.xcodeproj` from now on instead of the `.xcworkspace`.
1. In Xcode, select File > Add Package Dependencies and enter `https://github.com/meta/facebook-ios-sdk`.
1. Choose the "Up to Next Major Version" rule, starting from `19.0.1`.
1. Add the libraries that match the pods you removed:

   | CocoaPods pod | Swift Package Manager library |
   |:---|:---|
   | `FBSDKCoreKit` | `FacebookCore` |
   | `FBSDKLoginKit` | `FacebookLogin` |
   | `FBSDKShareKit` | `FacebookShare` |
   | `FBSDKGamingServicesKit` | `FacebookGamingServices` |
   | `FBAEMKit` | `FacebookAEM` |
   | `FBSDKCoreKit_Basics` | `FacebookBasics` |

1. Clean the build folder (Product > Clean Build Folder) and rebuild.

Your existing imports, such as `import FBSDKCoreKit` and `@import FBSDKCoreKit;`, do not need to change.

If you can't use Swift Package Manager, you can download prebuilt XCFrameworks for each version from the [Releases](https://github.com/meta/facebook-ios-sdk/releases) page and add them to your project manually.

## FRAMEWORK ARCHITECTURES

Source builds use standard architectures (`ARCHS = $(ARCHS_STANDARD)` in `Configurations/Common.xcconfig` and `Configurations/FacebookSDK-Project.xcconfig`). A default device build is `arm64`. Simulator builds keep the standard simulator architectures selected by Xcode.

To include an `arm64e` device slice, rebuild with an explicit override:

```sh
xcodebuild ... ARCHS="arm64 arm64e"
```

Rebuilding with that override produces new local binaries. The XCFrameworks already published for remote Swift Package Manager stay at the versions attached to the current release. Remote package users receive the updated architecture layout after maintainers rebuild and publish new release artifacts.

Check a locally assembled XCFramework with:

```sh
./scripts/test_framework_architectures.py path/to/Kit.xcframework
```

The checker requires each iOS device library to be exactly `arm64`, so an opt-in `arm64`/`arm64e` build fails this default check. Simulator libraries are classified from the XCFramework metadata and must match the architectures recorded there.

## iOS 14 CHANGES

### Data Disclosure

Due to the release of iOS 14, tracking events that your app collects and sends to Facebook may require you to disclosed these data types in the App Store Connect questionnaire. It is your responsibility to ensure this is reflected in your application’s privacy policy. Visit our blogpost for information on affected Facebook SDKs, APIs, and products and the Apple App Store Privacy Details article to learn more about the data types you will need to disclose.

link to FB blogpost https://developers.facebook.com/blog/post/2020/10/22/preparing-for-apple-app-store-data-disclosure-requirements/

apple store details https://developer.apple.com/app-store/app-privacy-details/

## FEATURES

- Login - <https://developers.facebook.com/docs/facebook-login>
- Sharing - <https://developers.facebook.com/docs/sharing>
- App Links - <https://developers.facebook.com/docs/applinks>
- Graph API - <https://developers.facebook.com/docs/ios/graph>
- Analytics - <https://developers.facebook.com/docs/analytics>

## GIVE FEEDBACK

Please report bugs or issues to our designated developer support team -- <https://developers.facebook.com/support/bugs/> -- as this will help us resolve them more quickly.

You can also visit our [Facebook Developer Community Forum](https://developers.facebook.com/community/),
join the [Facebook Developers Group on Facebook](https://www.facebook.com/groups/fbdevelopers/),
ask questions on [Stack Overflow](https://stackoverflow.com/questions/tagged/facebook-ios-sdk),
or open an issue in this repository.

## CONTRIBUTE

Facebook welcomes contributions to our SDKs. Please see the [CONTRIBUTING](CONTRIBUTING.md) file.

## LICENSE

See the [LICENSE](LICENSE) file.

Copyright © Meta Platforms, Inc

## SECURITY POLICY

See the [SECURITY POLICY](SECURITY.md) for more info on our bug bounty program.

## DEVELOPER TERMS

- By enabling Facebook integrations, including through this SDK, you can share information with Facebook, including
  information about people’s use of your app. Facebook will use information received in accordance with our
  [Data Use Policy](https://www.facebook.com/about/privacy/), including to provide you with insights about the
  effectiveness of your ads and the use of your app. These integrations also enable us and our partners to serve ads on
  and off Facebook.
- You may limit your sharing of information with us by updating the Insights control in the developer tool
  `https://developers.facebook.com/apps/{app_id}/settings/advanced`.
- If you use a Facebook integration, including to share information with us, you agree and confirm that you have
  provided appropriate and sufficiently prominent notice to and obtained the appropriate consent from your users
  regarding such collection, use, and disclosure (including, at a minimum, through your privacy policy). You further
  agree that you will not share information with us about children under the age of 13.
- You agree to comply with all applicable laws and regulations and also agree to our Terms
  <https://www.facebook.com/policies/>, including our Platform Policies <https://developers.facebook.com/policy/> and
  Advertising Guidelines, as applicable <https://www.facebook.com/ad_guidelines.php>.

By using the Facebook SDK for iOS you agree to these terms.
