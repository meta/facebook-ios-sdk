/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import ObjectiveC
import UIKit

/**
 An `ApplicationDelegate` is designed to post-process the results from Facebook Login
 or Facebook Dialogs (or any action that requires switching over to the native Facebook
 app or Safari).

 The methods in this class are designed to mirror those in `UIApplicationDelegate`, and you
 should call them in the respective methods in your application delegate implementation.
 */
@objcMembers
@objc(FBSDKApplicationDelegate)
public final class ApplicationDelegate: NSObject {

  var applicationObservers = NSHashTable<FBSDKApplicationObserving>(options: .weakMemory)
  let components: CoreKitComponents
  let configurator: CoreKitConfiguring
  var isAppLaunched = false
  private var hasInitializeBeenCalled = false
  var applicationState = UIApplication.State.active {
    didSet {
      components.appEvents.setApplicationState(applicationState)
    }
  }

  // Schedules SDK setup to run after the first frame is rendered so it does not serialize ahead of
  // the initial render. Overridden in tests to run synchronously.
  @nonobjc
  var scheduleAfterFirstFrame: FirstFrameScheduling = ApplicationDelegate.runAfterFirstFrame

  // Resolves the Login kit's observer for authentication sessions restored at launch. CoreKit cannot import
  // FBSDKLoginKit, so the type is looked up by its Objective-C name. Overridden in tests.
  @nonobjc
  var restoredSessionObserverProvider: () -> _RestoredAuthenticationSessionObserving.Type? = {
    NSClassFromString("FBSDKLimitedLoginRestoredSessionObserver") as? _RestoredAuthenticationSessionObserving.Type
  }

  private static let kitsBitmaskKey = "com.facebook.sdk.kits.bitmask"

  /// Gets the singleton instance.
  @objc(sharedInstance)
  public private(set) static var shared = ApplicationDelegate()

  override convenience init() {
    let components = CoreKitComponents.default
    self.init(components: components, configurator: CoreKitConfigurator(components: components))
  }

  init(components: CoreKitComponents, configurator: CoreKitConfiguring) {
    self.components = components
    self.configurator = configurator
    super.init()
  }

  /**
   Initializes the SDK.

   If you are using the SDK within the context of the `UIApplication` lifecycle, do not use this method.
   Instead use `application(_:didFinishLaunchingWithOptions:)`.

   As part of SDK initialization, basic auto logging of app events will occur, this can be
   controlled via the 'FacebookAutoLogAppEventsEnabled' key in your project's Info.plist file.
   Metadata collection is controlled separately via 'FBSDKAutoLogMetaDataEnabled'.
   */
  public func initializeSDK() {
    initializeSDK(launchOptions: [:], completionBlock: nil)
  }

  func initializeSDK(
    launchOptions: [UIApplication.LaunchOptionsKey: Any]?,
    completionBlock: _DomainConfigurationBlock?
  ) {
    guard !hasInitializeBeenCalled else { return }

    hasInitializeBeenCalled = true

    // DO NOT MOVE THIS CALL
    // Dependencies MUST be configured before they are used
    configurator.performConfiguration()
    initializeTokenCache()
    initializeProfile()
    // Arm the App Events persist-on-close observers synchronously, before SDK setup is deferred
    // past the first frame. This ensures events logged during the deferral window are persisted
    // (and re-sent next launch) rather than lost if the app is closed before doSDKSetup runs.
    components.appEvents.startObservingApplicationStatePersistenceNotifications()
    fetchDomainConfiguration {
      // The completion now fires from the cached/default domain configuration without waiting on
      // the network. Defer SDK setup until after the first frame so it does not serialize ahead
      // of the initial render.
      self.scheduleAfterFirstFrame {
        GraphRequestConnection.setDidFetchDomainConfiguration()
        self.doSDKSetup(launchOptions: launchOptions, completionBlock: completionBlock)
        GraphRequestQueue.sharedInstance().flush() // Flush any queued requests
      }
    }
  }

  private func doSDKSetup(
    launchOptions: [UIApplication.LaunchOptionsKey: Any]?,
    completionBlock: _DomainConfigurationBlock?
  ) {
    logInitialization()
    addObservers()
    components.appEvents.startObservingApplicationLifecycleNotifications()
    _ = application(UIApplication.shared, didFinishLaunchingWithOptions: launchOptions)
    handleDeferredActivationIfNeeded()
    enableInstrumentation()
    enableMetadataCollection()

    logBackgroundRefreshStatus()
    initializeAppLink()
    initializeAEMAutoSetup()

    configureSourceApplication(launchOptions: launchOptions)
    completionBlock?()
  }

