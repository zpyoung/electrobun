#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include <arpa/inet.h>
#include <atomic>
#include <cstdio>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

#include "isolated_preview.h"

static int failures = 0;

#define CHECK(condition, message) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "FAIL: %s\n", message); \
            ++failures; \
        } \
    } while (false)

static NSString *const kScheme = @"electrobun-preview-test";

// Loopback listeners stand in for the internet: any TCP connection or UDP
// datagram (WebRTC ICE sends STUN over UDP) means the page reached the network.
static std::atomic<int> tcpConnections{0};
static std::atomic<int> udpDatagrams{0};
static int tcpPort = 0;
static int udpPort = 0;
static NSString *lastPostBody = nil;

static void *acceptLoop(void *arg)
{
    int listener = (int)(intptr_t)arg;
    while (true) {
        int connection = accept(listener, nullptr, nullptr);
        if (connection < 0)
            continue;
        tcpConnections++;
        const char *response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nAccess-Control-Allow-Origin: *\r\n\r\nok";
        send(connection, response, strlen(response), 0);
        close(connection);
    }
    return nullptr;
}

static void *receiveLoop(void *arg)
{
    int socketFd = (int)(intptr_t)arg;
    char buffer[2048];
    while (true) {
        if (recv(socketFd, buffer, sizeof(buffer), 0) > 0)
            udpDatagrams++;
    }
    return nullptr;
}

static int bindLoopback(int type)
{
    int socketFd = socket(AF_INET, type, 0);
    sockaddr_in address {};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(socketFd, reinterpret_cast<sockaddr *>(&address), sizeof(address));
    return socketFd;
}

static int boundPort(int socketFd)
{
    sockaddr_in address {};
    socklen_t length = sizeof(address);
    getsockname(socketFd, reinterpret_cast<sockaddr *>(&address), &length);
    return ntohs(address.sin_port);
}

static void startLoopbackListeners()
{
    int tcp = bindLoopback(SOCK_STREAM);
    listen(tcp, 64);
    tcpPort = boundPort(tcp);
    int udp = bindLoopback(SOCK_DGRAM);
    udpPort = boundPort(udp);
    pthread_t tcpThread;
    pthread_t udpThread;
    pthread_create(&tcpThread, nullptr, acceptLoop, (void *)(intptr_t)tcp);
    pthread_create(&udpThread, nullptr, receiveLoop, (void *)(intptr_t)udp);
}

static void spin(NSTimeInterval seconds)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static bool spinUntil(bool (^condition)(void), NSTimeInterval seconds)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

static NSString *evaluate(WKWebView *webView, NSString *script)
{
    __block NSString *result = nil;
    __block bool done = false;
    [webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
        result = [value isKindOfClass:[NSString class]] ? value : (error ? error.localizedDescription : @"");
        done = true;
    }];
    spinUntil(^{ return done; }, 5);
    return result ?: @"";
}

