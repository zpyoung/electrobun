#pragma once

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

namespace electrobun {

// nil or an empty string clears the override so WebKit's default applies again.
inline void setCustomUserAgent(WKWebView *webView, NSString *userAgent)
{
    webView.customUserAgent = userAgent.length > 0 ? userAgent : nil;
}

// Runs in the client world so a page that redefines navigator.userAgent can't change the answer.
inline void readUserAgent(WKWebView *webView, void (^completion)(NSString *userAgent))
{
    [webView evaluateJavaScript:@"navigator.userAgent"
                        inFrame:nil
                 inContentWorld:WKContentWorld.defaultClientWorld
              completionHandler:^(id result, NSError *error) {
                  completion(!error && [result isKindOfClass:[NSString class]] ? result : nil);
              }];
}

inline WKWebView *createDefaultUserAgentProbe()
{
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    return [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1) configuration:configuration];
}

} // namespace electrobun