  private func initializeAppLink() {
    initializeMeasurementListener()
    logIfAutoAppLinkEnabled()
  }

  private func handleDeferredActivationIfNeeded() {
    // If SDK initialization is deferred until after the applicationDidBecomeActive notification is received,
    // then we need to manually perform this work in case it hasn't happened at all.
    if UIApplication.shared.applicationState == .active {
      applicationDidBecomeActive(nil)
    }
  }

  private func configureSourceApplication(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
    // Set the SourceApplication for time spent data. This is not going to update the value
    // if the app has already launched.
    components.appEvents.setSourceApplication(
      launchOptions?[.sourceApplication] as? String,
      open: launchOptions?[.url] as? URL
    )

    // Register on UIApplicationDidEnterBackgroundNotification events to reset source application data when app backgrounds.
    components.appEvents.registerAutoResetSourceApplication()
    components.internalUtility.validateFacebookReservedURLSchemes()
  }

  private func initializeMeasurementListener() {
    // Register Listener for App Link measurement events
    _MeasurementEventListener(eventLogger: components.appEvents, sourceApplicationTracker: components.appEvents)
      .registerForAppLinkMeasurementEvents()
  }

  private func initializeAEMAutoSetup() {
    let flag = components.infoDictionaryProvider.fb_object(forInfoDictionaryKey: "FBSDKAemAutoSetupEnabled") as? Bool
    let enabled = flag ?? true
    if !enabled {
      components.aemManager.logAutoSetupStatus(false, source: "client_flag")
    }
    if enabled, components.featureChecker.isEnabled(.aemAutoSetup) {
      components.aemManager.enable(
        components.featureChecker.isEnabled(.aemAutoSetupProxy)
      )
    }
  }

  private func logBackgroundRefreshStatus() {
    components.backgroundEventLogger.logBackgroundRefreshStatus(UIApplication.shared.backgroundRefreshStatus)
  }

  private func logInitialization() {
    components.settings.logIfSDKSettingsChanged()
    components.settings.recordInstall()
    validateAppConfiguration()
  }

  /// Surfaces a clear developer-facing warning when the App ID or Client Token is
  /// missing, empty, or whitespace-only at initialization, rather than letting the
  /// misconfiguration surface later as opaque authentication / Graph API failures
  /// (see GitHub issue #3639). This only logs via `.developerErrors` and never
  /// aborts initialization. Note: apps that configure the App ID / Client Token
  /// *after* `initializeSDK()` runs will see one spurious `.developerErrors` entry
  /// at launch (logging is on by default); the warning is diagnostic only and does
  /// not affect functionality.
  private func validateAppConfiguration() {
    let appID = components.settings.appID
    if (appID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true {
      _Logger.singleShotLogEntry(
        .developerErrors,
        logEntry: "Invalid Facebook App ID configuration: the App ID is missing or empty. Set "
          + "FacebookAppID in your Info.plist (or Settings.shared.appID) before using the SDK."
      )
    }

    let clientToken = components.settings.clientToken
    if (clientToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true {
      _Logger.singleShotLogEntry(
        .developerErrors,
        logEntry: "Invalid Facebook Client Token configuration: the Client Token is missing or empty. Set "
          + "FacebookClientToken in your Info.plist (or Settings.shared.clientToken) before using the SDK."
      )
    }
  }

  private func enableInstrumentation() {
    components.featureChecker.check(.instrument) { enabled in
      if enabled {
        _InstrumentManager.shared.enable()
      }
    }
  }

  // Not app event auto-logging, so deliberately not gated on `isAutoLogAppEventsEnabled`.
  private func enableMetadataCollection() {
    purgeCollectedDataIfOptedOut()

    // Runs even when opted out, so the GateKeeper stays loaded for a later mid-session opt-in.
    components.featureChecker.check(.metadataCollection) { enabled in
      guard enabled else { return }

      self.installMetadataCollectionIfPermitted()
    }
  }

  /// Drops app link URLs an earlier launch cached before the developer opted out. Deliberately
  /// outside the GateKeeper check: the persisted data outlives both the launch and the flag.
  func purgeCollectedDataIfOptedOut() {
    guard !components.settings.isMetaDataCollectionEnabled else { return }

    _AppLinkURLCache.shared.clearCachedURLs()
  }

  /// Idempotent, so a mid-session opt-in can call it again. An app that has opted out is never swizzled.
  func installMetadataCollectionIfPermitted() {
    guard components.settings.isMetaDataCollectionEnabled else { return }

    _ScreenTitleObserver.shared.startObserving()
    setupOutboundURLSwizzle()
  }

  // Install the swizzle at most once — re-running enableMetadataCollection would
  // otherwise stack blocks and run each outbound open through the cache multiple times.
  // Only ever read/written on the main thread, which gives it dispatch_once semantics.
  private static var hasInstalledOutboundURLSwizzle = false

  /// Installs the `openURL:options:completionHandler:` swizzle. Hops to the main thread and is a
  /// no-op after the first call, so it is safe to invoke from any thread any number of times.
  private func setupOutboundURLSwizzle() {
    runOnMainThread { [weak self] in
      guard
        let self = self,
        !Self.hasInstalledOutboundURLSwizzle
      else { return }

      Self.hasInstalledOutboundURLSwizzle = true
      self.installOutboundURLSwizzle()
    }
  }

  private func installOutboundURLSwizzle() {
    let selector = NSSelectorFromString("openURL:options:completionHandler:")
    guard let method = class_getInstanceMethod(UIApplication.self, selector) else { return }

    let originalIMP = method_getImplementation(method)
    typealias OpenURLIMP = @convention(c) (AnyObject, Selector, NSURL, NSDictionary?, ((Bool) -> Void)?) -> Void
    typealias OpenURLBlock = @convention(block) (AnyObject, NSURL, NSDictionary?, ((Bool) -> Void)?) -> Void
    // The swizzle cannot be uninstalled and the client flag is runtime-mutable, so the cache
    // re-checks both gates on every call.
    let block: OpenURLBlock = { receiver, url, options, completion in
      _AppLinkURLCache.shared.cacheOutboundURL(url as URL)
      unsafeBitCast(originalIMP, to: OpenURLIMP.self)(receiver, selector, url, options, completion)
    }
    method_setImplementation(method, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)))
  }

