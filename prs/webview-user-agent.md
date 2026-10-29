Set a BrowserView's user agent on macOS

## What this adds

Three additions to the main-process `BrowserView` API:

- A `userAgent` constructor option. The view sends it with every request, the first one included, and pages see it as `navigator.userAgent`.
- `view.setUserAgent(userAgent: string | null): boolean` changes it later. It applies from the view's next request on, and `null` goes back to the engine's own user agent. `view.userAgent` holds the custom value in effect, or `null`.
- `BrowserView.getDefaultUserAgent(): string | null` returns the user agent the native renderer uses when nothing is set.

## Why an app needs it

Some sites decide what to serve from the User-Agent header, and an app that embeds a browser sometimes needs to control what it sends. Our case: a desktop app with a browser pane lets the user choose between the system webview's own identity and a "cleaned" one with app tokens removed. To build the cleaned string the app has to start from the engine's real user agent, which is why the default getter is part of this PR. Spoofing `navigator.userAgent` from a preload doesn't help, because it leaves the request header unchanged.

## macOS implementation

It uses public WebKit API only.

- `setUserAgent()` sets `WKWebView.customUserAgent`. An empty string or `null` sets it to `nil`, which restores WebKit's default. WebKit uses that value for both the request header and `navigator.userAgent`.
- `WKWebViewImpl` creates its `WKWebView` asynchronously on the main queue. If the setter runs before that, the value is held and applied right after the `WKWebView` is created, before the initial URL loads.
- With the `userAgent` option, `BrowserView` creates the view without its URL, sets the user agent, and then loads the URL. That's the same create-then-load path the `html` option already uses, and it means the first request carries the custom value.
- `getDefaultUserAgent()` creates a 1×1 `WKWebView` with a non-persistent data store and reads `navigator.userAgent` with `evaluateJavaScript:inFrame:inContentWorld:` in `WKContentWorld.defaultClientWorld`, so page scripts can't change the answer. The result is cached for the process. The call waits up to 5 seconds and returns `null` if WebKit doesn't answer.
- The Objective-C++ helpers are in `native/macos/user_agent.h`, next to `spell_check.h`, so the native test can compile them on their own.

Core (`main.zig`) exports `webviewSetUserAgent(id, cstring) bool` and `getDefaultUserAgent() ?cstring`. Both look up the wrapper symbol like `webviewSetSpellCheck` does, and report unsupported (`false` or `null`) if the wrapper doesn't have it.

## Linux, Windows and CEF

These report unsupported explicitly and never ignore the call:

- `setUserAgent()` returns `false` and changes nothing. That covers CEF on macOS too, through the `AbstractView` base method.
- The `userAgent` option logs a warning and keeps the engine default. `view.userAgent` stays `null`.
- `getDefaultUserAgent()` returns `null`.

WebKitGTK (`webkit_settings_set_user_agent`) and WebView2 (`ICoreWebView2Settings2::put_UserAgent`) could both support this later. I left them out to keep this PR to one platform I could test.

The other language SDKs (Zig, Rust, Go, Odin) and the `<electrobun-webview>` tag attribute aren't covered. A tag's view can still use `BrowserView.getById(id).setUserAgent(...)` from the main process. I can add any of these here if you'd like them in the same PR.

## Tests

- `hutch test:macos-user-agent` (`scripts/test-macos-user-agent.sh`) compiles `native/macos/user_agent.test.mm` against the real `user_agent.h` and runs it against a real `WKWebView` and a local HTTP server that records each request's `User-Agent` header. It checks four things. The first request carries a user agent set before loading. A change made after a load reaches the next request. Clearing it makes requests carry exactly the default the probe reported. The client-world read ignores a page that redefines `navigator.userAgent`. The script skips on non-Darwin hosts.
- `hutch test:user-agent` (`src/shared/user-agent.test.js`) is a source contract test in the style of `spell-check.test.js`. It checks that the override is applied right after `WKWebView` creation and before the initial load, that CEF, Linux and Windows return unsupported, that core forwards both symbols, and that `BrowserView` loads its URL only after setting the user agent. It fails on `v2.0.5` without this patch.
- The existing `native-symbol-contract.test.ts` covers the new descriptors across TypeScript, core and all three wrappers.
- Both new scripts are wired into `release.yml` next to the spell-check steps, and `test:user-agent` is part of `test:unit`.

I also ran it in a small Electrobun app on macOS, with a hidden window and a local server recording headers:
- A `BrowserView` created with `userAgent` sent it on its first request.
- After `setUserAgent()` returned `true`, the next request carried the new value.
- After `setUserAgent(null)`, requests went back to the engine default.
- `getDefaultUserAgent()` returned exactly the header that an unmodified view sent.

Docs: `docs/.../apis/browser-view.mdx` has a new "User agent" section, plus the option in the constructor table and the methods in the method list.
