Let navigation rules target iframes on macOS

## What this adds

A navigation rule written as `frame:<pattern>` (allow) or `^frame:<pattern>` (block) applies only to subframe navigations. Top-level navigations skip it. Everything else about rules is unchanged: `*` is a wildcard, `^` blocks, the last matching rule wins and no match allows.

```ts
view.setNavigationRules([
  "^*",
  "https://*",
  "frame:about:srcdoc",
  "frame:data:*",
  "frame:blob:*",
]);
```

With these rules the page can render `srcdoc`, `data:` and `blob:` iframes, while a top-level navigation to a `data:` URL is still cancelled.

## Why an app needs it

On macOS, `decidePolicyForNavigationAction` checks the rules for every frame, not just the main one. So a strict policy like `["^*", "https://*"]` also cancels an iframe the page builds with `frame.srcdoc = …`, and the user sees an empty box. Our case: a desktop app with an embedded browser pane uses a strict top-level policy, and a local tool that previews generated HTML through a `srcdoc` iframe rendered blank there while it worked in Chromium.

Allowing `about:srcdoc` or `data:*` outright would fix the iframe, but it would also let the top-level page navigate to a `data:` URL, which is exactly what a strict policy is meant to stop. The app needs to say "in iframes only".

## macOS implementation

- `NavigationRule` in `native/shared/navigation_rules.h` gains `isFrameRule`, set when the pattern (after any `^`) starts with `frame:`. The prefix is stripped before matching.
- Both `checkNavigationRulesForUrl` overloads take a new `isMainFrame` parameter, defaulting to `true`, and skip frame rules when it's true. Existing callers keep their behavior.
- `AbstractView` gets `shouldAllowNavigationToURL:isMainFrame:`, which now goes through the shared helper instead of its own copy of the loop. The one-argument selector stays and passes `YES`.
- The WKWebView navigation delegate passes `!targetFrame || targetFrame.isMainFrame`. A nil target frame means a new window, which is a top-level page.
- CEF's `OnBeforeBrowse` passes `!frame || frame->IsMain()`.

## Linux and Windows

Both wrappers keep their current rule loop and treat every navigation as top-level. A `frame:` pattern can never match a real URL there, so frame rules have no effect and the policy stays exactly as strict as the same rules without them. Nothing gets more permissive on a platform this PR doesn't cover. WebKitGTK and WebView2 (`FrameNavigationStarting`) could support this later; I left them out to keep the PR to the platform I could test.

## Tests

- `hutch test:macos-frame-navigation-rules` (`scripts/test-macos-frame-navigation-rules.sh`) compiles `native/macos/frame_navigation_rules.test.mm` against the real `navigation_rules.h`. Its WKWebView part uses a navigation delegate that makes the same `targetFrame.isMainFrame` call as the wrapper and decides through the shared helper. It checks:
  - rule parsing and matching, including `^frame:`, the comma-separated overload, and that normal rules still apply to subframes
  - a baseline: WebKit does ask the delegate about an `about:srcdoc` subframe, and under `["^*", "http://*", "about:blank"]` none of the `srcdoc`, `data:` or `blob:` iframes runs
  - with the three frame rules added, all three iframes run script, while a top-level `data:` navigation is still cancelled
- The script skips on non-Darwin hosts and runs in `release.yml` next to the spell-check steps.

It fails on `v2.0.5` and passes with the patch:

```sh
cd package && scripts/test-macos-frame-navigation-rules.sh
```

Docs: `apis/browser-view.mdx` explains the rule syntax, including `frame:` rules and the platform note. `browser-window.mdx` and `browser/electrobun-webview-tag.mdx` point to it, and `setNavigationRules` has a JSDoc comment in `BrowserView.ts` and `webviewtag.ts`.
