Add Session.setProxy to route a partition through a proxy (macOS)

## What it adds

`Session.fromPartition(partition).setProxy(proxy)` sends every request from views in that partition through an HTTP CONNECT or SOCKS5 proxy. That covers page loads, subresources, `fetch()` and WebSockets. `matchDomains` limits the proxy to some domains and `excludedDomains` keeps some off it. `setProxy(null)` goes back to direct connections, and `Session.supportsProxy` says whether the platform can do it.

```ts
Session.fromPartition("persist:preview").setProxy({
  type: "http",
  host: "127.0.0.1",
  port: 8899,
  matchDomains: ["localhost"],
});
```

## Why an app needs it

A dev tool that previews several local servers at once wants to give each one a stable name, like `feature-a.localhost` and `feature-b.localhost`, while they really listen on different ports. A small local proxy can do that mapping, because with a proxy the proxy resolves the hostname, not the system. Without a per-session proxy, the only ways to get those names working are changing `/etc/hosts`, the system resolver or the system proxy, which affects every other app on the machine. It's also the usual way to put an app's web content behind a corporate or debugging proxy without touching system settings.

## macOS implementation

macOS 14 added `WKWebsiteDataStore.proxyConfigurations`, which takes Network framework `nw_proxy_config_t` values. `sessionSetProxy` builds one with `nw_proxy_config_create_http_connect` or `nw_proxy_config_create_socksv5` and adds the match and excluded domains.

The proxy is a property of the data store, and a non-`persist:` partition gives every view its own `nonPersistentDataStore`. So `createDataStoreForPartition` now keeps a weak table of the stores it has handed out for each partition, plus the proxy last set for it. `setProxy` updates every live store in the partition, and a store created later gets the proxy when it's created. Views that already exist pick it up without being recreated.

I checked the routing outside Electrobun with a WKWebView on an ephemeral store pointed at a small Bun proxy. Page loads, a script subresource and a WebSocket to `feature-x.localhost` all arrived at the proxy as `CONNECT` and reached the mapped port. WebKit doesn't bypass the proxy for `*.localhost`. With `matchDomains: ["localhost"]`, `example.com` loaded directly. Setting the proxy after the view was created also worked.

In a bundled app, App Transport Security still applies to the URL. A proxy doesn't change that, so plain-http names other than `localhost` and IP addresses need an `NSExceptionDomains` entry. The docs say so, because without the entry the load fails before the proxy is ever contacted.

The native library now links `Network.framework`. The calls sit behind `@available(macOS 14.0, *)`, so the deployment target doesn't change. On older macOS, `Session.supportsProxy` is `false`.

## Linux and Windows

`sessionSupportsProxy` and `sessionSetProxy` return `false` on both. `Session.setProxy()` throws "Session proxies are not supported on <platform>" there, and on macOS before 14, instead of quietly loading pages without the proxy. WebKitGTK (`webkit_network_session_set_proxy_settings`) and WebView2 (`--proxy-server` per environment) could support this later.

CEF views don't use the session proxy on any platform. The docs say so.

## Tests

`package/src/sdks/main/__tests__/session-proxy.test.ts`:

- Unit tests for the TypeScript side: it throws on an unsupported platform without calling native code, rejects a bad proxy (unknown type, empty host, out-of-range port, bad domain lists), and reports a native refusal.
- A source check that the Linux and Windows wrappers return `false` from both functions.
- On macOS, it compiles the proxy section of `nativeWrapper.mm` into a dylib, like `native-text-bitmap.test.ts` does, and checks real WebKit data stores. A store opened before `setProxy` gets the proxy, a new store in the same partition gets it, another partition doesn't, clearing removes it, and invalid JSON is refused. On macOS before 14 it checks that the feature reports unsupported.

```sh
cd package && node scripts/run-bun-test.js src/sdks/main/__tests__/session-proxy.test.ts src/shared/native-symbol-contract.test.ts
```

The docs section is in `apis/browser-view.mdx`, under "Session proxies".