// Every channel a page has to reach a server it was not served from.
static NSString *egressDocument()
{
    int p = tcpPort;
    NSString *origin = [NSString stringWithFormat:@"http://127.0.0.1:%d", p];
    return [NSString stringWithFormat:@
        "<!doctype html><html><head>"
        "<link rel=preconnect href='%1$@/preconnect'>"
        "<link rel=prefetch href='%1$@/prefetch'>"
        "<link rel=stylesheet href='%1$@/style.css'>"
        "<style>@import url('%1$@/import.css');"
        "body{background:url('%1$@/background.png')}"
        "@font-face{font-family:probe;src:url('%1$@/font.woff')} p{font-family:probe}</style>"
        "<script src='%1$@/script.js'></script>"
        "</head><body><p>preview</p>"
        "<img src='%1$@/image.png'><img id=asset src='asset.png'>"
        "<iframe src='%1$@/frame'></iframe>"
        "<video src='%1$@/video.mp4'></video>"
        "<form id=form action='%1$@/form' method=post target=formTarget></form><iframe name=formTarget></iframe>"
        "<a id=download download href='download.bin'>download</a>"
        "<script>"
        "window.R={rtc:typeof RTCPeerConnection};"
        "document.getElementById('asset').onload=()=>R.asset='loaded';"
        "fetch('data.json').then(r=>r.text()).then(t=>R.sameScheme=t,e=>R.sameScheme='error');"
        "fetch('echo.json',{method:'POST',body:'posted-body'}).then(r=>R.post=r.status,e=>R.post='error');"
        "fetch('%1$@/fetch').then(()=>R.fetch='reached',()=>R.fetch='blocked');"
        "var x=new XMLHttpRequest();x.open('GET','%1$@/xhr');x.send();"
        "try{new WebSocket('ws://127.0.0.1:%2$d/socket')}catch(e){}"
        "try{new EventSource('%1$@/events')}catch(e){}"
        "try{navigator.sendBeacon('%1$@/beacon','x')}catch(e){}"
        "try{new Worker('worker.js')}catch(e){}"
        "try{var pc=new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:%3$d'}]});"
        "pc.createDataChannel('probe');pc.createOffer().then(o=>pc.setLocalDescription(o));}catch(e){}"
        "document.getElementById('form').submit();"
        "document.getElementById('download').click();"
        "window.open('%1$@/popup');"
        "setTimeout(()=>{location.href='%1$@/navigate'},300);"
        "</script></body></html>",
        origin, p, udpPort];
}

@interface PreviewNavigationProbe : NSObject <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, assign) BOOL enforcePolicy;
@property (nonatomic, assign) NSUInteger finishedNavigations;
@property (nonatomic, assign) NSUInteger cancelledNavigations;
@property (nonatomic, assign) NSUInteger cancelledDownloads;
@property (nonatomic, assign) NSUInteger downloads;
@property (nonatomic, assign) NSUInteger popupRequests;
@end

@implementation PreviewNavigationProbe
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    if (!self.enforcePolicy) {
        decisionHandler(navigationAction.shouldPerformDownload ? WKNavigationActionPolicyDownload
                                                               : WKNavigationActionPolicyAllow);
        return;
    }
    WKNavigationActionPolicy policy =
        electrobun::isolatedPreviewNavigationActionPolicy(navigationAction, kScheme);
    if (policy == WKNavigationActionPolicyCancel) {
        self.cancelledNavigations += 1;
        if (navigationAction.shouldPerformDownload)
            self.cancelledDownloads += 1;
    }
    decisionHandler(policy);
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                      decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
    decisionHandler(self.enforcePolicy
                        ? electrobun::isolatedPreviewNavigationResponsePolicy(navigationResponse)
                        : WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    self.finishedNavigations += 1;
}

- (void)webView:(WKWebView *)webView
     navigationAction:(WKNavigationAction *)navigationAction
    didBecomeDownload:(WKDownload *)download
{
    self.downloads += 1;
    [download cancel:nil];
}

- (void)webView:(WKWebView *)webView
    navigationResponse:(WKNavigationResponse *)navigationResponse
     didBecomeDownload:(WKDownload *)download
{
    self.downloads += 1;
    [download cancel:nil];
}

- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures
{
    self.popupRequests += 1;
    return nil;
}
@end

