import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const src = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (relativePath) => readFileSync(join(src, relativePath), "utf8");

// The body of the first Objective-C method whose selector starts with `head`.
// Declarations are skipped: a definition's `{` comes before any `;`.
function methodBody(source, head) {
	let start = source.indexOf(head);
	while (start !== -1) {
		const brace = source.indexOf("{", start);
		const semicolon = source.indexOf(";", start);
		if (brace !== -1 && (semicolon === -1 || brace < semicolon)) break;
		start = source.indexOf(head, start + head.length);
	}
	assert.notEqual(start, -1, `missing ${head}`);
	const open = source.indexOf("{", start);
	let depth = 0;
	for (let index = open; index < source.length; index++) {
		if (source[index] === "{") depth++;
		if (source[index] === "}" && --depth === 0) {
			return source.slice(open, index + 1);
		}
	}
	throw new Error(`unterminated ${head}`);
}

test("macOS builds previews from public WebKit isolation APIs", () => {
	const helper = read("native/macos/isolated_preview.h");

	assert.match(helper, /\[WKWebsiteDataStore nonPersistentDataStore\]/);
	assert.match(helper, /lockdownModeEnabled = YES/);
	assert.match(helper, /javaScriptCanOpenWindowsAutomatically = NO/);
	assert.match(helper, /compileContentRuleListForIdentifier:/);
	assert.match(helper, /@"url-filter" : @"\.\*"[\s\S]*@"type" : @"block"/);
	assert.match(helper, /setURLSchemeHandler:schemeHandler forURLScheme:scheme/);
	assert.match(helper, /handlesURLScheme:scheme/);
	assert.match(helper, /isEqualToString:@"views"/);
	assert.match(helper, /shouldPerformDownload/);
	assert.match(helper, /canShowMIMEType/);
	assert.doesNotMatch(helper, /setValue:|valueForKey:|_[a-z]+[A-Z]\w*:/);
});

