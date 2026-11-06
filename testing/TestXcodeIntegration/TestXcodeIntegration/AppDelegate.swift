/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import UIKit

func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {ApplicationDelegate.shared.application(application, didFinishLaunchingWithOptions: launchOptions)
return true
}
import FBSDKGamingServicesKit
import FBSDKLoginKit
import FBSDKShareKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
}open -a Xcode Podfile

pod 'FBSDKCoreKit', '~> 8.0.0'
pod 'FBSDKLoginKit', '~> 8.0.0'
pod 'FBSDKShareKit', '~> 8.0.0'
pod 'FBSDKGamingServicesKit', '~> 8.0.0'

/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import UIKit
import FBSDKCoreKit
import FBSDKGamingServicesKit
import FBSDKLoginKit
import FBSDKShareKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        ApplicationDelegate.shared.application(application, didFinishLaunchingWithOptions: launchOptions)
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }pod 'FBSDKCoreKit', '~> 8.0.0'
  pod 'FBSDKLoginKit', '~> 8.0.0'
  pod 'FBSDKShareKit', '~> 8.0.0'
  pod 'FBSDKGamingServicesKit', '~> 8.0.0'
}
/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import UIKit
import FBSDKCoreKit
import FBSDKGamingServicesKit
import FBSDKLoginKit
import FBSDKShareKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        ApplicationDelegate.shared.application(application, didFinishLaunchingWithOptions: launchOptions)
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
}
# Abre el archivo Podfile en Xcode
open -a Xcode Podfile

# Añade las dependencias de Facebook SDK en el Podfile
pod 'FBSDKCoreKit', '~> 8.0.0'
pod 'FBSDKLoginKit', '~> 8.0.0'
pod 'FBSDKShareKit', '~> 8.0.0'
pod 'FBSDKGamingServicesKit', '~> 8.0.0'
# Uncomment the next line to define a global platform for your projectplatform :ios, '9.0'

target 'YourAppTarget' do
Comment the next line if you're not using Swift and don't want to use dynamic frameworks
use_frameworks!

Pods for YourAppTarget
pod 'FBSDKCoreKit', '~> 8.0.0'
pod 'FBSDKLoginKit', '~> 8.0.0'
pod 'FBSDKShareKit', '~> 8.0.0'
pod 'FBSDKGamingServicesKit', '~> 8.0.0'

end
