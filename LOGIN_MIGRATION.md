# Handling Facebook Login and Limited Login

If your integration assumes every successful login returns an `AccessToken`, handle Limited Login before upgrading.
This guide describes the current SDK source; consult the [changelog](CHANGELOG.md) for your installed release.
See also Meta's [Limited Login guidance](https://developers.facebook.com/docs/facebook-login/limited-login/ios).

## Choose the credential returned by the login

| Credential | Purpose | Where to obtain it |
| --- | --- | --- |
| `AccessToken` | Graph API access under granted permissions. | Successful result's token or `AccessToken.current`. |
| `AuthenticationToken` | Limited Login OpenID Connect ID token (JWT). | `AuthenticationToken.current`. |

The Objective-C login result also exposes `authenticationToken`.

An `AuthenticationToken` is not a Graph API access token. Do not pass its `tokenString` as a Graph request's
`access_token`, or to a backend endpoint that expects an access token. An authentication provider or backend must
explicitly support the Limited Login ID token and its verification requirements; decoding a JWT is not verification.

`LoginTracking.enabled` requests tracking-enabled login. It neither grants App Tracking Transparency authorization nor
guarantees an access token. In the current SDK, on iOS 17 and later, that request uses Limited Login when advertiser
tracking is disabled. On earlier supported iOS versions, this routing also depends on remote configuration. Handle the
actual login result instead of choosing a token type from the requested tracking mode or OS version alone.

## Handle success, cancellation, and errors

Keep the `LoginManager` alive for the login attempt, call it on the main thread, and wait for completion before starting
another attempt. Request only the permissions your feature needs, and check the granted/declined permissions before
using a permission-dependent feature.

The Swift `LoginResult.success` case carries an optional access token. For a successful Limited Login, read
`AuthenticationToken.current` in that callback. Do not treat a nil access token as cancellation, or mistake a credential
cached before the attempt for the result of a failed or cancelled attempt.

The example takes an app-supplied `requestNonce` prepared for this specific attempt. Generate a fresh, cryptographically
secure nonce and follow your authentication provider's rules for the value sent to Facebook and the value retained for
verification. The SDK requires a nonempty nonce without whitespace.

```swift
import FBSDKCoreKit
import FBSDKLoginKit
import UIKit

enum FacebookLoginOutcome {
  case accessToken(AccessToken)
  case authenticationToken(AuthenticationToken)
  case cancelled
  case failed(Error)
}

@MainActor
func logIn(
  manager: LoginManager,
  from presenter: UIViewController,
  requestNonce: String,
  completion: @escaping (FacebookLoginOutcome) -> Void
) {
  guard let configuration = LoginConfiguration(
    permissions: ["public_profile"],
    tracking: .enabled,
    nonce: requestNonce
  ) else {
    completion(.failed(NSError(domain: "ExampleLogin", code: 1)))
    return
  }

  manager.logIn(viewController: presenter, configuration: configuration) { result in
    switch result {
    case let .success(_, _, accessToken):
      if let accessToken = accessToken {
        completion(.accessToken(accessToken))
      } else if let authenticationToken = AuthenticationToken.current {
        completion(.authenticationToken(authenticationToken))
      } else {
        completion(.failed(NSError(domain: "ExampleLogin", code: 2)))
      }
    case .cancelled:
      completion(.cancelled)
    case let .failed(error):
      completion(.failed(error))
    }
  }
}
```

For example,
[Firebase's Limited Login integration](https://firebase.google.com/docs/auth/ios/facebook-login)
sends the SHA-256 hash of a nonce to Facebook and retains the original nonce for Firebase's `rawNonce` argument.
That is a Firebase-specific contract, not a rule to apply to every backend. The example above does not implement
provider sign-in or token verification. Do not log tokens or nonces.

## Understand the local Graph compatibility behavior

For eligible requests when advertiser tracking is disabled, the current SDK can answer `/me`, `/me/friends`, and
`/me/picture` (including version-prefixed paths) from the current profile through a local compatibility layer. These
responses are limited to the available profile data. They do not mean the ID token authorizes arbitrary Graph API
requests, has additional permissions, or will be accepted by a Graph request made directly by your backend.

For a Limited Login profile, prefer the available `Profile.current` data for supported profile features. If your app
needs other Graph operations, review the endpoint's login and permission requirements rather than substituting the
ID token for an access token. Test both credential paths, cancellation, errors, missing optional profile fields, and
your provider's nonce verification when upgrading.
