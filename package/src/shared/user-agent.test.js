import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const src = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (relativePath) => readFileSync(join(src, relativePath), "utf8");

test("macOS WKWebView applies the user agent before its first load", () => {
	const helper = read("native/macos/user_agent.h");
	const wrapper = read("native/macos/nativeWrapper.mm");

	assert.match(helper, /customUserAgent = userAgent\.length > 0 \? userAgent : nil/);
	assert.match(helper, /inContentWorld:WKContentWorld\.defaultClientWorld/);
	assert.match(
		wrapper,
		/self\.webView = \[\[WKWebView alloc\] initWithFrame:frame\s+configuration:configuration\];\s+if \(self\.pendingUserAgent\) \{\s+electrobun::setCustomUserAgent/,
	);
	assert.match(
		wrapper,
		/setCustomUserAgent\(self\.webView, self\.pendingUserAgent\)[\s\S]*?loadURLOnMainThread:\[NSString stringWithUTF8String:url\]/,
	);
	assert.match(wrapper, /extern "C" bool webviewSetUserAgent\(AbstractView \*abstractView,/);
	assert.match(wrapper, /extern "C" const char \*getDefaultUserAgent\(\)/);
});

test("CEF and non-macOS native renderers report unsupported", () => {
	const mac = read("native/macos/nativeWrapper.mm");
	const windows = read("native/win/nativeWrapper.cpp");
	const linux = read("native/linux/nativeWrapper.cpp");

	assert.match(
		mac,
		/@implementation AbstractView[\s\S]*?- \(BOOL\)setUserAgent:\(NSString \*\)userAgent \{\s+\(void\)userAgent;\s+return NO;/,
	);
	assert.doesNotMatch(
		mac.slice(mac.indexOf("@implementation CEFWebViewImpl")),
		/- \(BOOL\)setUserAgent:/,
	);
	for (const wrapper of [windows, linux]) {
		assert.match(
			wrapper,
			/bool webviewSetUserAgent\([^)]*\) \{[^}]*return false;\s*\}/,
		);
		assert.match(
			wrapper,
			/const char\* getDefaultUserAgent\(\) \{[^}]*return nullptr;\s*\}/,
		);
	}
});

test("core forwards both symbols and reports a missing wrapper as unsupported", () => {
	const core = read("core/main.zig");

	assert.match(
		core,
		/export fn webviewSetUserAgent\(webview_id: u32, user_agent: \[\*:0\]const u8\) bool \{[\s\S]*?"webviewSetUserAgent",\s+\) orelse return false;/,
	);
	assert.match(
		core,
		/export fn getDefaultUserAgent\(\) \?\[\*:0\]const u8 \{[\s\S]*?"getDefaultUserAgent",\s+\) orelse return null;/,
	);
});

test("BrowserView sets the user agent before loading its URL", () => {
	const view = read("sdks/main/core/BrowserView.ts");
	const ffi = read("sdks/main/proc/native.ts");

	assert.match(view, /userAgent: string \| null;/);
	assert.match(view, /url: this\.html \|\| this\.userAgent \? null : this\.url/);
	assert.match(
		view,
		/this\.id = this\.init\(\) as number;[\s\S]*?if \(!this\.setUserAgent\(this\.userAgent\)\) \{[\s\S]*?console\.warn[\s\S]*?this\.loadURL\(this\.url\)/,
	);
	assert.match(
		view,
		/setUserAgent\(userAgent: string \| null\): boolean \{[\s\S]*?if \(applied\) \{[\s\S]*?return applied;/,
	);
	assert.match(view, /static getDefaultUserAgent\(\): string \| null \{/);
	assert.match(ffi, /webviewSetUserAgent: \{\s+args: \[FFIType\.u32, FFIType\.cstring\],\s+returns: FFIType\.bool,/);
	assert.match(ffi, /getDefaultUserAgent: \{\s+args: \[\],\s+returns: FFIType\.cstring,/);
});
