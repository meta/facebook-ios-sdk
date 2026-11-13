/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AuthenticationServices
import SafariServices

/**
 Internal Type exposed to facilitate transition to Swift.
 API Subject to change or removal without warning. Do not use.

 @warning INTERNAL - DO NOT USE
 */
public final class _BridgeAPI: NSObject,
  FBSDKApplicationObserving,
  URLOpener,
  BridgeAPIRequestOpening,
  _ContainerViewControllerDelegate,
  SFSafariViewControllerDelegate {

  private enum Values {
    static let authenticationSessionErrorDomain = "com.apple.AuthenticationServices.WebAuthenticationSession"
    static let sourceApplication = "com.apple"
    static let bridgeResponseHost = "bridge"
  }

  let logger: _Logger
  let urlOpener: _InternalURLOpener
  let bridgeAPIResponseFactory: BridgeAPIResponseCreating
  let appURLSchemeProvider: AppURLSchemeProviding
  let errorFactory: ErrorCreating
  var pendingRequest: BridgeAPIRequestProtocol?
  var pendingRequestCompletionBlock: BridgeAPIResponseBlock?
  var pendingURLOpener: URLOpening?
  var authenticationSession: AuthenticationSessionProtocol?
  var authenticationSessionCompletionHandler: AuthenticationCompletionHandler?
  var authenticationSessionState = AuthenticationSessionState.none
  var isExpectingBackground = false
  var safariViewController: SFSafariViewController?
  var isDismissingSafariViewController = false
  var isActive = false

  public static let shared = _BridgeAPI(
    logger: _Logger(loggingBehavior: .developerErrors),
    urlOpener: CoreUIApplication.shared,
    bridgeAPIResponseFactory: _BridgeAPIResponseFactory(),
    appURLSchemeProvider: InternalUtility.shared,
    errorFactory: _ErrorFactory()
  )

  init(
    logger: _Logger,
    urlOpener: _InternalURLOpener,
    bridgeAPIResponseFactory: BridgeAPIResponseCreating,
    appURLSchemeProvider: AppURLSchemeProviding,
    errorFactory: ErrorCreating
  ) {
    self.logger = logger
    self.urlOpener = urlOpener
    self.bridgeAPIResponseFactory = bridgeAPIResponseFactory
    self.appURLSchemeProvider = appURLSchemeProvider
    self.errorFactory = errorFactory
  }

  private func updateAuthStateIfSystemAlertToUseWebAuthFlowPresented() {
    if authenticationSession != nil,
       authenticationSessionState == .started {
      authenticationSessionState = .showAlert
    }
  }

  private func updateAuthStateIfSystemCancelAuthSession() {
    if authenticationSession != nil,
       authenticationSessionState == .showAlert {
      authenticationSessionState = .canceledBySystem
    }
  }

  private var isRequestingWebAuthenticationSession: Bool {
    ![.none, .canceledBySystem].contains(authenticationSessionState)
  }

  func bridgeAPIRequestCompletionBlock(
    request: BridgeAPIRequestProtocol,
    completion completionBlock: @escaping BridgeAPIResponseBlock
  ) -> SuccessBlock {
    { [self] openedURL, _ in
      guard !openedURL else { return }

      pendingRequest = nil
      pendingRequestCompletionBlock = nil
      let openedURLError: Error

      if request.scheme.hasPrefix(URLSchemeEnum.http.rawValue) {
        openedURLError = errorFactory.error(
          code: CoreError.errorBrowserUnavailable.rawValue,
          message: "the app switch failed because the browser is unavailable",
          underlyingError: nil
        )
      } else {
        openedURLError = errorFactory.error(
          code: CoreError.errorAppVersionUnsupported.rawValue,
          message: "the app switch failed because the destination app is out of date",
          underlyingError: nil
        )
      }
      let response = bridgeAPIResponseFactory.createResponse(request: request, error: openedURLError)
      completionBlock(response)
    }
  }

  private func presentSafariViewController(
    with url: URL,
    in container: _ContainerViewController,
    from parent: UIViewController
  ) {
    let safariController = SFSafariViewController(url: url)
    safariViewController = safariController

    // Disable dismissing with edge pan gesture
    safariController.modalPresentationStyle = .overFullScreen
    safariController.delegate = self
    container.displayChildController(safariController)
    parent.present(container, animated: true)
  }

  func openURLWithAuthenticationSession(url: URL) {
    if let session = authenticationSession {
      // swiftlint:disable:next line_length
      logger.logEntry("There is already a request for authenticated session. Cancelling active authentication session before starting the new one.")
      session.cancel()
    }

    authenticationSession = ASWebAuthenticationSession(
      url: url,
      callbackURLScheme: appURLSchemeProvider.appURLScheme,
      completionHandler: authenticationSessionCompletionHandler ?? { [weak self] _, _ in
        self?.clearSession()
      }
    )

    authenticationSession?.presentationContextProvider = self

    authenticationSessionState = .started
    _ = authenticationSession?.start()
  }

  func setSessionCompletionHandler(calling handler: @escaping SuccessBlock) {
    authenticationSessionCompletionHandler = { [weak self] potentialURL, potentialError in
      let didSucceed = (potentialError == nil && potentialURL != nil)
      handler(didSucceed, potentialError)

      if let url = potentialURL,
         didSucceed {
        _ = self?.application(
          UIApplication.shared,
          open: url,
          sourceApplication: Values.sourceApplication,
          annotation: nil
        )
      }
      self?.clearSession()
    }
  }

  func clearSession() {
    authenticationSession = nil
    authenticationSessionCompletionHandler = nil
    authenticationSessionState = .none
  }

  public func viewControllerDidDisappear(
    _ viewController: _ContainerViewController,
    animated: Bool
  ) {
    if let safariViewController = safariViewController {
      logger.logEntry(
        """
        **ERROR**:
        The SFSafariViewController's parent view controller was dismissed.
        This can happen if you are triggering login from a UIAlertController. Instead, make sure your topmost view \
        controller will not be prematurely dismissed.
        """
      )
      safariViewControllerDidFinish(safariViewController)
    }
  }

  func handleBridgeAPIResponse(
    url responseURL: URL,
    sourceApplication: String?
  ) -> Bool {
    let request = pendingRequest
    let completionBlock = pendingRequestCompletionBlock
    pendingRequest = nil
    pendingRequestCompletionBlock = nil

    guard
      responseURL.scheme == appURLSchemeProvider.appURLScheme,
      responseURL.host == Values.bridgeResponseHost,
      let request = request
    else {
      return false
    }

    guard let completionBlock = completionBlock else {
      return true
    }

    do {
      let response = try bridgeAPIResponseFactory.createResponse(
        request: request,
        responseURL: responseURL,
        sourceApplication: sourceApplication
      )
      completionBlock(response)
      return true
    } catch let error as NSError where error.code == CoreError.errorBridgeAPIResponse.rawValue {
      return false
    } catch {
      completionBlock(
        bridgeAPIResponseFactory.createResponse(request: request, error: error)
      )
      return true
    }
  }

  func cancelBridgeRequest() {
    let request = pendingRequest
    let completionBlock = pendingRequestCompletionBlock
    pendingRequest = nil
    pendingRequestCompletionBlock = nil

    if let request = request {
      completionBlock?(BridgeAPIResponse(cancelledWith: request))
    }
  }
}