  private func runOnMainThread(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  private func addObservers() {
    components.notificationCenter.fb_addObserver(
      self,
      selector: #selector(applicationDidEnterBackground(_:)),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    components.notificationCenter.fb_addObserver(
      self,
      selector: #selector(applicationDidBecomeActive(_:)),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    components.notificationCenter.fb_addObserver(
      self,
      selector: #selector(applicationWillResignActive(_:)),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )

    addObserver(_BridgeAPI.shared)
  }

  // MARK: - UIApplicationDelegate-like interface

  /**
   Call this method from the `UIApplicationDelegate.application(_:continue:restorationHandler:)` method
   of your application delegate. It should be invoked in order to properly process the web URL (universal link)
   once the end user is redirected to your app.

   - Parameters:
     - application: The application as passed to `UIApplicationDelegate.application(_:continue:restorationHandler:).
     - userActivity: The user activity as passed to `UIApplicationDelegate.application(_:continue:restorationHandler:)`.

   - Returns: `true` if the URL was intended for the Facebook SDK, `false` if not.
   */
  @discardableResult
  @objc(application:continueUserActivity:)
  public func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity
  ) -> Bool {
    guard
      userActivity.activityType == NSUserActivityTypeBrowsingWeb,
      let url = userActivity.webpageURL
    else { return false }

    return self.application(application, open: url, options: [:])
  }

  /**
   Call this method from the `UIApplicationDelegate.application(_:open:options:)` method
   of your application delegate. It should be invoked for the proper processing of responses during interaction
   with the native Facebook app or Safari as part of an SSO authorization flow or Facebook dialogs.

   - Parameters:
     - application: The application as passed to `UIApplicationDelegate.application(_:open:options:)`.
     - url: The URL as passed to `UIApplicationDelegate.application(_:open:options:)`.
     - options: The options dictionary as passed to `UIApplicationDelegate.application(_:open:options:)`.

   - Returns: `true` if the URL was intended for the Facebook SDK, `false` if not.
   */
  @discardableResult
  @objc(application:openURL:options:)
  public func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any]
  ) -> Bool {
    self.application(
      application,
      open: url,
      sourceApplication: options[.sourceApplication] as? String,
      annotation: options[.annotation]
    )
  }

  /**
   Call this method from the `UIApplicationDelegate.application(_:openL:sourceApplication:annotation:)` method
   of your application delegate. It should be invoked for the proper processing of responses during interaction
   with the native Facebook app or Safari as part of an SSO authorization flow or Facebook dialogs.

   - Parameters:
     - application: The application as passed to `UIApplicationDelegate.application(_:open:sourceApplication:annotation:)`.
     - url: The URL as passed to `UIApplicationDelegate.application(_:open:sourceApplication:annotation:)`.
     - sourceApplication: The source application as passed to `UIApplicationDelegate.application(_:open:sourceApplication:annotation:)`.
     - annotation: The annotation as passed to `UIApplicationDelegate.application(_:open:sourceApplication:annotation:)`.

   - Returns: `true` if the URL was intended for the Facebook SDK, `false` if not.
   */
  @discardableResult
  @objc(application:openURL:sourceApplication:annotation:)
  public func application(
    _ application: UIApplication,
    open url: URL,
    sourceApplication: String?,
    annotation: Any?
  ) -> Bool {
    components.appEvents.setSourceApplication(sourceApplication, open: url)
    // Unguarded: the cache gates itself, which is what also covers the `FBSDKAEMManager` writers.
    _AppLinkURLCache.shared.cacheInboundURL(url)

    components.featureChecker.check(.AEM) { enabled in
      guard enabled else { return }

      let featureChecker = self.components.featureChecker

      AEMReporter.setCatalogMatchingEnabled(featureChecker.isEnabled(.aemCatalogMatching))
      AEMReporter.setConversionFilteringEnabled(featureChecker.isEnabled(.aemConversionFiltering))
      AEMReporter.setAdvertiserRuleMatchInServerEnabled(featureChecker.isEnabled(.aemAdvertiserRuleMatchInServer))
      AEMReporter.enable()
      AEMReporter.handle(url)
    }

    var handled = false
    applicationObservers.allObjects.forEach { observer in
      let observerHandled = observer.application?(
        application,
        open: url,
        sourceApplication: sourceApplication,
        annotation: annotation
      )

      if observerHandled ?? false {
        handled = true
      }
    }

    components.appEventsUtility.saveCampaignIDs(url)
    if handled {
      return true
    } else {
      logIfAppLinkEvent(url: url)
      return false
    }
  }

  // MARK: Finish Launching

  /**
   Call this method from the `UIApplicationDelegate.application(_:didFinishLaunchingWithOptions:)` method
   of your application delegate. It should be invoked for the proper use of the Facebook SDK.
   As part of SDK initialization, basic auto-logging of app events will occur; this can be
   controlled via the `FacebookAutoLogAppEventsEnabled` key in the project's Info.plist file.
   Metadata collection is controlled separately via `FBSDKAutoLogMetaDataEnabled`.

   - Parameters:
     - application: The application as passed to `UIApplicationDelegate.application(_:didFinishLaunchingWithOptions:)`.
     - launchOptions: The launch options as passed to `UIApplicationDelegate.application(_:didFinishLaunchingWithOptions:)`.

   - Returns: `true`
   */
  @discardableResult
  public func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    guard
      !isAppLaunched,
      !hasInitializeBeenCalled
    else { return false }

    initializeSDK(launchOptions: launchOptions) {
      self.isAppLaunched = true

      self.fetchServerConfiguration()

      if self.components.settings.isAutoLogAppEventsEnabled {
        self.logSDKInitialize()
      }

      self.checkAuthentication()
      _ = self.notifyLaunchObservers(application: application, launchOptions: launchOptions)
    }
    return true
  }

  private func initializeTokenCache() {
    components.accessTokenWallet.current = components.accessTokenWallet.tokenCache?.accessToken
    components.authenticationTokenWallet.current = components.authenticationTokenWallet.tokenCache?.authenticationToken
  }

  private func fetchServerConfiguration() {
    components.serverConfigurationProvider.loadServerConfiguration(completionBlock: nil)
  }

  private func fetchDomainConfiguration(completionBlock: _DomainConfigurationBlock?) {
    _DomainHandler.sharedInstance().loadDomainConfiguration(completionBlock: completionBlock)
  }

  @nonobjc
  static func runAfterFirstFrame(_ work: @escaping () -> Void) {
    // An app launched into the background never renders a first frame, so there is nothing to defer
    // to — run setup immediately rather than stalling it until a frame that never comes.
    if UIApplication.shared.applicationState == .background {
      work()
      return
    }
    FirstFrameScheduler.schedule(work)
  }

  private func initializeProfile() {
    components.profileSetter.current = components.profileSetter.fetchCachedProfile()
  }

  private func checkAuthentication() {
    if components.authenticationTokenWallet.current != nil {
      restoredSessionObserverProvider()?.didRestoreAuthenticationSession()
    }
    _AuthenticationStatusUtility.checkAuthenticationStatus()
  }

  private func notifyLaunchObservers(
    application: UIApplication,
    launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    var someObserverHandledLaunch = false
    applicationObservers.allObjects.forEach { observer in
      let observerHandled = observer.application?(
        application,
        didFinishLaunchingWithOptions: launchOptions
      )

      if observerHandled ?? false {
        someObserverHandledLaunch = true
      }
    }

    return someObserverHandledLaunch
  }

  // MARK: Entering Background

  func applicationDidEnterBackground(_ notification: Notification) {
    applicationState = .background
    applicationObservers.allObjects.forEach { observer in
      observer.applicationDidEnterBackground?(notification.object as? UIApplication)
    }
    IAPTransactionCache.shared.trimIfNeeded()
    if IAPDedupeProcessor.shared.isEnabled {
      IAPDedupeProcessor.shared.saveNonProcessedEvents()
    }
  }

  func applicationDidBecomeActive(_ notification: Notification?) {
    applicationState = .active

    // Auto log basic events in case auto-logging of app events is enabled
    if components.settings.isAutoLogAppEventsEnabled {
      components.appEvents.activateApp()
    }

    if components.featureChecker.isEnabled(.skAdNetworkV4) {
      components.skAdNetworkReporterV2?.checkAndRevokeTimer()
    } else {
      components.skAdNetworkReporter?.checkAndRevokeTimer()
    }

    applicationObservers.allObjects.forEach { observer in
      observer.applicationDidBecomeActive?(notification?.object as? UIApplication)
    }
    Task {
      await IAPTransactionObserver.shared.observeNewTransactions()
    }
  }

  func applicationWillResignActive(_ notification: Notification) {
    applicationState = .inactive
    applicationObservers.allObjects.forEach { observer in
      observer.applicationWillResignActive?(notification.object as? UIApplication)
    }
  }

  // MARK: - Internal Methods

  // MARK: FBSDKApplicationObserving

  /**
   Adds an observer that will be informed about application lifecycle events.

   - Note: Observers are weakly held
   */
  public func addObserver(_ observer: FBSDKApplicationObserving) {
    applicationObservers.add(observer)
  }

  /// Removes an observer so that it will no longer be informed about application lifecycle events.
  public func removeObserver(_ observer: FBSDKApplicationObserving) {
    applicationObservers.remove(observer)
  }

  private func logIfAppLinkEvent(url: URL) {
    guard let query = url.query else { return }

    let parameters = BasicUtility.dictionary(withQueryString: query)
    guard
      let appLinkDataString = parameters["al_applink_data"],
      let rawData = appLinkDataString.data(using: .utf8),
      let appLinkData = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any]
    else { return }

    var logData = [AppEvents.ParameterName: Any]()

    let targetURLString = appLinkData["target_url"] as? String
    if let targetURL = targetURLString.flatMap(URL.init(string:)) {
      logData[.targetURL] = targetURL.absoluteString
      logData[.targetURLHost] = targetURL.host
    }

    if let referrerData = appLinkData["referer_data"] as? [String: Any] {
      logData[.referralTargetURL] = referrerData["target_url"]
      logData[.referralURL] = referrerData["url"]
      logData[.referralAppName] = referrerData["app_name"]
    }

    logData[.inputURL] = url.absoluteString
    logData[.inputURLScheme] = url.scheme

    components.appEvents.logInternalEvent(
      .appLinkInboundEvent,
      parameters: logData,
      isImplicitlyLogged: true
    )
  }

  func logSDKInitialize() {
    let frameworkFlagMap: [String: AppEvents.ParameterName] = [
      "FBSDKLoginManager": .isLoginLibraryIncluded,
      "FBSDKAutoLog": .isMarketingLibraryIncluded,
      "FBSDKMessengerButton": .isMessengerLibraryIncluded,
      "FBSDKPlacesManager": .isPlacesLibraryIncluded,
      "FBSDKShareDialog": .isShareLibraryIncluded,
      "FBSDKTVInterfaceFactory": .isTVLibraryIncluded,
    ]

    var bitmask = 0
    var bit = 0
    var parameters: [AppEvents.ParameterName: Any] = [.isCoreKitIncluded: 1]

    frameworkFlagMap.forEach { className, parameterName in
      if objc_lookUpClass(className) != nil {
        parameters[parameterName] = 1
        bitmask |= 1 << bit
      }

      bit += 1
    }

    let existingBitmask = components.defaultDataStore.fb_integer(forKey: Self.kitsBitmaskKey)
    if existingBitmask != bitmask {
      components.defaultDataStore.fb_setInteger(bitmask, forKey: Self.kitsBitmaskKey)
      components.appEvents.logInternalEvent(
        .initializeSDK,
        parameters: parameters,
        isImplicitlyLogged: false
      )
    }
  }

  private func logIfAutoAppLinkEnabled() {
    let enabled = components.infoDictionaryProvider.fb_object(forInfoDictionaryKey: "FBSDKAutoAppLinkEnabled") as? Bool
    if enabled ?? false {
      var parameters = [AppEvents.ParameterName: Any]()
      if !AppLinkUtility.isMatchURLScheme("fb\(components.settings.appID ?? "nil")") {
        let warning = "You haven't set the Auto App Link URL scheme: fb<YOUR APP ID>"
        parameters[.schemeWarning] = warning
        _Logger.singleShotLogEntry(.developerErrors, logEntry: warning)
      }

      components.appEvents.logInternalEvent(
        .autoAppLink,
        parameters: parameters,
        isImplicitlyLogged: true
      )
    }
  }

  // MARK: - Testability

  #if DEBUG
  func resetHasInitializeBeenCalled() {
    hasInitializeBeenCalled = false
  }

  func resetApplicationObserverCache() {
    applicationObservers = NSHashTable<FBSDKApplicationObserving>(options: .weakMemory)
  }
  #endif
}

