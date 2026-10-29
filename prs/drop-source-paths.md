Report source paths of native file drops on macOS

## What this adds

A `drop-source-paths` webview event. When the user drops files from Finder (or any app that puts
file URLs on the drag pasteboard) onto a view, the main process gets the original absolute paths of
that drop:

```ts
if (win.webview.supportsDropSourcePaths()) {
  win.webview.on("drop-source-paths", (event: unknown) => {
    const { paths } = (event as { data: { detail: { paths: string[] } } }).data.detail;
  });
}
```

`BrowserView.supportsDropSourcePaths()` says whether a view will ever emit it.

## Why an app needs it

The page's DOM `drop` event gives `File` objects with a name and contents but no path. That's
fine for an upload, but an editor or file manager needs to know *which* file was dropped. If the
user drags a file that's already inside the project the app has open, the app should open that
file, not import a second copy. Without the path, the app can only guess from the name, and
guessing opens the wrong file when two folders hold a `README.md`. Issue #63 asks for the same
thing.

## macOS implementation

- WKWebViews are now created as `ElectrobunWKWebView`, a small `WKWebView` subclass in
  `native/macos/drop_source_paths.h`. It overrides `performDragOperation:`, reads the file URLs
  from the drag pasteboard with `readObjectsForClasses:@[NSURL.class]` and
  `NSPasteboardURLReadingFileURLsOnlyKey`, calls `super`, and reports the paths only when WebKit
  accepted the drop. The page still gets its normal DOM drop with the same files.
- File reference URLs are resolved through `filePathURL`. Web links, text and file promises
  (a mail attachment, say) don't produce the event, because they have no source file.
- The paths go out as `{"paths": [...]}` through the existing webview event handler, so the
  TypeScript SDK and the native SDKs' `event` callback both receive it.
- Only public AppKit and WebKit API is used: `NSDraggingDestination` on the `WKWebView` subclass
  and `NSPasteboard`.
- `parseWebviewEventBridgeMessage` now refuses `drop-source-paths`, so a page can't send itself
  fake paths through `__electrobunEventBridge`. Only the native wrapper can emit it.

CEF views on macOS don't emit the event yet; `supportsDropSourcePaths()` returns `false` for them.
CEF's `CefDragHandler::OnDragEnter` could supply the same data in a follow-up.

## Linux and Windows

`webviewSupportsDropSourcePaths` is exported from both wrappers and returns `false`, so
`supportsDropSourcePaths()` reports unsupported and apps keep their existing drop handling. The
event never fires there. I haven't built or tested a WebKitGTK or WebView2 version, so this PR
doesn't claim either.

## Tests

- `hutch test:macos-drop-source-paths` compiles `drop_source_paths.test.mm` and drives a real
  `ElectrobunWKWebView` in a window through `draggingEntered:`, `draggingUpdated:` and
  `performDragOperation:` with two temporary files, one with quotes and a non-ASCII name. It checks
  that the handler gets both paths in order and that the page's own `drop` event still sees the
  same two files. It also checks that web URLs and plain text on the pasteboard don't become paths.
- `hutch test:drop-source-paths` runs `src/shared/drop-source-paths.test.js`, which checks the
  wiring in the macOS, Linux and Windows wrappers, the core export and the SDK, in the same style
  as `spell-check.test.js`.
- `eventBridge.test.ts` gains a case showing a page can't forge the event.
- The existing `native-symbol-contract.test.ts` covers the new core and wrapper symbol.

Both new scripts run in `release.yml` next to the spell-check steps, and the contract test joins
`test:unit`. All of these fail on `v2.0.5` and pass with the patch:

```sh
cd package && node --test src/shared/drop-source-paths.test.js \
  && scripts/test-macos-drop-source-paths.sh \
  && node scripts/run-bun-test.js src/sdks/main/proc/eventBridge.test.ts src/shared/native-symbol-contract.test.ts
```