// MARK: FBSDKApplicationObserving Conformance

extension _BridgeAPI {
  public func applicationWillResignActive(_ application: UIApplication?) {
    updateAuthStateIfSystemAlertToUseWebAuthFlowPresented()
  }

  public func applicationDidBecomeActive(_ application: UIApplication?) {
    var isRequestingWebAuthenticationSession = false

    if authenticationSession != nil {
      switch authenticationSessionState {
      case .none, .started, .showWebBrowser:
        break
      case .showAlert:
        authenticationSessionState = .showWebBrowser
      case .canceledBySystem:
        authenticationSession?.cancel()
        authenticationSession = nil
        let errorDomain = Values.authenticationSessionErrorDomain
        let error = errorFactory.error(domain: errorDomain, code: 1, message: nil, underlyingError: nil)

        authenticationSessionCompletionHandler?(nil, error)
        isRequestingWebAuthenticationSession = self.isRequestingWebAuthenticationSession
      }
    }

    // _expectingBackground can be YES if the caller started doing work (like login)
    // within the app delegate's lifecycle like openURL, in which case there
    // might have been a "didBecomeActive" event pending that we want to ignore.
    guard
      !isExpectingBackground,
      safariViewController == nil,
      !isDismissingSafariViewController,
      !isRequestingWebAuthenticationSession
    else { return }

    isActive = true

    if let validApplication = application {
      pendingURLOpener?.applicationDidBecomeActive(validApplication)
    }
    cancelBridgeRequest()

    NotificationCenter.default.post(name: .FBSDKApplicationDidBecomeActive, object: self)
  }

