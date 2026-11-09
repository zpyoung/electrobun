import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { dlopen, FFIType } from "bun:ffi";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setSessionProxy, type SessionProxy } from "../proc/sessionProxy";

const proxy: SessionProxy = {
	type: "http",
	host: "127.0.0.1",
	port: 8080,
	matchDomains: ["localhost"],
};

function readWrapper(platform: string): string {
	return readFileSync(
		new URL(`../../../native/${platform}/nativeWrapper.${platform === "macos" ? "mm" : "cpp"}`, import.meta.url),
		"utf8",
	);
}

function cString(value: string): Buffer {
	return Buffer.from(`${value}\0`, "utf8");
}

describe("Session.setProxy", () => {
	it("throws instead of ignoring the proxy where it is unsupported", () => {
		const calls: string[] = [];
		const symbols = {
			supportsProxy: () => false,
			setProxy: (partition: string) => (calls.push(partition), true),
		};
		expect(() => setSessionProxy(symbols, "persist:a", proxy)).toThrow(/not supported/);
		expect(() => setSessionProxy(symbols, "persist:a", null)).toThrow(/not supported/);
		expect(calls).toEqual([]);
	});

	it("rejects an invalid proxy before calling native code", () => {
		const calls: string[] = [];
		const symbols = {
			supportsProxy: () => true,
			setProxy: (partition: string) => (calls.push(partition), true),
		};
		const invalid = [
			{ ...proxy, type: "https" },
			{ ...proxy, host: "" },
			{ ...proxy, port: 0 },
			{ ...proxy, port: 65536 },
			{ ...proxy, port: 80.5 },
			{ ...proxy, matchDomains: [""] },
			{ ...proxy, excludedDomains: "localhost" },
		] as unknown as SessionProxy[];
		for (const config of invalid) {
			expect(() => setSessionProxy(symbols, "persist:a", config)).toThrow(TypeError);
		}
		expect(calls).toEqual([]);
	});

	it("passes the proxy as JSON and reports a native refusal", () => {
		const calls: [string, string][] = [];
		let accept = true;
		const symbols = {
			supportsProxy: () => true,
			setProxy: (partition: string, json: string) => (calls.push([partition, json]), accept),
		};
		setSessionProxy(symbols, "persist:a", proxy);
		setSessionProxy(symbols, "persist:a", null);
		expect(calls).toEqual([
			["persist:a", JSON.stringify(proxy)],
			["persist:a", "null"],
		]);
		accept = false;
		expect(() => setSessionProxy(symbols, "persist:a", proxy)).toThrow(/Failed to set the proxy/);
	});

	it.each(["linux", "win"])("reports session proxies unsupported on %s", (platform) => {
		const source = readWrapper(platform);
		expect(source).toMatch(/\bbool sessionSupportsProxy\(\) \{\s*return false;\s*\}/);
		expect(source).toMatch(/\bbool sessionSetProxy\([^)]*\) \{(?:\s*\(void\)\w+;)*\s*return false;\s*\}/);
	});
});

(process.platform === "darwin" ? describe : describe.skip)("WebKit session proxy", () => {
	const compileTimeoutMs = 60_000;
	let directory: string | undefined;
	let library: string;

	beforeAll(() => {
		directory = mkdtempSync(join(tmpdir(), "electrobun-proxy-"));
		const source = readWrapper("macos");
		const start = source.indexOf("NSUUID *UUIDFromString");
		const end = source.indexOf("static NSString *normalizeViewsRelativePath", start);
		expect(start).toBeGreaterThan(0);
		expect(end).toBeGreaterThan(start);
		const fixture = join(directory, "proxy.mm");
		library = join(directory, "proxy.dylib");
		// the wrapper's main-thread helper lives elsewhere; bun:test already runs on the main thread
		writeFileSync(
			fixture,
			[
				"#import <CommonCrypto/CommonDigest.h>",
				"#import <Network/Network.h>",
				"#import <WebKit/WebKit.h>",
				source.slice(start, end),
				"static bool runOnMainThreadSyncBool(bool (^block)(void)) { return block(); }",
				"static WKWebsiteDataStore *liveStore;",
				'extern "C" void openStore(const char *partition) { liveStore = createDataStoreForPartition(partition); }',
				'extern "C" int liveStoreProxyCount() { return (int)liveStore.proxyConfigurations.count; }',
				'extern "C" int newStoreProxyCount(const char *partition) { return (int)createDataStoreForPartition(partition).proxyConfigurations.count; }',
			].join("\n"),
		);
		execFileSync(
			"clang++",
			["-dynamiclib", "-fobjc-arc", "-std=c++20", fixture, "-framework", "Foundation", "-framework", "WebKit", "-framework", "Network", "-o", library],
			{ timeout: compileTimeoutMs },
		);
	}, compileTimeoutMs + 5_000);

	afterAll(() => {
		if (directory) rmSync(directory, { recursive: true, force: true });
	});

	it("applies the proxy to the partition's open and future data stores", () => {
		const native = dlopen(library, {
			sessionSupportsProxy: { args: [], returns: FFIType.bool },
			sessionSetProxy: { args: [FFIType.cstring, FFIType.cstring], returns: FFIType.bool },
			openStore: { args: [FFIType.cstring], returns: FFIType.void },
			liveStoreProxyCount: { args: [], returns: FFIType.i32 },
			newStoreProxyCount: { args: [FFIType.cstring], returns: FFIType.i32 },
		} as const);
		try {
			// proxyConfigurations needs macOS 14; older systems must report unsupported
			const majorVersion = Number(execFileSync("sw_vers", ["-productVersion"]).toString().split(".")[0]);
			expect(native.symbols.sessionSupportsProxy()).toBe(majorVersion >= 14);
			if (majorVersion < 14) return;

			const symbols = {
				supportsProxy: () => native.symbols.sessionSupportsProxy(),
				setProxy: (partition: string, json: string) =>
					native.symbols.sessionSetProxy(cString(partition), cString(json)),
			};
			// an ephemeral partition gives every view its own data store
			const partition = "proxy-test";
			native.symbols.openStore(cString(partition));
			expect(native.symbols.liveStoreProxyCount()).toBe(0);

			setSessionProxy(symbols, partition, { ...proxy, excludedDomains: ["example.com"] });
			expect(native.symbols.liveStoreProxyCount()).toBe(1);
			expect(native.symbols.newStoreProxyCount(cString(partition))).toBe(1);
			expect(native.symbols.newStoreProxyCount(cString("other-partition"))).toBe(0);

			setSessionProxy(symbols, partition, { type: "socks5", host: "localhost", port: 1080 });
			expect(native.symbols.liveStoreProxyCount()).toBe(1);

			setSessionProxy(symbols, partition, null);
			expect(native.symbols.liveStoreProxyCount()).toBe(0);
			expect(native.symbols.newStoreProxyCount(cString(partition))).toBe(0);

			expect(native.symbols.sessionSetProxy(cString(partition), cString('{"type":"ftp","host":"h","port":1}'))).toBe(false);
			expect(native.symbols.sessionSetProxy(cString(partition), cString("not json"))).toBe(false);
		} finally {
			native.close();
		}
	});
});
