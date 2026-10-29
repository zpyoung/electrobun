Add a cache-bypassing reload and a load-failed event for webviews

## What this adds

Two things a browser-like view needs and Electrobun doesn't have yet:

- `reloadIgnoringCache()` reloads the current page without using cached responses. The URL and the
  view's partition stay the same.
- A `load-failed` event fires when a navigation fails, before or after it commits: DNS, a refused
  connection, a TLS error and so on. Its detail is
  `{ url, domain, code, description }`, with the URL that failed and the engine's error.

Both are on `BrowserView` and on `<electrobun-webview>`:

```ts
import "electrobun/view";

const webview = document.querySelector("electrobun-webview");

if (await webview.supportsReloadIgnoringCache()) {
  await webview.reloadIgnoringCache();
}

webview.on("load-failed", (event: CustomEvent) => {
  const { url, domain, code, description } = event.detail;
  showErrorPage(url, `${description} (${domain} ${code})`);
});
```

`supportsReloadIgnoringCache()` and `supportsLoadFailed()` say up front whether a view can do
either, so an app can hide a Hard Reload button or keep its own error handling instead of waiting
for an event that never comes. `reloadIgnoringCache()` returns `false`, without reloading, where it
isn't supported.

## Why an app needs it

An app that embeds a browser (a dev tool previewing a local server, a docs viewer, a mini browser)
needs the two controls every browser has.

Hard reload is how a developer sees the file they just changed when the server sent long cache
headers. `reload()` revalidates at best, and the usual workarounds are worse: adding a cache-buster
to the URL changes the page's identity and history, and clearing the partition's storage logs the
user out of everything.

When a page can't load, the app needs to know. Right now a failed navigation just stops: no
`did-navigate`, no error, and the app can only guess from a timeout. With `load-failed` the app
can show "this site can't be reached" with the address the user typed and a Retry button, and
tell a DNS failure from a certificate error.

## macOS implementation

- `reloadIgnoringCache` calls `-[WKWebView reloadFromOrigin]`. WebKit then loads the page with its
  own cache bypassed and sends `Cache-Control: no-cache` and `Pragma: no-cache` without validators,
  so proxies refetch too.
- The navigation delegate now implements `webView:didFailProvisionalNavigation:withError:` and
  `webView:didFailNavigation:withError:`. Both emit `load-failed` through the existing webview event
  handler, so the TypeScript SDK, the webview tag and the native SDKs' `event` callback all receive
  it. `native/macos/load_failed.h` builds the detail with `NSJSONSerialization`, taking the URL from
  the error's `NSURLErrorFailingURLErrorKey` and falling back to the web view's URL.
- The core delivers the detail to the tag as an object, the same way it does for `host-message`.
- A page can't fake a `load-failed`: the TypeScript event bridge parser and core's
  `isValidEventBridgeMessage` both refuse it from `__electrobunEventBridge`.
- Only public WebKit API is used.

A navigation that's stopped or replaced by a newer one doesn't report anything on current WebKit.
Older WebKit may report it as `NSURLErrorDomain` `-999`, so the docs tell apps to compare `url`
with the navigation they started. CEF views on macOS report both features unsupported for now.
CEF has `CefBrowser::ReloadIgnoreCache` and `CefLoadHandler::OnLoadError`, so a follow-up could add
them.

## Linux and Windows

`webviewReloadIgnoringCache`, `webviewSupportsReloadIgnoringCache` and `webviewSupportsLoadFailed`
are exported from both wrappers and return `false`. The support checks report unsupported, and
`reloadIgnoringCache()` returns `false` without reloading, instead of quietly doing an ordinary
reload. WebKitGTK has `webkit_web_view_reload_bypass_cache` and the `load-failed` signal, and
WebView2 has `NavigationCompleted` with `WebErrorStatus`, so these are straightforward follow-ups.
I left them out to keep this PR to what I could test.

## Native SDKs

The three functions are C exports of the core library, and the `load-failed` event already reaches
the native SDKs' `event` callback. I didn't add Zig, Rust, Go or Odin wrappers; the docs page says
so. Happy to add them here if you'd rather ship them together.

## How it's tested

- `package/scripts/test-macos-webview-navigation.sh` builds `native/macos/webview_navigation.test.mm`
  with clang and runs it against a real `WKWebView` and a loopback HTTP server in the test binary.
  It checks that `reloadFromOrigin` sends `no-cache` without validators and shows a fresh response
  at the same URL, while an ordinary reload doesn't bypass the cache. It also checks that a
  navigation to a closed port reaches the delegate as `NSURLErrorDomain` `-1004` with the requested
  URL, and that a replaced navigation never reports a failure for its replacement. It also covers
  the JSON detail builder, including escaping and the URL fallback.
- `src/shared/webview-navigation-contract.test.ts` checks the wiring across native wrappers, core,
  the TypeScript SDK and the tag. It checks that Linux and Windows return `false` and that the event
  factory builds `load-failed`. `native-symbol-contract.test.ts` checks that every new core lookup
  has a wrapper definition on all three platforms.
- `eventBridge.test.ts` and core's `event bridge requires the native sender identity` test check
  that a page can't send `load-failed`. A new core test checks the tag gets the detail as an object.

```sh
bash package/scripts/test-macos-webview-navigation.sh
cd package && node scripts/run-bun-test.js src/shared/webview-navigation-contract.test.ts src/shared/native-symbol-contract.test.ts src/sdks/main/proc/eventBridge.test.ts
```

I also ran it in an app built on this branch, with an embedded `<electrobun-webview>`. Hard reload
reloaded the same URL with `no-cache` and `Pragma: no-cache` reaching the server, where an ordinary
reload sent neither. A refused connection and a self-signed certificate each produced `load-failed`
(`-1004` and `-1202`) with the requested URL, and navigating again once the port served loaded the
page.