static ElectrobunIsolatedPreviewSchemeHandler *makeSchemeHandler(NSString *html)
{
    __block __weak ElectrobunIsolatedPreviewSchemeHandler *weakHandler = nil;
    ElectrobunIsolatedPreviewSchemeHandler *handler = [[ElectrobunIsolatedPreviewSchemeHandler alloc]
        initWithRequestHandler:^(uint32_t requestId, NSURLRequest *request, NSData *requestBody) {
            NSString *path = request.URL.path;
            if ([request.HTTPMethod isEqualToString:@"POST"]) {
                lastPostBody = [[NSString alloc] initWithData:requestBody encoding:NSUTF8StringEncoding];
            }
            NSString *type = @"text/html";
            NSData *body = [html dataUsingEncoding:NSUTF8StringEncoding];
            if ([path hasSuffix:@".png"]) {
                type = @"image/png";
                body = [[NSData alloc] initWithBase64EncodedString:
                    @"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
                                                           options:0];
            } else if ([path hasSuffix:@".json"]) {
                type = @"application/json";
                body = [@"in-scheme" dataUsingEncoding:NSUTF8StringEncoding];
            } else if ([path hasSuffix:@"worker.js"]) {
                type = @"text/javascript";
                body = [[NSString stringWithFormat:@"fetch('http://127.0.0.1:%d/worker')", tcpPort]
                    dataUsingEncoding:NSUTF8StringEncoding];
            } else if ([path hasSuffix:@".bin"]) {
                type = @"application/octet-stream";
                body = [@"binary" dataUsingEncoding:NSUTF8StringEncoding];
            }
            // Answer on a later turn, as the app does after its handler resolves.
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakHandler respondToRequest:requestId
                                       status:200
                                      headers:@{@"Content-Type" : type}
                                         body:body];
            });
        }];
    weakHandler = handler;
    return handler;
}

static WKContentRuleList *compileRuleList()
{
    __block WKContentRuleList *ruleList = nil;
    __block NSError *compileError = nil;
    __block bool done = false;
    electrobun::loadIsolatedPreviewContentRuleList(kScheme, ^(WKContentRuleList *list, NSError *error) {
        ruleList = list;
        compileError = error;
        done = true;
    });
    spinUntil(^{ return done; }, 10);
    CHECK(ruleList != nil && compileError == nil, "isolated preview content rules must compile");
    return ruleList;
}

static WKWebView *makePreviewWebView(ElectrobunIsolatedPreviewSchemeHandler *handler,
                                     WKContentRuleList *ruleList)
{
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    electrobun::configureIsolatedPreview(configuration, kScheme, handler);
    if (ruleList)
        [configuration.userContentController addContentRuleList:ruleList];
    return [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320) configuration:configuration];
}

static NSURL *previewURL(NSString *path)
{
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@://document/%@", kScheme, path]];
}

static void testSchemeValidation()
{
    CHECK(electrobun::isValidIsolatedPreviewScheme(@"app-preview"), "plain custom scheme must be accepted");
    CHECK(electrobun::isValidIsolatedPreviewScheme(@"preview2"), "digits after the first letter are accepted");
    NSArray<NSString *> *rejected = @[
        @"", @"http", @"https", @"file", @"about", @"data", @"blob", @"ws", @"wss", @"javascript",
        @"views", @"appdata", @"Preview", @"2preview", @"pre.view", @"pre+view", @"pre view",
        [@"" stringByPaddingToLength:65 withString:@"a" startingAtIndex:0],
    ];
    for (NSString *scheme in rejected) {
        if (electrobun::isValidIsolatedPreviewScheme(scheme)) {
            std::fprintf(stderr, "FAIL: scheme \"%s\" must be rejected\n", scheme.UTF8String);
            ++failures;
        }
    }
    CHECK(!electrobun::isValidIsolatedPreviewScheme(nil), "nil scheme must be rejected");
}

static void testNavigationPolicy()
{
    auto allows = [](NSString *url) {
        return electrobun::isolatedPreviewAllowsNavigation([NSURL URLWithString:url], kScheme);
    };
    CHECK(allows([NSString stringWithFormat:@"%@://document/index.html", kScheme]), "preview scheme must navigate");
    CHECK(allows(@"about:blank"), "about:blank must navigate");
    CHECK(allows(@"about:srcdoc"), "about:srcdoc must navigate");
    for (NSString *url in @[ @"https://example.com/", @"http://127.0.0.1/", @"file:///etc/hosts",
                              @"data:text/html,hi", @"blob:null/1", @"javascript:alert(1)",
                              @"views://index.html", @"other-preview://document/", @"about:config" ]) {
        if (allows(url)) {
            std::fprintf(stderr, "FAIL: navigation to %s must be refused\n", url.UTF8String);
            ++failures;
        }
    }
}

