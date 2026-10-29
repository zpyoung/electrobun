Add isolated preview webviews on macOS

## What this adds

An isolated preview is a throwaway, sandboxed webview whose pages and assets come only from a URL scheme the app answers. The app hands it untrusted HTML, and the native layer stops the page from reaching anything else before the first byte loads.

- A `BrowserView` option, `isolatedPreview: { scheme, handler }`. The handler gets a standard `Request` for every load on that scheme and returns a `Response`, much like Electron's `protocol.handle`.
- `view.setIsolatedPreviewHandler(handler | null)` sets or replaces the handler later. Until there is one, every request gets a 404.
- `<electrobun-webview isolated-preview="scheme">` creates one from a page. The main process answers its requests through `setIsolatedPreviewHandler`, usually from `BrowserView.on("created")`.
- `BrowserView.isIsolatedPreviewSupported()` says whether the platform has them.

## Why an app needs it

Our app shows HTML reports that coding agents write into a project folder. People want to see them rendered, scripts and all, but the page is untrusted: it can read whatever the app serves it, so any outbound request is a way to send that out. Today the options are a normal webview, which can reach the network, keep cookies and ask for the camera, or a sandboxed iframe with a CSP, which page script and response headers can't fully enforce and which doesn't cover WebRTC at all.

What we need is a view where the host, not the page, decides what loads. The same need comes up for previewing user documents, rendering email or showing generated content.

## macOS implementation

All of it is public WebKit API. The policy code is in `native/macos/isolated_preview.h`, next to `spell_check.h`, so the native test compiles it on its own.

- Each preview gets its own `[WKWebsiteDataStore nonPersistentDataStore]`, so storage is shared with no other view and gone when the view is.
- A `WKContentRuleList` blocks every load and then exempts the preview scheme, `about:`, `data:` and `blob:`. That covers subresources, fetch, XHR, WebSockets, beacons, preconnects and worker requests. The list compiles asynchronously, so the view refuses every navigation, and holds any `loadURL`, until the list is installed. If compiling fails, the view stays blank.
- Content rules can't see WebRTC, which opens UDP directly. The view sets `defaultWebpagePreferences.lockdownModeEnabled`, which removes `RTCPeerConnection`. It also removes WebAssembly, WebGL and service workers, and slows JavaScript. That trade is fine for previews, and the docs say so.
- The navigation delegate cancels anything off the scheme (except `about:blank` and `about:srcdoc`), cmd-clicks and downloads, and the response policy cancels anything WebKit can't render instead of downloading it. Popups, file pickers, camera, microphone and location are denied without a prompt or a `new-window-open` event an app might act on.
- The view gets no `views://` or `appdata://` handler, and it's always sandboxed, so it never sees the RPC preload or its key. `initWebview` refuses an unsandboxed or CEF isolated preview.
- `loadURL` refuses off-scheme URLs before `loadFileURL` could hand the web process a file sandbox extension, and `loadHTML` is refused.
- Requests reach the app as an `isolated-preview-request` event from the native callback, with the method, headers and body (up to 16 MB, base64). The SDK drops event-bridge copies of that event, because page script can post any event name. The answer comes back through `webviewIsolatedPreviewRespond`, which copies the body before returning and fulfills the `WKURLSchemeTask` on the main queue. A task WebKit already stopped is never answered, since that raises.

Core (`main.zig`) exports `isolatedPreviewSupported`, `setNextWebviewIsolatedPreview` and `webviewIsolatedPreviewRespond`, looking each one up in the wrapper like `webviewSetSpellCheck` does. The scheme is passed the same way `setNextWebviewAllowedProtocols` passes allowed protocols, so `createWebview` keeps its signature. An empty scheme clears a pending request, and the SDK clears it after every creation so a failed one can't leak isolation into the next view. The scheme must be lowercase letters, digits and hyphens, start with a letter, not be a scheme WebKit handles itself, and not be `views` or `appdata`. An empty or invalid `isolated-preview` attribute fails creation instead of making an ordinary view.

The other language SDKs don't expose it yet. I kept this PR to the TypeScript SDK; the core exports are there for them.

## Linux and Windows

The wrappers export all three symbols and return `false`. `BrowserView.isIsolatedPreviewSupported()` returns `false`, and creating a preview throws "Isolated preview views are not supported on this platform". A tag with `isolated-preview` fails to initialize. Nothing falls back to an ordinary view. WebKitGTK and WebView2 have equivalent pieces (custom URI schemes, request filtering, ephemeral contexts), but they're a separate PR.

## How it's tested

- `scripts/test-macos-isolated-preview.sh` (`hutch test:macos-isolated-preview`) compiles `isolated_preview.test.mm` and drives real `WKWebView`s against an in-process loopback TCP listener and UDP listener. The test page tries stylesheets, `@import`, fonts, scripts, images, iframes, video, fetch, XHR, a WebSocket, EventSource, `sendBeacon`, a worker fetch, a WebRTC offer with a STUN server, a form post, an `<a download>` click, `window.open` and a top-level navigation. Without the fences the same page opens 16 TCP connections and sends STUN datagrams, which proves the test can see a leak. With them it opens none and sends none, while in-scheme images, fetch and POST bodies still work. It also checks that two previews don't share `localStorage` or cookies, that an unrenderable response doesn't become a download, and the scheme and navigation rules.
- `src/shared/isolated-preview.test.js` (`hutch test:isolated-preview`) checks the wiring in the wrapper, core, SDK and tag preload, and that Linux and Windows return `false`.
- The existing `native-symbol-contract.test.ts` passes with the three new core lookups.
- Both new tests fail on v2.0.5: the contract test fails all five cases, and the native test doesn't compile without the header.
- Both run in `release.yml`, next to the spell-check steps.

Docs: `browser-view.mdx` has a new "Isolated preview views" section, and `electrobun-webview-tag.mdx` documents the `isolated-preview` attribute.
