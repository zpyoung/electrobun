#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include <cstdio>

#include "native_requests.h"

static int failures = 0;

#define CHECK(condition, message) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "FAIL: %s\n", message); \
            ++failures; \
        } \
    } while (false)

static bool spinUntil(bool (^condition)(void), NSTimeInterval seconds)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

static void spinFor(NSTimeInterval seconds)
{
    spinUntil(^bool { return false; }, seconds);
}

static NSString *documentTitle(WKWebView *webView)
{
    __block NSString *title = nil;
    __block bool done = false;
    [webView evaluateJavaScript:@"document.title"
              completionHandler:^(id result, NSError *error) {
                  (void)error;
                  title = [result isKindOfClass:[NSString class]] ? result : nil;
                  done = true;
              }];
    spinUntil(^bool { return done; }, 5.0);
    return title;
}

static bool waitForTitle(WKWebView *webView, NSString *expected, NSTimeInterval seconds)
{
    return spinUntil(^bool { return [documentTitle(webView) isEqualToString:expected]; }, seconds);
}

static void testRegistryResolvesExactlyOnce()
{
    electrobun::NativeRequestRegistry registry;
    __block int resolvedCount = 0;
    __block NSDictionary *resolvedWith = nil;
    __block NSString *expiredReason = nil;

    uint32_t timedOut = registry.add(7, 50,
        ^(NSDictionary *response) {
            resolvedCount += 1;
            resolvedWith = response;
        },
        ^(uint32_t requestId, NSString *reason) {
            (void)requestId;
            expiredReason = reason;
        });
    CHECK(registry.isPending(7, timedOut), "new request must be pending");
    CHECK(!registry.isPending(8, timedOut), "request must belong to its webview");
    spinUntil(^bool { return resolvedCount > 0; }, 2.0);
    CHECK(resolvedCount == 1 && resolvedWith == nil, "timeout must resolve once with no response");
    CHECK([expiredReason isEqualToString:@"timeout"], "timeout must report its reason");
    CHECK(!registry.respond(7, timedOut, @{ @"accept" : @YES }), "late response must be rejected");
    CHECK(resolvedCount == 1, "late response must not resolve again");

    __block int answeredCount = 0;
    __block NSDictionary *answer = nil;
    uint32_t answered = registry.add(7, 100,
        ^(NSDictionary *response) {
            answeredCount += 1;
            answer = response;
        },
        nil);
    CHECK(!registry.respond(8, answered, @{ @"accept" : @YES }), "another webview must not answer");
    CHECK(registry.respond(7, answered, @{ @"accept" : @YES }), "owner must answer a pending request");
    CHECK(!registry.respond(7, answered, @{ @"accept" : @NO }), "second answer must be rejected");
    spinFor(0.25);
    CHECK(answeredCount == 1 && electrobun::responseAccepted(answer), "answer must win over the later timeout");

    __block int closedCount = 0;
    __block int otherCount = 0;
    registry.add(9, 10000, ^(NSDictionary *response) { closedCount += response ? 0 : 1; }, nil);
    registry.add(9, 10000, ^(NSDictionary *response) { closedCount += response ? 0 : 1; }, nil);
    uint32_t other = registry.add(10, 10000, ^(NSDictionary *response) { (void)response; otherCount += 1; }, nil);
    registry.expireAllForWebview(9, @"closed");
    CHECK(closedCount == 2, "closing a webview must fail its pending requests closed");
    CHECK(otherCount == 0 && registry.isPending(10, other), "closing a webview must not touch other webviews");
    registry.expireAllForWebview(10, @"closed");
    CHECK(registry.pendingCount() == 0, "registry must be empty after expiry");
}

static void testResponseDecoding()
{
    NSDictionary *parsed = electrobun::parseNativeRequestResponse("{\"accept\":true,\"text\":\"h\\u00e9llo \\u4e16\\u754c\"}");
    CHECK(electrobun::responseAccepted(parsed), "accept must parse");
    CHECK([electrobun::responseString(parsed, @"text") isEqualToString:@"héllo 世界"], "unicode text must parse");
    CHECK(!electrobun::responseAccepted(electrobun::parseNativeRequestResponse("not json")), "invalid json must decline");
    CHECK(!electrobun::responseAccepted(electrobun::parseNativeRequestResponse("{\"accept\":\"yes\"}")), "non-boolean accept must decline");
    CHECK(!electrobun::responseAccepted(nil), "expiry must decline");

    NSURLCredential *credential = electrobun::credentialForAuthResponse(
        @{ @"accept" : @YES, @"username" : @"ada", @"password" : @"s3cret" });
    CHECK(credential && [credential.user isEqualToString:@"ada"], "accepted auth must build a credential");
    CHECK(credential.persistence == NSURLCredentialPersistenceNone, "auth credentials must not persist");
    CHECK(!electrobun::credentialForAuthResponse(@{ @"accept" : @NO, @"username" : @"ada", @"password" : @"x" }),
          "declined auth must not build a credential");
    CHECK(!electrobun::credentialForAuthResponse(@{ @"accept" : @YES }), "auth without credentials must not build one");
    CHECK(!electrobun::credentialForAuthResponse(nil), "expired auth must not build a credential");
}