struct EgressResult {
    int tcp;
    int udp;
    NSString *results;
    PreviewNavigationProbe *probe;
};

static EgressResult loadEgressDocument(WKWebView *webView, BOOL enforcePolicy)
{
    tcpConnections = 0;
    udpDatagrams = 0;
    PreviewNavigationProbe *probe = [[PreviewNavigationProbe alloc] init];
    probe.enforcePolicy = enforcePolicy;
    webView.navigationDelegate = probe;
    webView.UIDelegate = probe;
    [webView loadRequest:[NSURLRequest requestWithURL:previewURL(@"index.html")]];
    spinUntil(^{ return probe.finishedNavigations > 0; }, 10);
    // Give ICE gathering, workers and the delayed navigation time to try.
    spin(2.5);
    NSString *results = evaluate(webView, @"JSON.stringify(window.R)");
    EgressResult result { tcpConnections.load(), udpDatagrams.load(), results, probe };
    webView.navigationDelegate = nil;
    webView.UIDelegate = nil;
    [webView stopLoading];
    return result;
}

static void testUnfencedControlReachesNetwork()
{
    // Without the fences the same document must reach the listeners, or the
    // fenced run below would pass vacuously.
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    [configuration setURLSchemeHandler:makeSchemeHandler(egressDocument()) forURLScheme:kScheme];
    WKWebView *webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320)
                                            configuration:configuration];
    EgressResult result = loadEgressDocument(webView, NO);
    CHECK(result.tcp > 0, "unfenced control must open TCP connections");
    CHECK(result.udp > 0, "unfenced control must send WebRTC datagrams");
    std::printf("control: %d TCP connections, %d UDP datagrams without the fences\n", result.tcp, result.udp);
}

static void testIsolatedPreviewBlocksEgress(WKContentRuleList *ruleList)
{
    ElectrobunIsolatedPreviewSchemeHandler *handler = makeSchemeHandler(egressDocument());
    WKWebView *webView = makePreviewWebView(handler, ruleList);
    CHECK(!webView.configuration.websiteDataStore.persistent, "preview data store must be nonpersistent");
    CHECK(webView.configuration.defaultWebpagePreferences.lockdownModeEnabled, "preview must run in Lockdown Mode");

    EgressResult result = loadEgressDocument(webView, YES);
    NSLog(@"isolated preview page results: %@", result.results);
    CHECK(result.tcp == 0, "isolated preview must not open any TCP connection");
    CHECK(result.udp == 0, "isolated preview must not send any UDP datagram");
    CHECK([result.results containsString:@"\"rtc\":\"undefined\""], "RTCPeerConnection must be unavailable");
    CHECK([result.results containsString:@"\"asset\":\"loaded\""], "in-scheme image must load");
    CHECK([result.results containsString:@"\"sameScheme\":\"in-scheme\""], "in-scheme fetch must succeed");
    CHECK([result.results containsString:@"\"fetch\":\"blocked\""], "cross-scheme fetch must fail");
    if (![lastPostBody isEqualToString:@"posted-body"])
        std::fprintf(stderr, "POST body seen by handler: %s\n", lastPostBody ? lastPostBody.UTF8String : "(no POST)");
    CHECK([lastPostBody isEqualToString:@"posted-body"], "in-scheme POST body must reach the handler");
    CHECK(result.probe.cancelledNavigations >= 3, "frame, form and top-level navigations must be cancelled");
    CHECK(result.probe.cancelledDownloads >= 1, "download link must be cancelled");
    CHECK(result.probe.downloads == 0, "no download may start");
    CHECK(result.probe.popupRequests == 0, "script popups must not reach the UI delegate");
    CHECK([webView.URL.scheme isEqualToString:kScheme], "top-level document must stay on the preview scheme");
    CHECK(handler.pendingRequestCount == 0, "answered requests must be released");
    std::printf("isolated: %d TCP connections, %d UDP datagrams\n", result.tcp, result.udp);
}

