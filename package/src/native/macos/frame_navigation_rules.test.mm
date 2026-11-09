#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include <cstdio>
#include <string>
#include <vector>

#include "../shared/navigation_rules.h"

static int failures = 0;

#define CHECK(condition, message) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "FAIL: %s\n", message); \
            ++failures; \
        } \
    } while (false)

// Decides navigations exactly as nativeWrapper's MyNavigationDelegate does, and records each decision.
@interface RulesDelegate : NSObject <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, assign) std::vector<std::string> rules;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *decisions;
@property (nonatomic, strong) NSMutableSet<NSString *> *loadedFrames;
@property (nonatomic, assign) BOOL finished;
@end

@implementation RulesDelegate

- (instancetype)initWithRules:(std::vector<std::string>)rules
{
    self = [super init];
    _rules = rules;
    _decisions = [NSMutableArray array];
    _loadedFrames = [NSMutableSet set];
    return self;
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    WKFrameInfo *targetFrame = navigationAction.targetFrame;
    BOOL isMainFrame = !targetFrame || targetFrame.isMainFrame;
    NSString *url = navigationAction.request.URL.absoluteString ?: @"";
    bool allowed = electrobun::checkNavigationRulesForUrl(_rules, [url UTF8String], true, isMainFrame);
    [self.decisions addObject:@{ @"url": url, @"main": @(isMainFrame), @"allowed": @(allowed) }];
    decisionHandler(allowed ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    self.finished = YES;
}

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message
{
    if ([message.body isKindOfClass:[NSString class]])
        [self.loadedFrames addObject:message.body];
}

- (BOOL)decided:(NSString *)prefix main:(BOOL)main allowed:(BOOL)allowed
{
    for (NSDictionary *decision in self.decisions) {
        if ([decision[@"url"] hasPrefix:prefix] && [decision[@"main"] boolValue] == main &&
            [decision[@"allowed"] boolValue] == allowed)
            return YES;
    }
    return NO;
}

@end

// Each child iframe posts its name to the parent, which relays it to the native handler.
static NSString *const kPage =
    @"<!doctype html><body><script>"
     "addEventListener('message', (event) => webkit.messageHandlers.probe.postMessage(String(event.data)));"
     "const child = (name) => '<script>parent.postMessage(\"' + name + '\", \"*\")<\\/script>';"
     "const srcdoc = document.createElement('iframe'); srcdoc.srcdoc = child('srcdoc'); document.body.append(srcdoc);"
     "const data = document.createElement('iframe'); data.src = 'data:text/html,' + encodeURIComponent(child('data')); document.body.append(data);"
     "const blob = document.createElement('iframe');"
     "blob.src = URL.createObjectURL(new Blob([child('blob')], { type: 'text/html' })); document.body.append(blob);"
     "</script></body>";

static void spin(NSTimeInterval seconds, BOOL (^done)(void))
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ((!done || !done()) && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

static RulesDelegate *loadPage(std::vector<std::string> rules, NSUInteger expectedFrames, WKWebView **outView)
{
    RulesDelegate *delegate = [[RulesDelegate alloc] initWithRules:rules];
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    [configuration.userContentController addScriptMessageHandler:delegate name:@"probe"];
    WKWebView *webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:configuration];
    webView.navigationDelegate = delegate;
    [webView loadHTMLString:kPage baseURL:[NSURL URLWithString:@"http://127.0.0.1/"]];
    spin(10, ^{ return delegate.finished; });
    // a blocked frame never reports, so the wait for it runs out rather than ending early
    spin(expectedFrames ? 10 : 1.5, ^{ return (BOOL)(expectedFrames && delegate.loadedFrames.count >= expectedFrames); });
    if (outView)
        *outView = webView;
    return delegate;
}

static void testRuleMatching()
{
    std::vector<std::string> rules = { "^*", "https://*", "about:blank", "frame:about:srcdoc", "frame:data:*", "^frame:https://ads.example/*" };
    CHECK(!electrobun::checkNavigationRulesForUrl(rules, "about:srcdoc", true, true), "frame rule must not allow a top-level navigation");
    CHECK(electrobun::checkNavigationRulesForUrl(rules, "about:srcdoc", true, false), "frame rule allows a subframe navigation");
    CHECK(!electrobun::checkNavigationRulesForUrl(rules, "data:text/html,x", true, true), "top-level data: stays blocked");
    CHECK(electrobun::checkNavigationRulesForUrl(rules, "data:text/html,x", true, false), "subframe data: is allowed");
    CHECK(electrobun::checkNavigationRulesForUrl(rules, "https://ads.example/x", true, true), "^frame: rule leaves top-level navigation alone");
    CHECK(!electrobun::checkNavigationRulesForUrl(rules, "https://ads.example/x", true, false), "^frame: rule blocks a subframe navigation");
    CHECK(electrobun::checkNavigationRulesForUrl(rules, "https://example.com/", true, false), "page rules still apply to subframes");
    CHECK(electrobun::checkNavigationRulesForUrl(std::string("^*, frame:about:srcdoc"), "about:srcdoc", true, false),
        "comma-separated rules understand the frame prefix");
    CHECK(!electrobun::checkNavigationRulesForUrl(std::string("^*, frame:about:srcdoc"), "about:srcdoc"),
        "the frame flag defaults to a top-level navigation");
}

static void testBlockedWithoutFrameRules()
{
    RulesDelegate *delegate = loadPage({ "^*", "http://*", "about:blank" }, 0, nullptr);
    CHECK(delegate.finished, "baseline page finished loading");
    CHECK([delegate decided:@"about:srcdoc" main:NO allowed:NO], "WebKit asks the delegate about an about:srcdoc subframe");
    CHECK(delegate.loadedFrames.count == 0, "without frame rules no srcdoc, data: or blob: iframe runs");
}

static void testFrameRulesAllowIframesOnly()
{
    WKWebView *webView = nil;
    RulesDelegate *delegate = loadPage(
        { "^*", "http://*", "about:blank", "frame:about:srcdoc", "frame:data:*", "frame:blob:*" }, 3, &webView);
    CHECK(delegate.finished, "page with frame rules finished loading");
    CHECK([delegate.loadedFrames containsObject:@"srcdoc"], "srcdoc iframe runs");
    CHECK([delegate.loadedFrames containsObject:@"data"], "data: iframe runs");
    CHECK([delegate.loadedFrames containsObject:@"blob"], "blob: iframe runs");

    [webView evaluateJavaScript:@"location.href = 'data:text/html,top'" completionHandler:nil];
    spin(5, ^{ return [delegate decided:@"data:" main:YES allowed:NO]; });
    CHECK([delegate decided:@"data:" main:YES allowed:NO], "top-level data: navigation is cancelled");
}

int main()
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        testRuleMatching();
        testBlockedWithoutFrameRules();
        testFrameRulesAllowIframesOnly();
    }
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::printf("PASS: frame navigation rules\n");
    return 0;
}