  public func applicationDidEnterBackground(_ application: UIApplication?) {
    isActive = false
    isExpectingBackground = false
    updateAuthStateIfSystemCancelAuthSession()
  }

  public func application(
    _ application: UIApplication,
    open url: URL,
    sourceApplication: String?,
    annotation: Any?
  ) -> Bool {
    let pendingURLOpener = self.pendingURLOpener

    if let pending = pendingURLOpener,
       pending.shouldStopPropagation?(of: url) == true {
      return true
    }

    let canOpenURL = pendingURLOpener?.canOpen(
      url,
      for: application,
      sourceApplication: sourceApplication,
      annotation: annotation
    ) ?? false

    let completePendingOpenURLBlock = { [self] in
      self.pendingURLOpener = nil
      pendingURLOpener?.application(
        application,
        open: url,
        sourceApplication: sourceApplication,
        annotation: annotation
      )
      isDismissingSafariViewController = false
    }
    // if they completed a SFVC flow, dismiss it.
    if let safariViewController = safariViewController {
      isDismissingSafariViewController = true
      safariViewController.presentingViewController?.dismiss(animated: true, completion: completePendingOpenURLBlock)
      self.safariViewController = nil
    } else {
      if authenticationSession != nil {
        authenticationSession?.cancel()
        authenticationSession = nil

        // This check is needed in case another sdk / message / ad etc... tries to open the app
        // during the login flow.
        // This dismisses the authentication browser without triggering any login callbacks.
        // Hence we need to explicitly call the authentication session's completion handler.
        if !canOpenURL {
          let errorMessage = "Login attempt cancelled by alternate call to openURL from: \(url)"
          let loginError = errorFactory.error(
            code: CoreError.errorBridgeAPIInterruption.rawValue,
            userInfo: [ErrorLocalizedDescriptionKey: errorMessage],
            message: errorMessage,
            underlyingError: nil
          )

          if let handler = authenticationSessionCompletionHandler {
            handler(url, loginError)
            authenticationSessionCompletionHandler = nil
          }
        }
      }
      completePendingOpenURLBlock()
    }

    if canOpenURL {
      return true
    }

    return handleBridgeAPIResponse(url: url, sourceApplication: sourceApplication)
  }

  public func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    guard
      let launchedURL = launchOptions?[UIApplication.LaunchOptionsKey.url] as? URL,
      let sourceApplication = launchOptions?[UIApplication.LaunchOptionsKey.sourceApplication] as? String,
      let loginManagerClass = NSClassFromString("FBSDKLoginManager") as? URLOpening.Type,
      let loginManager = loginManagerClass.makeOpener?()
    else {
      return false
    }

    return loginManager.application(
      application,
      open: launchedURL,
      sourceApplication: sourceApplication,
      annotation: launchOptions?[UIApplication.LaunchOptionsKey.annotation]
    )
  }
}

// MARK: URLOpener Conformance

