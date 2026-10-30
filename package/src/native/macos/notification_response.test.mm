#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

#include <cstdio>
#include <cstring>

#include "notification_response.h"

static int failures = 0;

#define CHECK(condition, message) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "FAIL: %s\n", message); \
            ++failures; \
        } \
    } while (false)

static bool eventIs(const char *event, const char *expected)
{
    return event && std::strcmp(event, expected) == 0;
}

int main()
{
    @autoreleasepool {
        CHECK(eventIs(electrobun::notificationResponseEvent(UNNotificationDefaultActionIdentifier), "click"),
            "the default action reports a click");
        CHECK(eventIs(electrobun::notificationResponseEvent(UNNotificationDismissActionIdentifier), "dismiss"),
            "the dismiss action reports a dismissal");
        CHECK(electrobun::notificationResponseEvent(@"reply") == nullptr,
            "an app-defined action reports nothing");
        CHECK(electrobun::notificationResponseEvent(nil) == nullptr,
            "a missing action reports nothing");

        // This test binary has no Info.plist, so asking for the center would raise.
        CHECK([[NSBundle mainBundle] bundleIdentifier] == nil,
            "the test binary runs without a bundle identifier");
        CHECK(electrobun::notificationCenterIfAvailable([NSBundle mainBundle]) == nil,
            "an unbundled process gets no notification center instead of an exception");
    }

    if (failures) {
        std::fprintf(stderr, "%d notification response check(s) failed\n", failures);
        return 1;
    }
    std::printf("PASS: notification responses map to click and dismiss events\n");
    return 0;
}