static void testDownloadDestinations()
{
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"electrobun-native-requests-%@", [NSUUID UUID].UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *requested = [directory stringByAppendingPathComponent:@"report.pdf"];

    CHECK([electrobun::uniqueDownloadPath(requested) isEqualToString:requested], "free destination must be kept");
    [@"taken" writeToFile:requested atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *second = [directory stringByAppendingPathComponent:@"report (1).pdf"];
    CHECK([electrobun::uniqueDownloadPath(requested) isEqualToString:second], "taken destination must be numbered");
    CHECK(!electrobun::uniqueDownloadPath(@"report.pdf"), "relative destination must be refused");
    CHECK(!electrobun::uniqueDownloadPath([directory stringByAppendingPathComponent:@"missing/report.pdf"]),
          "destination in a missing directory must be refused");

    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

@interface TestSchemeHandler : NSObject <WKURLSchemeHandler>
@property (nonatomic, strong) NSMutableArray<NSURLRequest *> *requests;
@end

@implementation TestSchemeHandler
- (instancetype)init
{
    self = [super init];
    if (self)
        _requests = [NSMutableArray array];
    return self;
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task
{
    (void)webView;
    [self.requests addObject:task.request];
    NSString *html = @"<!doctype html><script>"
                     @"document.title = 'opener:' + (window.opener !== null) + ' name:' + window.name;"
                     @"</script>";
    NSData *data = [html dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:task.request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{ @"Content-Type" : @"text/html" }];
    [task didReceiveResponse:response];
    [task didReceiveData:data];
    [task didFinish];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task
{
    (void)webView;
    (void)task;
}

- (NSURLRequest *)requestForPath:(NSString *)path
{
    for (NSURLRequest *request in self.requests) {
        if ([request.URL.path isEqualToString:path])
            return request;
    }
    return nil;
}
@end

@interface RequestProbe : NSObject <WKUIDelegate, WKNavigationDelegate>
@property (nonatomic, assign) electrobun::NativeRequestRegistry *registry;
@property (nonatomic, assign) double timeoutMs;
@property (nonatomic, assign) uint32_t lastRequestId;
@property (nonatomic, copy) NSString *lastExpiredReason;
@property (nonatomic, strong) NSMutableArray<ElectrobunParkedPopup *> *popups;
@property (nonatomic, assign) NSUInteger finishedNavigations;
@end

@implementation RequestProbe
- (uint32_t)addRequest:(electrobun::NativeRequestResolver)resolver
{
    RequestProbe *probe = self;
    self.lastRequestId = self.registry->add(1, self.timeoutMs, resolver, ^(uint32_t requestId, NSString *reason) {
        (void)requestId;
        probe.lastExpiredReason = reason;
    });
    return self.lastRequestId;
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame
    completionHandler:(void (^)(BOOL))completionHandler
{
    (void)webView;
    (void)message;
    (void)frame;
    [self addRequest:^(NSDictionary *response) {
        completionHandler(electrobun::responseAccepted(response));
    }];
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
    defaultText:(NSString *)defaultText
    initiatedByFrame:(WKFrameInfo *)frame
    completionHandler:(void (^)(NSString *))completionHandler
{
    (void)webView;
    (void)prompt;
    (void)defaultText;
    (void)frame;
    [self addRequest:^(NSDictionary *response) {
        completionHandler(electrobun::promptResult(response));
    }];
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
    forNavigationAction:(WKNavigationAction *)navigationAction
    windowFeatures:(WKWindowFeatures *)windowFeatures
{
    (void)webView;
    (void)navigationAction;
    (void)windowFeatures;
    ElectrobunParkedPopup *popup = [[ElectrobunParkedPopup alloc] initWithConfiguration:configuration];
    [self.popups addObject:popup];
    return popup.webView;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    (void)webView;
    (void)navigation;
    self.finishedNavigations += 1;
}
@end

static void testRealWKWebView()
{
    [NSApplication sharedApplication];

    electrobun::NativeRequestRegistry registry;
    TestSchemeHandler *schemeHandler = [[TestSchemeHandler alloc] init];
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = YES;
    [configuration setURLSchemeHandler:schemeHandler forURLScheme:@"ebtest"];

    CHECK(electrobun::isExternalAppURL([NSURL URLWithString:@"zoommtg://zoom.us/join"], configuration),
          "app scheme must be external");
    CHECK(electrobun::isExternalAppURL([NSURL URLWithString:@"mailto:ada@example.com"], configuration),
          "mailto must be external");
    CHECK(!electrobun::isExternalAppURL([NSURL URLWithString:@"https://example.com"], configuration),
          "https must load in the webview");
    CHECK(!electrobun::isExternalAppURL([NSURL URLWithString:@"about:blank"], configuration),
          "about must load in the webview");
    CHECK(!electrobun::isExternalAppURL([NSURL URLWithString:@"ebtest://page"], configuration),
          "a registered scheme handler must load in the webview");

    WKWebView *webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320) configuration:configuration];
    RequestProbe *probe = [[RequestProbe alloc] init];
    probe.registry = &registry;
    probe.popups = [NSMutableArray array];
    webView.UIDelegate = probe;
    webView.navigationDelegate = probe;

    NSString *page = @"<!doctype html><form id=oauth method=post action='ebtest://popup/submit' target=oauth>"
                     @"<input name=code value=abc></form><script>"
                     @"function ask() { document.title = 'confirm:' + confirm('Proceed?'); }"
                     @"function askText() { const v = prompt('Name?', 'x'); document.title = 'prompt:' + v; }"
                     @"</script>";
    [webView loadHTMLString:page baseURL:[NSURL URLWithString:@"https://opener.test/"]];
    CHECK(spinUntil(^bool { return probe.finishedNavigations >= 1; }, 10.0), "opener page must load");

    probe.timeoutMs = 150;
    probe.lastRequestId = 0;
    [webView evaluateJavaScript:@"setTimeout(ask)" completionHandler:nil];
    CHECK(waitForTitle(webView, @"confirm:false", 5.0), "unanswered confirm must fail closed to false");
    CHECK([probe.lastExpiredReason isEqualToString:@"timeout"], "confirm expiry must report timeout");
    CHECK(!registry.respond(1, probe.lastRequestId, @{ @"accept" : @YES }), "late confirm answer must be rejected");

    probe.timeoutMs = 10000;
    probe.lastRequestId = 0;
    [webView evaluateJavaScript:@"setTimeout(ask)" completionHandler:nil];
    CHECK(spinUntil(^bool { return probe.lastRequestId != 0; }, 5.0), "confirm must reach the registry");
    CHECK(registry.respond(1, probe.lastRequestId, @{ @"accept" : @YES }), "confirm answer must be accepted");
    CHECK(waitForTitle(webView, @"confirm:true", 5.0), "accepted confirm must return true to the page");

    probe.lastRequestId = 0;
    [webView evaluateJavaScript:@"setTimeout(askText)" completionHandler:nil];
    CHECK(spinUntil(^bool { return probe.lastRequestId != 0; }, 5.0), "prompt must reach the registry");
    registry.respond(1, probe.lastRequestId, @{ @"accept" : @YES, @"text" : @"héllo 世界" });
    CHECK(waitForTitle(webView, @"prompt:héllo 世界", 5.0), "prompt must return unicode text");

    probe.timeoutMs = 150;
    [webView evaluateJavaScript:@"setTimeout(askText)" completionHandler:nil];
    CHECK(waitForTitle(webView, @"prompt:null", 5.0), "unanswered prompt must fail closed to null");

    [webView evaluateJavaScript:@"document.getElementById('oauth').submit()" completionHandler:nil];
    CHECK(spinUntil(^bool { return probe.popups.count == 1; }, 5.0), "form post must ask for a popup");
    spinFor(0.3);
    CHECK(![schemeHandler requestForPath:@"/submit"], "parked popup must hold its first navigation");

    ElectrobunParkedPopup *popup = probe.popups.firstObject;
    WKWebView *popupView = popup.webView;
    RequestProbe *popupProbe = [[RequestProbe alloc] init];
    [popup releaseToNavigationDelegate:popupProbe];
    CHECK(spinUntil(^bool { return popupProbe.finishedNavigations >= 1; }, 10.0), "adopted popup must load");
    NSURLRequest *submitted = [schemeHandler requestForPath:@"/submit"];
    NSString *body = submitted.HTTPBody
        ? [[NSString alloc] initWithData:submitted.HTTPBody encoding:NSUTF8StringEncoding]
        : nil;
    CHECK([submitted.HTTPMethod isEqualToString:@"POST"], "adopted popup must keep the POST method");
    CHECK([body isEqualToString:@"code=abc"], "adopted popup must keep the POST body");
    CHECK(waitForTitle(popupView, @"opener:true name:oauth", 5.0), "adopted popup must keep its opener and name");

    [webView evaluateJavaScript:@"window.open('ebtest://popup/discarded', 'second')" completionHandler:nil];
    CHECK(spinUntil(^bool { return probe.popups.count == 2; }, 5.0), "window.open must ask for a popup");
    [probe.popups.lastObject discard];
    spinFor(0.3);
    CHECK(![schemeHandler requestForPath:@"/discarded"], "discarded popup must never load");

    webView.UIDelegate = nil;
    webView.navigationDelegate = nil;
    [webView stopLoading];
    std::printf("PASS: real WKWebView dialogs fail closed and popups keep opener and POST body\n");
}

int main()
{
    @autoreleasepool {
        testRegistryResolvesExactlyOnce();
        testResponseDecoding();
        testDownloadDestinations();
        testRealWKWebView();
    }

    if (failures == 0) {
        std::printf("PASS: macOS native request tests\n");
        return 0;
    }
    return 1;
}
