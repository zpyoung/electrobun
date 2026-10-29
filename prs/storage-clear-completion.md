Report storage clear results and let apps choose a partition's WebKit store

## What this adds

- `Session.fromPartition(p).clearStorageData(types)` now returns a result instead of `void`:
  `{ status: "cleared" }` once WebKit's completion handler fires, or a `failed` / `unsupported`
  status with a reason (`timeout`, `invalid-types`, `partition`, `platform`). Existing callers that
  ignore the return value keep working.
- `Session.fromPartition(p).setStorageIdentifier(uuid)` picks the `WKWebsiteDataStore` a
  `persist:` partition uses. It has to be called before the first webview for that partition is
  created. Setting the same identifier again is fine; a different one is refused with `in-use`
  once any native webview in the process has used the partition. The result echoes the identifier
  in the uppercase form WebKit reports. CEF views ignore it.
- `BrowserView#getStorageIdentifier()` returns the identifier of the store a native webview was
  actually created with, so an app can check which store it's really writing to.

## Why an app needs it

I'm building a desktop app with browser profiles on top of the native renderer. Clearing or
deleting a profile has to remove its cookies and site data and only then report success. Today
`clearStorageData()` returns before you can know whether anything happened, so the app can't tell
a finished clear from a timeout.

It's worse than that with the default argument: `clearStorageData()` sends `["all"]`, and the macOS
wrapper didn't recognise `"all"`, so the default call removed nothing at all. This PR fixes that on
macOS.

The identifier matters for tests and for multiple installs. On macOS 14+ a `persist:<name>`
partition maps to a store named by a hash of `<name>`, inside the app's WebKit container. Two copies
of the same app (a test run and the user's real one, say) therefore share `persist:default`'s
cookies. With `setStorageIdentifier()` the app can scope its stores however it wants, and with
`getStorageIdentifier()` it can prove a view really landed in the store it chose before it touches
anything shared.

## macOS implementation

The partition-to-store logic moves out of `nativeWrapper.mm` into a small header,
`src/native/macos/website_data_store.h`, so it can be tested without the whole wrapper.

- Partitions without an assigned identifier keep the exact hash they use today, so no existing data
  moves. The native test pins `persist:default`'s identifier to catch accidental changes.
- `setStorageIdentifier()` uses `+[WKWebsiteDataStore dataStoreForIdentifier:]`, the same public
  macOS 14 API partitions already use. `WKWebViewImpl` records each partition that gets a webview, so
  the setter can refuse a change that existing views wouldn't see.
- The clear calls `-removeDataOfTypes:modifiedSince:completionHandler:` and reports `cleared` only
  from the completion handler. The existing 10-second wait becomes a `timeout` result.
- An unknown type name now fails the whole request with `invalid-types` instead of being skipped,
  because skipping it would report a partial clear as finished. `"webSQL"`, which `StorageType`
  already listed, now maps to `WKWebsiteDataTypeWebSQLDatabases`.
- Non-`persist:` partitions report `unsupported` / `partition`. Each lookup of an ephemeral partition
  creates a fresh `nonPersistentDataStore`, so a clear never reached the live view's store anyway.
- `WKWebViewImpl`'s init copied `partitionIdentifier` into its `dispatch_async` block as a raw
  pointer, which the core frees as soon as `createWebview` returns. The block now uses an
  `NSString` copied up front.
- On macOS 13 and older, `setStorageIdentifier()` reports `unsupported` / `platform` and
  `getStorageIdentifier()` returns `null`. The clear itself behaves as before there: all `persist:`
  partitions share the default store.

The result codes live in `src/native/shared/storage_status.h`, and
`src/sdks/main/proc/sessionStorage.ts` maps them to typed results. `ElectrobunCore` forwards the
new return values and the two new symbols, so the native SDKs can use them later. Their existing
`void` declarations of `sessionClearStorageData` keep working.

## Linux and Windows

Both keep their existing clear code, but `clearStorageData()` returns `unsupported` / `platform`,
because neither wrapper reports completion yet. That's explicit rather than a fake `cleared`.
`setStorageIdentifier()` returns `unsupported` / `platform` and `getStorageIdentifier()` returns
`null`. Both wrappers have completion callbacks available (`webkit_website_data_manager_clear_finish`,
`ClearBrowsingData`'s handler), so wiring real results there is a natural follow-up. Two existing
problems I didn't touch: both treat `["all"]` as "no types", and the Windows clear uses the first
WebView2 view's profile rather than the requested partition.

## Behaviour changes for existing callers

- `clearStorageData()` now returns a value. Callers that ignored `void` are unaffected.
- On macOS, an empty type list or an unknown type name clears nothing and returns `failed` /
  `invalid-types`. Before, unknown names were skipped silently.
- On macOS, clearing a non-`persist:` partition returns `unsupported` / `partition`. Before, it
  cleared a brand-new empty store.

## Tests

From `package/`:

```sh
node scripts/run-bun-test.js src/sdks/main/__tests__/session-storage.test.ts src/shared/native-symbol-contract.test.ts
scripts/test-macos-website-data-store.sh   # also: hutch test:macos-website-data-store
```

- `session-storage.test.ts` checks that every code in `storage_status.h` maps to the right result,
  and that unknown codes throw.
- `native-symbol-contract.test.ts` checks that both calls return `int32_t` / `FFIType.i32` in the SDK,
  the core and all three wrappers, and that Linux and Windows return the unsupported codes.
- `website_data_store.test.mm` runs against real WebKit, in the same style as
  `spell_check.test.mm`. It checks type parsing, the stable default identifier, the
  set/in-use/invalid rules, and that a real `WKWebView` reports its assigned identifier. It then
  writes cookies into two fresh stores, clears one, and checks that `fetchDataRecordsOfTypes:`
  comes back empty for it and non-empty for the other. The script gives the binary a unique name and
  removes its WebKit data afterwards, so it never touches another app's stores.

I also ran the patched build inside my app on macOS 26. A profile's view reported its assigned
identifier, the store directory appeared under that UUID, and a clear removed the page's cookie and
localStorage before the result came back.