extension _BridgeAPI {
  public func open(
    _ url: URL,
    sender: URLOpening?,
    handler: @escaping SuccessBlock
  ) {
    isExpectingBackground = true
    pendingURLOpener = sender

    let block = { [weak urlOpener, weak errorFactory] in
      // Dispatch openURL calls to prevent hangs if we're inside the current app delegate's openURL flow already
      if let opener = urlOpener {
        opener.open(url, options: [:]) { success in
          handler(success, nil)
        }
      } else {
        #if DEBUG
        // self.urlOpener should only be nil in test
        let message = "Cannot login due to urlOpener being nil"
        let userInfo = [ErrorLocalizedDescriptionKey: message]
        let loginError = errorFactory?.unknownError(message: message, userInfo: userInfo)
        handler(false, loginError)
        #endif
      }
    }

    #if DEBUG
    block()
    #else
    DispatchQueue.main.async(execute: block)
    #endif
  }

  public func open(
    _ request: BridgeAPIRequestProtocol,
    useSafariViewController: Bool,
    from fromViewController: UIViewController?,
    completionBlock: @escaping BridgeAPIResponseBlock
  ) {
    do {
      let requestURL = try request.requestURL()

      pendingRequest = request
      pendingRequestCompletionBlock = completionBlock
      let handler = bridgeAPIRequestCompletionBlock(request: request, completion: completionBlock)

      if useSafariViewController {
        openURLWithSafariViewController(url: requestURL, sender: nil, from: fromViewController, handler: handler)
      } else {
        open(requestURL, sender: nil, handler: handler)
      }
    } catch {
      let response = bridgeAPIResponseFactory.createResponse(request: request, error: error)
      completionBlock(response)
      return
    }
  }

  public func openURLWithSafariViewController(
    url: URL,
    sender: URLOpening?,
    from fromViewController: UIViewController?,
    handler: @escaping SuccessBlock
  ) {
    guard url.scheme?.hasPrefix(URLSchemeEnum.http.rawValue) == true else {
      return open(url, sender: sender, handler: handler)
    }

    isExpectingBackground = false
    pendingURLOpener = sender

    if sender?.isAuthenticationURL(url) == true {
      setSessionCompletionHandler(calling: handler)
      openURLWithAuthenticationSession(url: url)
      return
    }

    guard let parent = fromViewController ?? InternalUtility.shared.topMostViewController() else {
      logger.logEntry("There are no valid ViewController to present SafariViewController with")
      return
    }

    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let sfvcQueryItem = URLQueryItem(name: "sfvc", value: "1")
    let items = components?.queryItems ?? []
    components?.queryItems = items + [sfvcQueryItem]

    guard let updatedURL = components?.url else {
      logger.logEntry("Unable to create a URL from URL components.")
      return
    }

    let container = _ContainerViewController()
    container.delegate = self
    if let transitionCoordinator = parent.transitionCoordinator {
      // Wait until the transition is finished before presenting SafariVC to avoid a blank screen.
      transitionCoordinator.animate(alongsideTransition: nil) { [self] _ in
        // Note SFVC init must occur inside block to avoid blank screen.
        presentSafariViewController(with: updatedURL, in: container, from: parent)
      }
    } else {
      presentSafariViewController(with: updatedURL, in: container, from: parent)
    }
    // Assuming Safari View Controller always opens
    handler(true, nil)
  }
}

// MARK: SFSafariViewControllerDelegate Conformance

extension _BridgeAPI {
  // This means the user tapped "Done" which we should treat as a cancellation.
  public func safariViewControllerDidFinish(_ safariViewController: SFSafariViewController) {
    if let opener = pendingURLOpener {
      pendingURLOpener = nil
      opener.application(nil, open: nil, sourceApplication: nil, annotation: nil)
    }
    cancelBridgeRequest()
    self.safariViewController = nil
  }
}

// MARK: ASWebAuthenticationPresentationContextProviding Conformance

extension _BridgeAPI: ASWebAuthenticationPresentationContextProviding {
  public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    // `UIApplication.keyWindow` is deprecated and returns a key window across all
    // connected scenes, so resolve the anchor from the active scene instead.
    let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = windowScenes.first { $0.activationState == .foregroundActive } ?? windowScenes.first
    return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first ?? ASPresentationAnchor()
  }
}
