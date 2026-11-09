#pragma once

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

namespace electrobun {

// The event a notification response reports, or nullptr for an action the
// app registered itself.
inline const char *notificationResponseEvent(NSString *actionIdentifier)
{
    if ([actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier])
        return "click";
    if ([actionIdentifier isEqualToString:UNNotificationDismissActionIdentifier])
        return "dismiss";
    return nullptr;
}

// currentNotificationCenter raises when the process has no bundle identifier.
inline UNUserNotificationCenter *notificationCenterIfAvailable(NSBundle *bundle)
{
    if (![bundle bundleIdentifier])
        return nil;
    @try {
        return [UNUserNotificationCenter currentNotificationCenter];
    } @catch (NSException *exception) {
        NSLog(@"Notification center unavailable: %@", exception);
        return nil;
    }
}

} // namespace electrobun
