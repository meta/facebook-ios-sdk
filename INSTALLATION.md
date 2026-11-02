# Install the SDK and connect the application lifecycle

Choose one dependency manager for the SDK in an application. Use matching kit
versions, and remove an older manual or aggregate `FacebookSDK` installation
before adding the individual kits. Mixing static and dynamic copies can produce
duplicate symbols or duplicate Objective-C classes.

## Package, pod, and import names

| Feature | Swift Package Manager product / Swift import | CocoaPod / Swift import |
| --- | --- | --- |
| Core and App Events | `FacebookCore` | `FBSDKCoreKit` |
| Login | `FacebookLogin` | `FBSDKLoginKit` |
| Sharing | `FacebookShare` | `FBSDKShareKit` |
| Gaming Services | `FacebookGamingServices` | `FBSDKGamingServicesKit` |
| AEM | `FacebookAEM` | `FBAEMKit` |
| Basic utilities | `FacebookBasics` | `FBSDKCoreKit_Basics` |

Select the products needed by your app; their dependencies are included
automatically. SwiftPM's wrapper modules re-export the underlying SDK modules.
For example, the `FacebookCore` product also exposes `FBSDKCoreKit`.
Objective-C uses the underlying module names, such as `@import FBSDKCoreKit;`,
with either installation method. A type implemented in Swift can still be used
from Objective-C through its module; a legacy per-class header may no longer exist.

## Swift Package Manager

In Xcode, add <https://github.com/meta/facebook-ios-sdk> as a package dependency
and choose a released version. These examples use **19.0.0**. The equivalent
manifest entry pins that tag:

```swift
.package(url: "https://github.com/meta/facebook-ios-sdk", exact: "19.0.0")
```

Alternatively, an “Up to Next Major Version” requirement starting at 19.0.0
accepts compatible 19.x releases, not a future 20.x release. Review the changelog
when changing major versions.

Use a release tag rather than `main` for an app dependency. A version bump on
`main`, such as 19.0.1, can precede publication of the matching binary archives;
the source version alone does not establish that those archives are available.

## CocoaPods

For an app using Core and Login:

```ruby
platform :ios, '15.0'
use_frameworks!

target 'MyApp' do
  pod 'FBSDKCoreKit', '19.0.0'
  pod 'FBSDKLoginKit', '19.0.0'
end
```

Run `pod install` and open the generated `.xcworkspace`. Import `FBSDKCoreKit`
and `FBSDKLoginKit` in Swift, rather than SwiftPM's `FacebookCore` and
`FacebookLogin` wrappers. Do not also add the same SDK with SwiftPM.

## Configure the app

Register the app's bundle identifier in your Meta app settings. Configure
`FacebookAppID`, `FacebookClientToken`, `FacebookDisplayName`, and the callback
URL scheme (`fb` followed by your app ID) in the application's `Info.plist`, as
described in the [iOS getting-started guide](https://developers.facebook.com/docs/ios/getting-started).
For native app switching, include the query schemes required by the selected
features in `LSApplicationQueriesSchemes`: `fbapi` for Facebook and
`fb-messenger-share-api` for Messenger sharing. These are query schemes, not the
app's own `fb<APP_ID>` callback URL scheme.
Do not put an app secret in the client. Installation and callback wiring do not
replace Login permissions, consent, or token-handling requirements.

## SwiftUI lifecycle

This example uses SwiftPM. With CocoaPods, change the import to `FBSDKCoreKit`.
Use the application delegate adapter for startup and **one** URL handler for
incoming URLs:

```swift
import FacebookCore
import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    ApplicationDelegate.shared.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
  }
}

@main
struct MyApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      ContentView()
        .onOpenURL { url in
          let handled = ApplicationDelegate.shared.application(
            UIApplication.shared,
            open: url,
            options: [:]
          )
          if !handled {
            // Route a URL intended for your own app here.
          }
        }
    }
  }
}
```

Do not also forward the same URL from `AppDelegate.application(_:open:options:)`
or a scene delegate when `.onOpenURL` owns delivery. Initialize once during app
startup, not each time a view appears or a scene becomes active.

## UIKit lifecycle alternative

Use the same `AppDelegate` startup method above. For an app with scenes, forward
both cold-launch and later URL contexts through its scene delegate:

```swift
import FBSDKCoreKit
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    forward(connectionOptions.urlContexts)
    // Set up your window as usual.
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    forward(URLContexts)
  }

  private func forward(_ contexts: Set<UIOpenURLContext>) {
    for context in contexts {
      let handled = ApplicationDelegate.shared.application(
        UIApplication.shared,
        open: context.url,
        sourceApplication: context.options.sourceApplication,
        annotation: context.options.annotation
      )
      if !handled {
        // Route a URL intended for your own app here.
      }
    }
  }
}
```

For UIKit apps **without scenes**, forward URLs from
`application(_:open:options:)` instead. The Objective-C equivalent is:

```objc
@import FBSDKCoreKit;

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  return [[FBSDKApplicationDelegate sharedInstance] application:application
                                didFinishLaunchingWithOptions:launchOptions];
}

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
  return [[FBSDKApplicationDelegate sharedInstance] application:application
                                                      openURL:url
                                                      options:options];
}
```

Choose the lifecycle path used by your app; do not install all three URL handlers.
If your existing router handles universal links as `NSUserActivity`, the SDK also
provides `application(_:continue:)`. Forward a given link through one path only.

## Binary compatibility and embedding

The SDK is distributed as prebuilt XCFrameworks. The Swift language mode in a
package or project does not make a binary built by a newer Swift compiler
compatible with every older Xcode. Use an Xcode version supported by the release;
errors naming an unknown Swift type or compatibility library need a toolchain
check before changing linker flags. Version 19 requires iOS 15 or later.
The examples above were built with SDK 19.0.0 and Xcode 27.1.

Current SwiftPM and individual CocoaPods integrations use **dynamic** SDK
frameworks. The final application must embed and sign the required frameworks,
including transitive dependencies such as `FBAEMKit` and `FBSDKCoreKit_Basics`.
Let the dependency manager perform that embedding for the app target. If another
framework depends on the SDK, also ensure the host application's dependency
graph includes the SDK; linking the intermediate framework alone does not place
its dependencies in the app bundle. Check the archived app's `Frameworks` folder
when diagnosing `Library not loaded: @rpath/...` failures.

Do not embed a static archive as a dynamic framework, or add a second manual copy
of an SDK already installed by a dependency manager. A successful simulator
build does not validate device slices, signing, or an App Store update.
