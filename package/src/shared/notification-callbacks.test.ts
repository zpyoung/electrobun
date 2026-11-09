import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const packageRoot = join(import.meta.dirname, "..");
const read = (path: string) => readFileSync(join(packageRoot, path), "utf8");

const macos = read("native/macos/nativeWrapper.mm");
const linux = read("native/linux/nativeWrapper.cpp");
const windows = read("native/win/nativeWrapper.cpp");
const core = read("core/main.zig");
const bunNative = read("sdks/main/proc/native.ts");
const utils = read("sdks/main/core/Utils.ts");
const appEvents = read("sdks/main/events/ApplicationEvents.ts");

const nativeSymbols = [
	"setNotificationHandlers",
	"requestNotificationPermission",
	"showNotificationWithId",
];

describe("notification permission and response callbacks", () => {
	it("reports clicks and dismissals from UNUserNotificationCenter on macOS", () => {
		expect(macos).toContain(
			"@interface ElectrobunNotificationDelegate\n    : NSObject <UNUserNotificationCenterDelegate>",
		);
		// notification_response.test.mm covers the action-to-event mapping natively.
		expect(macos).toContain('#include "notification_response.h"');
		expect(macos).toContain(
			"electrobun::notificationResponseEvent(response.actionIdentifier);",
		);
		expect(macos).toContain(
			"strdup(response.notification.request.identifier.UTF8String));",
		);
		expect(macos).toContain("completionHandler();");
		// Without the opt-in category macOS never delivers the dismiss action.
		expect(macos).toContain(
			"options:UNNotificationCategoryOptionCustomDismissAction];",
		);
		expect(macos).toContain(
			"content.categoryIdentifier = kElectrobunNotificationCategory;",
		);
	});

	it("uses the caller's id as the notification request identifier", () => {
		expect(macos).toContain(
			'extern "C" void showNotificationWithId(const char *title, const char *body,',
		);
		expect(macos).toContain("? [NSString stringWithUTF8String:notificationId]");
		expect(macos).toContain(
			"showNotificationWithId(title, body, subtitle, silent, nullptr);",
		);
	});

	it("reads and requests authorization without blocking the caller", () => {
		expect(macos).toContain(
			'extern "C" void requestNotificationPermission(uint32_t requestId, BOOL prompt) {',
		);
		expect(macos).toContain("getNotificationSettingsWithCompletionHandler:");
		expect(macos).toContain("(int32_t)settings.authorizationStatus");
		expect(macos).toContain("requestAuthorizationWithOptions:");
	});

	it("never touches the notification center without a bundle identifier", () => {
		expect(macos).not.toContain("[UNUserNotificationCenter currentNotificationCenter]");
		expect(
			macos.match(
				/electrobun::notificationCenterIfAvailable\(\[NSBundle mainBundle\]\)/g,
			),
		).toHaveLength(3);
		expect(macos).toContain(
			"reportNotificationPermission(requestId, kNotificationPermissionUnavailable);",
		);
	});

	it("keeps the callbacks out of the Linux and Windows wrapper ABI", () => {
		for (const symbol of nativeSymbols) {
			expect(linux).not.toContain(symbol);
			expect(windows).not.toContain(symbol);
		}
	});

	it("reports the platform unsupported through ElectrobunCore", () => {
		expect(core).toContain(
			'lookupOptionalNativeSymbol(\n        SetNotificationHandlersFn,\n        "setNotificationHandlers",\n    ) orelse return false;',
		);
		expect(core).toContain(
			'lookupOptionalNativeSymbol(\n        RequestNotificationPermissionFn,\n        "requestNotificationPermission",\n    ) orelse return false;',
		);
		expect(core).toContain(
			") orelse return showNotification(title, body, subtitle, silent);",
		);
		for (const symbol of nativeSymbols) {
			expect(core).toContain(`export fn ${symbol}(`);
			expect(bunNative).toMatch(new RegExp(`^\\t{3}${symbol}: \\{$`, "m"));
		}
	});

	it("resolves unsupported instead of waiting forever", () => {
		expect(bunNative).toContain(
			"notificationEventsSupported = core_.symbols.setNotificationHandlers(",
		);
		expect(bunNative).toMatch(
			/!notificationEventsSupported \|\|\n\s+!core_\.symbols\.requestNotificationPermission\(requestId, params\.prompt\)\n\s+\) \{\n\s+notificationPermissionRequests\.delete\(requestId\);\n\s+resolve\("unsupported"\);/,
		);
		expect(bunNative).toContain(
			'resolve(notificationPermissionByStatus[status] ?? "unsupported");',
		);
	});

	it("maps UNAuthorizationStatus values in order", () => {
		expect(bunNative).toContain(
			'const notificationPermissionByStatus: readonly NotificationPermission[] = [\n\t"not-determined",\n\t"denied",\n\t"authorized",\n\t"provisional",\n];',
		);
	});

	it("exposes the permission API, notification ids and response events", () => {
		expect(utils).toContain(
			"export const getNotificationPermission = (): Promise<NotificationPermission> => {",
		);
		expect(utils).toContain("export const requestNotificationPermission =");
		expect(utils).toContain(
			"export const showNotification = (options: NotificationOptions): string => {",
		);
		expect(utils).toContain("id = crypto.randomUUID()");
		expect(appEvents).toContain('"notification-click"');
		expect(appEvents).toContain('"notification-dismiss"');
		expect(bunNative).toContain("events.notificationClick({ id })");
		expect(bunNative).toContain("events.notificationDismiss({ id })");
	});
});
