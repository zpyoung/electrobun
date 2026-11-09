import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const src = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (relativePath) => readFileSync(join(src, relativePath), "utf8");

const nativeExports = [
	"webviewSetNativeRequestHandling",
	"webviewRespondToNativeRequest",
	"webviewCancelDownload",
	"setNextWebviewPopupRequest",
];

const requestEvents = [
	"dialog-request",
	"auth-request",
	"certificate-request",
	"download-request",
	"popup-request",
	"external-app-request",
	"native-request-expired",
	"close-requested",
];

test("pending requests resolve once and time out to a fail-closed answer", () => {
	const registry = read("native/macos/native_requests.h");

	assert.match(registry, /class NativeRequestRegistry/);
	assert.match(registry, /dispatch_after[\s\S]*expire\(requestId, @"timeout"\)/);
	assert.match(registry, /pending_\.erase\(it\);\s*resolver\(response/);
	assert.match(registry, /entry\.resolver\(nil\)/);
	assert.match(registry, /NSURLCredentialPersistenceNone/);
	assert.match(registry, /handlesURLScheme:/);
	assert.match(registry, /urlSchemeHandlerForURLScheme:/);
});

test("WKWebView delegates route page requests through the registry", () => {
	const mac = read("native/macos/nativeWrapper.mm");

	for (const selector of [
		"runJavaScriptAlertPanelWithMessage:",
		"runJavaScriptConfirmPanelWithMessage:",
		"runJavaScriptTextInputPanelWithPrompt:",
		"didReceiveAuthenticationChallenge:",
		"decideDestinationUsingResponse:",
		"createWebViewWithConfiguration:",
		"webViewDidClose:",
	]) {
		assert.match(mac, new RegExp(`${selector}[\\s\\S]*?(startNativeRequest|parkPopupWithConfiguration|close-requested)`));
	}

	// a JavaScript dialog without an opted-in app keeps WebKit's default answer
	assert.match(mac, /runJavaScriptConfirmPanelWithMessage:[\s\S]*?if \(!view\) \{\s*completionHandler\(NO\);/);
	assert.match(mac, /runJavaScriptTextInputPanelWithPrompt:[\s\S]*?if \(!view\) \{\s*completionHandler\(nil\);/);
	// only untrusted certificates are offered to the app
	assert.match(mac, /SecTrustEvaluateAsyncWithError[\s\S]*?if \(trusted \|\| view\.isRemoved\)/);
	assert.match(mac, /NSURLSessionAuthChallengeCancelAuthenticationChallenge/);
	// external apps open only after an accepted request
	assert.match(mac, /isExternalAppURL[\s\S]*?responseAccepted\(response\)\) \{\s*\[\[NSWorkspace sharedWorkspace\] openURL:newURL\]/);
	// removing a view resolves every pending completion handler
	assert.match(mac, /expireAllForWebview\(webviewIdForLogging, @"closed"\)/);
	// adoption reuses the WebKit-created popup instead of a fresh WKWebView
	assert.match(mac, /adoptParkedPopup:self\.pendingPopupRequestId/);
	assert.match(mac, /releaseToNavigationDelegate:navigationDelegate/);
	assert.match(mac, /popup\.openerSandboxed && !sandbox/);

	for (const name of nativeExports) {
		assert.match(mac, new RegExp(`extern "C" \\w+ ${name}\\(`));
	}
});

test("CEF and non-macOS native renderers report unsupported", () => {
	const mac = read("native/macos/nativeWrapper.mm");
	const windows = read("native/win/nativeWrapper.cpp");
	const linux = read("native/linux/nativeWrapper.cpp");

	assert.match(mac, /@implementation AbstractView[\s\S]*setNativeRequestHandling:[\s\S]*?return NO;/);
	for (const wrapper of [windows, linux]) {
		for (const name of nativeExports.slice(0, 3)) {
			assert.match(
				wrapper,
				new RegExp(`${name}\\([\\s\\S]*?\\{[\\s\\S]*?return false;[\\s\\S]*?\\}`),
			);
		}
		assert.match(wrapper, /ELECTROBUN_EXPORT void setNextWebviewPopupRequest\(/);
	}
});

test("core and the main-process SDK expose the request contract", () => {
	const core = read("core/main.zig");
	const native = read("sdks/main/proc/native.ts");
	const browserView = read("sdks/main/core/BrowserView.ts");
	const events = read("sdks/main/events/webviewEvents.ts");

	for (const name of nativeExports) {
		assert.match(core, new RegExp(`export fn ${name}\\(`));
		assert.match(native, new RegExp(`${name}: \\{`));
	}
	assert.match(native, /setNextWebviewPopupRequest\(popupRequestId \?\? 0\)/);
	for (const name of requestEvents) {
		assert.match(native, new RegExp(`"${name}": "\\w+"`));
		assert.match(events, new RegExp(`"${name}"`));
		assert.match(browserView, new RegExp(`\\| "${name}"`));
	}
	assert.match(browserView, /setNativeRequestHandling\(\s*kinds: NativeRequestKind\[\]/);
	assert.match(browserView, /respondToNativeRequest\(\s*requestId: number/);
	assert.match(browserView, /cancelDownload\(downloadId: number\): boolean/);
	assert.match(browserView, /popupRequestId: this\.popupRequestId/);
});
