import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const src = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (relativePath) => readFileSync(join(src, relativePath), "utf8");

test("macOS WKWebViews report accepted file drops through the webview event handler", () => {
	const helper = read("native/macos/drop_source_paths.h");
	const wrapper = read("native/macos/nativeWrapper.mm");

	assert.match(helper, /@interface ElectrobunWKWebView : WKWebView/);
	assert.match(
		helper,
		/performDragOperation:[\s\S]*dropSourcePaths\(sender\.draggingPasteboard\)[\s\S]*\[super performDragOperation:sender\][\s\S]*dropSourcePathsHandler\(paths\)/,
	);
	assert.match(helper, /NSPasteboardURLReadingFileURLsOnlyKey/);
	assert.match(wrapper, /\[\[ElectrobunWKWebView alloc\] initWithFrame:frame/);
	assert.match(wrapper, /webviewEventHandler\(webviewId, strdup\("drop-source-paths"\)/);
	assert.match(wrapper, /extern "C" bool webviewSupportsDropSourcePaths/);
});

test("CEF and non-macOS native renderers report unsupported", () => {
	const mac = read("native/macos/nativeWrapper.mm");
	const windows = read("native/win/nativeWrapper.cpp");
	const linux = read("native/linux/nativeWrapper.cpp");

	assert.match(mac, /@implementation AbstractView[\s\S]*supportsDropSourcePaths \{\s*return NO;/);
	assert.match(mac, /@implementation WKWebViewImpl[\s\S]*supportsDropSourcePaths \{\s*return YES;/);
	for (const wrapper of [windows, linux]) {
		assert.match(
			wrapper,
			/webviewSupportsDropSourcePaths\([\s\S]*?\{[\s\S]*?return false;[\s\S]*?\}/,
		);
	}
});

test("the main-process SDK exposes the event and the support query", () => {
	const native = read("sdks/main/proc/native.ts");
	const events = read("sdks/main/events/webviewEvents.ts");
	const browserView = read("sdks/main/core/BrowserView.ts");
	const core = read("core/main.zig");

	assert.match(native, /"drop-source-paths": "dropSourcePaths"/);
	assert.match(native, /eventName === "drop-source-paths"/);
	assert.match(events, /dropSourcePaths:[\s\S]*"drop-source-paths"/);
	assert.match(browserView, /\| "drop-source-paths"/);
	assert.match(browserView, /supportsDropSourcePaths\(\): boolean/);
	assert.match(core, /export fn webviewSupportsDropSourcePaths/);
});