static void testUnrenderableResponseIsNotDownloaded(WKContentRuleList *ruleList)
{
    ElectrobunIsolatedPreviewSchemeHandler *handler = makeSchemeHandler(@"<!doctype html>");
    WKWebView *webView = makePreviewWebView(handler, ruleList);
    PreviewNavigationProbe *probe = [[PreviewNavigationProbe alloc] init];
    probe.enforcePolicy = YES;
    webView.navigationDelegate = probe;
    [webView loadRequest:[NSURLRequest requestWithURL:previewURL(@"archive.bin")]];
    spin(1.0);
    CHECK(probe.downloads == 0, "unrenderable preview response must not become a download");
    webView.navigationDelegate = nil;
}

static void testEachPreviewHasItsOwnStorage(WKContentRuleList *ruleList)
{
    NSString *html = @"<!doctype html><script>"
                      "window.before=JSON.stringify({ls:localStorage.getItem('k'),cookie:document.cookie});"
                      "localStorage.setItem('k','first');document.cookie='c=first';"
                      "</script>";
    WKWebView *first = makePreviewWebView(makeSchemeHandler(html), ruleList);
    WKWebView *second = makePreviewWebView(makeSchemeHandler(html), ruleList);
    CHECK(first.configuration.websiteDataStore != second.configuration.websiteDataStore,
          "each preview must get its own data store");

    PreviewNavigationProbe *firstProbe = [[PreviewNavigationProbe alloc] init];
    first.navigationDelegate = firstProbe;
    [first loadRequest:[NSURLRequest requestWithURL:previewURL(@"index.html")]];
    spinUntil(^{ return firstProbe.finishedNavigations > 0; }, 10);
    NSString *firstStorage = evaluate(first, @"localStorage.getItem('k')");
    CHECK([firstStorage isEqualToString:@"first"], "preview storage must work within one view");

    PreviewNavigationProbe *secondProbe = [[PreviewNavigationProbe alloc] init];
    second.navigationDelegate = secondProbe;
    [second loadRequest:[NSURLRequest requestWithURL:previewURL(@"index.html")]];
    spinUntil(^{ return secondProbe.finishedNavigations > 0; }, 10);
    NSString *secondBefore = evaluate(second, @"window.before");
    CHECK([secondBefore isEqualToString:@"{\"ls\":null,\"cookie\":\"\"}"],
          "a second preview must not see the first preview's storage");
    first.navigationDelegate = nil;
    second.navigationDelegate = nil;
}

static void testStoppedRequestsAreNotAnswered()
{
    ElectrobunIsolatedPreviewSchemeHandler *handler =
        [[ElectrobunIsolatedPreviewSchemeHandler alloc] initWithRequestHandler:nil];
    CHECK(![handler respondToRequest:42 status:200 headers:@{} body:[NSData data]],
          "unknown request ids must be refused");
}

int main()
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        startLoopbackListeners();
        testSchemeValidation();
        testNavigationPolicy();
        testStoppedRequestsAreNotAnswered();
        WKContentRuleList *ruleList = compileRuleList();
        testUnfencedControlReachesNetwork();
        testIsolatedPreviewBlocksEgress(ruleList);
        testUnrenderableResponseIsNotDownloaded(ruleList);
        testEachPreviewHasItsOwnStorage(ruleList);
    }

    if (failures == 0) {
        std::printf("PASS: macOS isolated preview native tests\n");
        return 0;
    }
    return 1;
}
