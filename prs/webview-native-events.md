feat: let apps answer native WKWebView page requests (dialogs, auth, certificates, downloads, popups, app links)

## What this adds

`BrowserView.setNativeRequestHandling(kinds, { timeoutMs })` lets an app answer page requests that WKWebView otherwise settles on its own. Each one arrives as an event with a `requestId`, and the page stays paused until the app calls `respondToNativeRequest(requestId, { accept, ... })`:

| Kind | Event | Answer |
| --- | --- | --- |
| `dialogs` | `dialog-request` (`alert`, `confirm`, `prompt`) | `{ accept, text }` |
| `auth` | `auth-request` (basic, digest, NTLM, Negotiate) | `{ accept, username, password }` |
| `certificates` | `certificate-request` (only certificates the system doesn't trust) | `{ accept }` |
| `downloads` | `download-request` | `{ accept, path }` |
| `popups` | `popup-request` | adopt with `new BrowserView({ popupRequestId })` |
| `externalApps` | `external-app-request` (`mailto:`, `zoommtg:`…) | `{ accept }` opens it with NSWorkspace |

If a request isn't answered within `timeoutMs` (120 s by default), it gets the fail-closed answer: `confirm()` returns false, `prompt()` returns null, the challenge is cancelled, the download is cancelled, the popup closes, and nothing opens. A `native-request-expired` event follows. Removing the view does the same, because WebKit requires every completion handler to be called. A request can only be answered once, and only through its own view.

Smaller additions:

- Download events now carry a stable `id`, plus `receivedBytes` and `totalBytes`.
- `cancelDownload(id)` cancels an active download.
- `close-requested` fires when the page calls `window.close()`.

Kinds an app doesn't opt into keep today's behavior exactly.

## Why an app needs it

Today an Electrobun app that shows arbitrary sites in a native webview can't do the following:

- Show `alert`/`confirm`/`prompt`. WebKit's defaults silently return.
- Sign in to a site behind basic auth.
- Let a developer through a self-signed certificate on `localhost`.
- Choose or cancel where a download goes.
- Keep an OAuth popup working. Today `new-window-open` only gives the URL, so `window.opener`, the window name and a form's POST body are lost.

Implementing these in page JavaScript isn't possible either: an async override can't fake a synchronous `confirm()`, and auth and certificate challenges never reach the page. This came up building a browser pane for a desktop IDE, where all of these are ordinary pages.

## macOS implementation

Everything uses public WebKit and AppKit API:

- Dialogs: the `WKUIDelegate` `runJavaScript{Alert,Confirm,TextInput}Panel…` methods.
- Auth and certificates: `webView:didReceiveAuthenticationChallenge:`. Server trust is first checked with `SecTrustEvaluateAsyncWithError`, so trusted certificates never reach the app. Accepting uses `credentialForTrust:`. Credentials are created with `NSURLCredentialPersistenceNone`.
- Downloads: `WKDownloadDelegate` `decideDestinationUsingResponse:` and `-[WKDownload cancel:]`. A destination that already exists is numbered (`report (1).pdf`), and `download-started` reports the final path.
- External apps: `decidePolicyForNavigationAction:` cancels URLs WebKit can't load (`+[WKWebView handlesURLScheme:]` is false and there's no registered scheme handler), then asks the app.
- Popups: `createWebViewWithConfiguration:` builds the popup from WebKit's configuration, which is what keeps the opener relationship. It gives the popup a fresh `WKUserContentController`, so the opener's scripts and message handlers don't leak in, and holds its first navigation decision. When the app creates a `BrowserView` with `popupRequestId`, `initWebview` takes over that WKWebView instead of allocating one. It then installs the new view's own preload and handlers and replays the held decision through the view's navigation delegate, so navigation rules apply. A sandboxed opener's popup can only be adopted by a sandboxed view.

The pending-request registry lives in a small header, `native/macos/native_requests.h`. Requests are main-thread only, and each resolves exactly once through a `dispatch_after` deadline. The FFI calls hop to the main thread, and `webviewRespondToNativeRequest` parses its JSON before the hop, while the caller's buffer is still valid.

The FFI surface is four symbols through the core:

- `webviewSetNativeRequestHandling(id, kinds, timeoutMs) → bool`
- `webviewRespondToNativeRequest(id, requestId, json) → bool`
- `webviewCancelDownload(id, downloadId) → bool`
- `setNextWebviewPopupRequest(requestId)`, used like `setNextWebviewAllowedProtocols`

The native wrapper now links `Security.framework`.

Not covered: `beforeunload` prompts, which have no public WKUIDelegate method.

## Linux, Windows and CEF

`setNativeRequestHandling()` returns `false` on WebKitGTK, WebView2 and CEF (including CEF on macOS), and nothing changes. The respond and cancel calls return `false` too, so an app can tell the feature is unavailable instead of waiting on events that never come. This PR covers the TypeScript SDK only. The Zig, Rust, Go and Odin SDKs don't expose it yet.

## Tests

- `package/src/native/macos/native_requests.test.mm`, run by `hutch test:macos-native-requests`. It compiles against Cocoa and WebKit like the spell-check test, and drives a real WKWebView:
  - An unanswered `confirm()` returns `false` and an unanswered `prompt()` returns `null` at the deadline, and a late answer is rejected.
  - Answered dialogs return `true` and Unicode text to the page.
  - A form POST to a named target is parked with its navigation held, then released: the popup sees `window.opener`, `window.name === "oauth"`, and the original POST body.
  - A discarded popup never loads.
  - It also unit-tests the registry (answer once, wrong view, expire-all on close), response decoding, numbered download destinations and external-URL detection.
- `package/src/shared/native-requests.test.js`, run by `hutch test:native-requests`. A source contract test in the style of `spell-check.test.js`: the delegates route through the registry, removal fails pending requests closed, the other platforms return false, and core and the SDK expose the symbols and events. It fails 4/4 on v2.0.5.
- Both run in `release.yml` next to the spell-check steps.

From the repo root:

```sh
node --test package/src/shared/native-requests.test.js && package/scripts/test-macos-native-requests.sh
```
