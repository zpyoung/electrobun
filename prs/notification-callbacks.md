Add notification permission and click/dismiss events on macOS

## What this adds

Three things in the TypeScript SDK, built on `UNUserNotificationCenter`:

- `Utils.getNotificationPermission()` reads whether the app may show notifications, without prompting. `Utils.requestNotificationPermission()` shows the macOS prompt the first time and resolves with the stored decision after that. Both resolve one of `"not-determined"`, `"denied"`, `"authorized"`, `"provisional"` or `"unsupported"`.
- `Utils.showNotification()` takes an optional `id` and returns the id it used (a random UUID when you don't pass one). Showing a second notification with the same id replaces the first.
- Two app events, `notification-click` and `notification-dismiss`, each carrying `{ id }`.

```ts
import Electrobun, { Utils } from "electrobun/main";

await Utils.requestNotificationPermission();
Utils.showNotification({ id: "export-42", title: "Export complete" });

Electrobun.events.on("notification-click", (event) => {
  openExport((event.data as { id: string }).id);
});
```

Existing `showNotification` calls keep working unchanged.

## Why an app needs it

Right now `showNotification` returns nothing and reports nothing back. An app can't tell whether macOS will display its notifications at all, and when the user clicks one, the app comes forward but can't tell which notification was clicked. So it can't take the user to the thing the notification was about, which is usually the point of sending it. Apps that send a notification per task, chat or build need the id round trip, and they need the permission state to explain a missing banner instead of failing silently.

## macOS implementation

- A small `UNUserNotificationCenterDelegate` maps `UNNotificationDefaultActionIdentifier` to `click` and `UNNotificationDismissActionIdentifier` to `dismiss`, and passes the request identifier back. It ignores other actions.
- macOS only reports a dismissal for notifications in a category with `UNNotificationCategoryOptionCustomDismissAction`, so the wrapper registers one category (`electrobun.notification`) and puts every notification in it.
- The delegate doesn't implement `willPresentNotification`, so notifications still aren't shown while the app is frontmost, the same as today.
- The permission calls use `getNotificationSettingsWithCompletionHandler` and `requestAuthorizationWithOptions`. They report back through a callback, because the prompt can wait on the user indefinitely and shouldn't block the Bun thread. A request id matches each answer to its promise.
- `currentNotificationCenter` raises an exception in a process with no bundle identifier. The new code checks for one first, reports `"unsupported"`, and falls back to the existing `NSUserNotification` path for `showNotification`. That check lives in `notification_response.h` so it can be tested without building the wrapper.
- `showNotification` becomes a thin wrapper over the new `showNotificationWithId`, so its existing behavior and fallback are unchanged. A refused permission request doesn't switch later notifications to the legacy API on its own; `showNotification`'s first-call check still decides that, as before. Notifications that go out through the legacy API report no click or dismiss, and the docs say so.
- The delegate hands the id to the JS callback as a `strdup` copy, like the webview events do, because the threadsafe callback reads it after the delegate returns.
- `setNotificationCategories` is asynchronous, so a notification posted in the first moments after launch might not report its dismissal. Clicks aren't affected.

The SDK installs the handlers when it loads, so clicks arrive for as long as the app runs. I haven't checked whether a click that launches a closed app gets reported. macOS only promises that when the delegate is set before the app finishes launching, and this change doesn't move it earlier.

## Linux and Windows

`ElectrobunCore` looks up the three new wrapper symbols with `lookupOptionalNativeSymbol`, and only the macOS wrapper defines them. Elsewhere `setNotificationHandlers` and `requestNotificationPermission` return false, and the SDK resolves both permission calls with `"unsupported"`. The click and dismiss events never fire there. `showNotificationWithId` falls back to the existing `showNotification`, so notifications still show. The Linux and Windows wrapper ABI doesn't change.

The other language SDKs don't wrap the new core exports yet. They're plain C functions, so they can follow in a separate change.

## Tests

- `package/src/shared/notification-callbacks.test.ts` is a source contract test in the style of `native-symbol-contract.test.ts`. It checks the macOS delegate and category wiring, the bundle check, that Linux and Windows don't define the symbols, the optional core lookups and their fallbacks, and the SDK's status mapping and events. It fails on `v2.0.5`.
- `package/src/native/macos/notification_response.test.mm`, run by `scripts/test-macos-notification-response.sh` (`hutch test:macos-notification-response`), compiles against the real UserNotifications framework. It checks that the default and dismiss actions map to `click` and `dismiss`, that other actions map to nothing, and that an unbundled process gets no notification center instead of an exception.
- The existing `native-symbol-contract.test.ts` still passes.

```sh
cd package
node scripts/run-bun-test.js src/shared/notification-callbacks.test.ts src/shared/native-symbol-contract.test.ts
scripts/test-macos-notification-response.sh
```

I haven't checked a real click or dismissal. macOS may refuse notification authorization for an unsigned build, and I don't have a signing identity to build a signed one. It needs a check on a signed app before merging.
