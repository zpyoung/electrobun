import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import webviewEvents from "../sdks/main/events/webviewEvents";

const sourceRoot = join(import.meta.dirname, "..");

function readSource(relativePath: string): string {
	return readFileSync(join(sourceRoot, relativePath), "utf8");
}

const sources = {
	core: readSource("core/main.zig"),
	typescript: readSource("sdks/main/proc/native.ts"),
	browserView: readSource("sdks/main/core/BrowserView.ts"),
	preloadTag: readSource("preload/webviewTag.ts"),
	browserTag: readSource("browser/webviewtag.ts"),
	darwin: readSource("native/macos/nativeWrapper.mm"),
	linux: readSource("native/linux/nativeWrapper.cpp"),
	win32: readSource("native/win/nativeWrapper.cpp"),
};

const nativeSymbols = [
	"webviewReloadIgnoringCache",
	"webviewSupportsReloadIgnoringCache",
	"webviewSupportsLoadFailed",
] as const;

const tagRequests = [
	"webviewTagReloadIgnoringCache",
	"webviewTagSupportsReloadIgnoringCache",
	"webviewTagSupportsLoadFailed",
] as const;

function section(source: string, startMarker: string, endMarker: string): string {
	const start = source.indexOf(startMarker);
	const end = source.indexOf(endMarker, start + startMarker.length);
	if (start === -1 || end === -1) {
		throw new Error(`Could not find ${startMarker}`);
	}
	return source.slice(start, end);
}

function functionBody(source: string, signature: string): string {
	return section(source, signature, "\n}\n");
}

describe("cache-bypassing reload and load-failed contract", () => {
	test("every layer carries the native symbols", () => {
		for (const symbol of nativeSymbols) {
			expect(sources.core).toContain(`export fn ${symbol}(webview_id: u32) bool {`);
			expect(sources.core).toContain(`"${symbol}",`);
			expect(sources.typescript).toContain(`\t\t\t${symbol}: {\n\t\t\t\targs: [FFIType.u32],\n\t\t\t\treturns: FFIType.bool,`);
			expect(sources.typescript).toContain(`\t\t${symbol}: (params: { id: number }) => {`);
		}
	});

	test("the webview tag reaches the native symbols", () => {
		tagRequests.forEach((request, index) => {
			expect(sources.preloadTag).toContain(`request("${request}", {`);
			expect(sources.typescript).toContain(
				`${request}: (params: { id: number }) => {\n\t\t\treturn core_.symbols.${nativeSymbols[index]}(params.id);`,
			);
			expect(sources.core).toContain(`std.mem.eql(u8, method, "${request}")`);
		});
		expect(sources.browserTag).toContain("reloadIgnoringCache(): Promise<boolean>;");
		expect(sources.browserTag).toContain('| "load-failed";');
		expect(sources.preloadTag).toContain('| "load-failed";');
		expect(sources.browserView).toContain("reloadIgnoringCache(): boolean {");
		expect(sources.browserView).toContain('| "load-failed",');
	});

	test("macOS WKWebView reloads from origin and reports navigation failures", () => {
		const wkWebView = section(sources.darwin, "@implementation WKWebViewImpl", "\n@end");
		expect(wkWebView).toMatch(/- \(void\)reloadIgnoringCache \{\n\s+\[self\.webView reloadFromOrigin\];/);
		expect(wkWebView).toMatch(/- \(BOOL\)supportsReloadIgnoringCache \{\n\s+return YES;/);
		expect(wkWebView).toMatch(/- \(BOOL\)supportsLoadFailed \{\n\s+return YES;/);

		const abstractView = section(sources.darwin, "@implementation AbstractView", "\n@end");
		expect(abstractView).toMatch(/- \(BOOL\)supportsReloadIgnoringCache \{\n\s+return NO;/);
		expect(abstractView).toMatch(/- \(BOOL\)supportsLoadFailed \{\n\s+return NO;/);

		const delegate = section(sources.darwin, "@implementation MyNavigationDelegate", "\n@end");
		for (const callback of ["didFailProvisionalNavigation", "didFailNavigation"]) {
			const handler = section(delegate, `${callback}:(WKNavigation *)navigation`, "\n}");
			expect(handler).toContain("electrobun::loadFailedEventDetail(error, webView.URL)");
			expect(handler).toContain('strdup("load-failed")');
		}

		const reload = functionBody(sources.darwin, 'extern "C" bool webviewReloadIgnoringCache(');
		expect(reload).toContain("![abstractView supportsReloadIgnoringCache]");
		expect(reload).toContain("[abstractView reloadIgnoringCache];");
	});

	test.each(["linux", "win32"] as const)(
		"%s reports both features unsupported",
		(platform) => {
			for (const symbol of nativeSymbols) {
				const body = functionBody(
					sources[platform],
					`ELECTROBUN_EXPORT bool ${symbol}(AbstractView* abstractView) {`,
				);
				expect(body).toContain("return false;");
				expect(body).not.toContain("reload(");
			}
		},
	);

	test("load-failed detail is delivered as an object", () => {
		expect(sources.typescript).toContain('"load-failed": "loadFailed",');
		expect(sources.typescript).toContain('eventName === "load-failed"\n\t) {\n\t\ttry {\n\t\t\tparsedDetail = JSON.parse(detail);');
		expect(sources.core).toContain('std.mem.eql(u8, event_name_slice, "load-failed"))');
		expect(sources.core).toContain('if (std.mem.eql(u8, event_name, "load-failed")) return false;');

		const detail = {
			url: "http://127.0.0.1:9/",
			domain: "NSURLErrorDomain",
			code: -1004,
			description: "Could not connect to the server.",
		};
		const event = webviewEvents.loadFailed({ detail });
		expect(event.name).toBe("load-failed");
		expect(event.data.detail).toEqual(detail);
	});
});
