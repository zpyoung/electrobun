#pragma once

#import <Foundation/Foundation.h>

namespace electrobun {

// Builds the JSON detail of a `load-failed` webview event from a WebKit
// navigation error: the failing URL, the error domain and code, and the
// localized description. `fallbackURL` is used when the error carries no URL.
inline NSString *loadFailedEventDetail(NSError *error, NSURL *fallbackURL)
{
    NSString *url = nil;
    id failingURL = error.userInfo[NSURLErrorFailingURLErrorKey];
    if ([failingURL isKindOfClass:[NSURL class]])
        url = [failingURL absoluteString];
    if (!url.length)
        url = fallbackURL.absoluteString ?: @"";

    NSDictionary *detail = @{
        @"url" : url,
        @"domain" : error.domain ?: @"",
        @"code" : @(error.code),
        @"description" : error.localizedDescription ?: @"",
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:detail options:0 error:nil];
    if (!json)
        return @"{}";
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

} // namespace electrobun