// swiftformat:disable:next extensionaccesscontrol
fileprivate extension AppEvents.Name {
  static let appLinkInboundEvent = Self("fb_al_inbound")
  static let autoAppLink = Self("fb_auto_applink")
}

// swiftformat:disable:next extensionaccesscontrol
fileprivate extension AppEvents.ParameterName {
  static let targetURL = Self("targetURL")
  static let targetURLHost = Self("targetURLHost")
  static let referralTargetURL = Self("referralTargetURL")
  static let referralURL = Self("referralURL")
  static let referralAppName = Self("referralAppName")
  static let inputURL = Self("inputURL")
  static let inputURLScheme = Self("inputURLScheme")
  static let isCoreKitIncluded = Self("core_lib_included")
  static let isLoginLibraryIncluded = Self("login_lib_included")
  static let isMarketingLibraryIncluded = Self("marketing_lib_included")
  static let isMessengerLibraryIncluded = Self("messenger_lib_included")
  static let isPlacesLibraryIncluded = Self("places_lib_included")
  static let isShareLibraryIncluded = Self("share_lib_included")
  static let isTVLibraryIncluded = Self("tv_lib_included")
  static let schemeWarning = Self("SchemeWarning")
}

/// Schedules a block of work to run after the first frame is rendered. Injectable so tests can run
/// the work synchronously.
typealias FirstFrameScheduling = (@escaping () -> Void) -> Void

/// Runs a block once, after the next rendered frame. A one-shot `CADisplayLink` fires on the next
/// display refresh; a fallback timer guarantees the block still runs if no frame is produced, so
/// SDK setup is never dropped.
private final class FirstFrameScheduler {
  private var displayLink: CADisplayLink?
  private var work: (() -> Void)?

  private static let fallbackDelay: TimeInterval = 1.0

  static func schedule(_ work: @escaping () -> Void) {
    let scheduler = FirstFrameScheduler()
    scheduler.work = work

    // The display link retains `scheduler`, and the run loop retains the link once added, so the
    // scheduler stays alive until it fires and invalidates the link.
    let displayLink = CADisplayLink(target: scheduler, selector: #selector(handleFrame))
    scheduler.displayLink = displayLink
    displayLink.add(to: .main, forMode: .common)

    DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) { [weak scheduler] in
      scheduler?.fire()
    }
  }

  @objc private func handleFrame() {
    fire()
  }

  private func fire() {
    guard let work = work else { return }

    self.work = nil
    displayLink?.invalidate()
    displayLink = nil
    work()
  }
}