test("macOS webviews apply every fence before the first preview load", () => {
	const wrapper = read("native/macos/nativeWrapper.mm");

	assert.match(wrapper, /#include "isolated_preview.h"/);
	assert.match(
		wrapper,
		/if \(isolatedPreviewScheme\) \{[\s\S]*?ElectrobunIsolatedPreviewSchemeHandler[\s\S]*?configureIsolatedPreview[\s\S]*?\} else \{[\s\S]*?forURLScheme:@"views"/,
	);
	assert.match(wrapper, /BOOL sandboxed = sandbox \|\| isolatedPreviewScheme != nil;/);
	assert.match(wrapper, /if \(!sandboxed\) \{[\s\S]*?"hostBridge"/);
	assert.match(wrapper, /loadIsolatedPreviewContentRuleList\(/);

	const finish = methodBody(wrapper, "- (void)finishIsolatedPreviewSetup:");
	assert.match(finish, /if \(!ruleList\) \{[\s\S]*?return;[\s\S]*?\}[\s\S]*?addContentRuleList:ruleList[\s\S]*?isolatedPreviewReady = YES/);

	const load = methodBody(wrapper, "- (void)loadURLOnMainThread:");
	assert.match(load, /isolatedPreviewAllowsNavigation[\s\S]*?return;[\s\S]*?pendingIsolatedPreviewURL = urlString;[\s\S]*?return;[\s\S]*?loadFileURL/);

	const html = methodBody(
		wrapper,
		"- (void)loadHTML:(const char *)htmlString {\n  // The caller's FFI buffer",
	);
	assert.match(html, /isolatedPreviewScheme[\s\S]*?return;[\s\S]*?loadHTMLString/);

	const init = methodBody(wrapper, 'extern "C" AbstractView *initWebview(');
	assert.match(init, /g_nextWebviewIsolatedPreviewScheme = nil;/);
	assert.match(init, /isolatedPreviewScheme && \(!sandbox \|\| strcmp\(renderer, "native"\) != 0\)[\s\S]*?return nil;/);
});

test("macOS delegates deny navigation, downloads, popups and permissions", () => {
	const wrapper = read("native/macos/nativeWrapper.mm");

	const action = methodBody(wrapper, "- (void)webView:(WKWebView *)webView\n    decidePolicyForNavigationAction:");
	assert.match(action, /if \(self\.isolatedPreviewScheme\) \{[\s\S]*?isolatedPreviewReady &&[\s\S]*?isolatedPreviewNavigationActionPolicy[\s\S]*?return;/);
	assert.ok(action.indexOf("isolatedPreviewScheme") < action.indexOf("strdup(\"new-window-open\")"));

	const response = methodBody(wrapper, "- (void)webView:(WKWebView *)webView\n    decidePolicyForNavigationResponse:");
	assert.match(response, /isolatedPreviewScheme[\s\S]*?isolatedPreviewNavigationResponsePolicy[\s\S]*?return;/);

	for (const head of [
		"- (WKWebView *)webView:(WKWebView *)webView\n    createWebViewWithConfiguration:",
		"- (void)webView:(WKWebView *)webView\n    runOpenPanelWithParameters:",
		"- (void)webView:(WKWebView *)webView\n    requestMediaCapturePermissionForOrigin:",
		"- (void)webView:(WKWebView *)webView\n    requestGeolocationPermissionForOrigin:",
	]) {
		const body = methodBody(wrapper, head);
		const guard = body.indexOf("if (self.isolatedPreview)");
		assert.notEqual(guard, -1, `${head} must check isolatedPreview`);
		for (const grant of ["WKPermissionDecisionGrant", "runModal", "strdup(\"new-window-open\")"]) {
			const index = body.indexOf(grant);
			assert.ok(index === -1 || guard < index, `${head} must deny before ${grant}`);
		}
	}

	const downloads = wrapper.match(/didBecomeDownload:\(WKDownload \*\)download[^{]*\{[\s\S]*?\n\}/g);
	assert.equal(downloads?.length, 2);
	for (const body of downloads) {
		assert.match(body, /isolatedPreviewScheme\) \{\s*\[download cancel:nil\];\s*return;/);
	}
});

test("Linux and Windows report isolated previews unsupported", () => {
	for (const file of ["native/linux/nativeWrapper.cpp", "native/win/nativeWrapper.cpp"]) {
		const wrapper = read(file);
		for (const symbol of [
			"isolatedPreviewSupported",
			"setNextWebviewIsolatedPreview",
			"webviewIsolatedPreviewRespond",
		]) {
			assert.match(
				wrapper,
				new RegExp(`ELECTROBUN_EXPORT bool ${symbol}\\([^)]*\\) \\{[^}]*return false;\\s*\\}`),
				`${file} ${symbol}`,
			);
		}
	}
	const mac = read("native/macos/nativeWrapper.mm");
	assert.match(mac, /extern "C" bool isolatedPreviewSupported\(\) \{ return true; \}/);
});

test("core and the TypeScript SDK route requests and refuse unsupported previews", () => {
	const core = read("core/main.zig");
	assert.match(core, /export fn isolatedPreviewSupported\(\) bool/);
	assert.match(core, /export fn setNextWebviewIsolatedPreview\(scheme: \[\*:0\]const u8\) bool/);
	assert.match(core, /export fn webviewIsolatedPreviewRespond\(/);
	assert.match(core, /params_object\.get\("isolatedPreview"\)/);
	assert.match(core, /isolated_preview: \?\[\]const u8 = if \(params_object\.get\("isolatedPreview"\)\) \|value\| jsonString\(value\) orelse "" else null;/);
	assert.match(core, /sandbox or isolated_preview != null/);

	const native = read("sdks/main/proc/native.ts");
	const handler = native.slice(
		native.indexOf("const webviewEventHandler = "),
		native.indexOf("const webviewEventJSCallback = "),
	);
	assert.match(
		handler,
		/BrowserView\.ensureWrapped\(id\);\s*\/\/[^\n]*\n[^\n]*\n\s*if \(eventName === "isolated-preview-request"\) \{\s*return \{ success: false \};/,
		"event-bridge copies of scheme requests must be dropped before dispatch",
	);
	const callback = native.slice(native.indexOf("const webviewEventJSCallback = "));
	assert.match(
		callback.slice(0, callback.indexOf("webviewEventHandler(id, eventName, detail)")),
		/eventName === "isolated-preview-request"[\s\S]*?answerIsolatedPreviewRequest\(id, detail\);\s*return;/,
		"only the native callback answers scheme requests",
	);
	assert.match(native, /setNextWebviewIsolatedPreview\(toCString\(isolatedPreview\)\)[\s\S]*?throw/);
	assert.match(native, /isolatedPreview === undefined \? null : \{ scheme: isolatedPreview \}/);

	const view = read("sdks/main/core/BrowserView.ts");
	assert.match(view, /static isIsolatedPreviewSupported\(\): boolean/);
	assert.match(view, /if \(!BrowserView\.isIsolatedPreviewSupported\(\)\) \{\s*throw new Error/);
	assert.match(view, /this\.renderer !== "native"[\s\S]*?throw new Error/);
	assert.match(view, /this\.sandbox = true;/);
	assert.match(view, /setIsolatedPreviewHandler\(handler: IsolatedPreviewHandler \| null\)/);
	assert.match(view, /new Response\("Not found", \{ status: 404 \}\)/);

	const tag = read("preload/webviewTag.ts");
	assert.match(tag, /getAttribute\("isolated-preview"\)/);
	assert.match(tag, /hasAttribute\("sandbox"\) \|\| isolatedPreview !== null/);
});
