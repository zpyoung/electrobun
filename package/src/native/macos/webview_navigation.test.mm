#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include <arpa/inet.h>
#include <cstdio>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include "load_failed.h"

static int failures = 0;

#define CHECK(condition, message) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "FAIL: %s\n", message); \
            ++failures; \
        } \
    } while (false)

// Serves one cacheable page whose body changes on every response.
@interface CachingServer : NSObject
@property (nonatomic, assign) int listenSocket;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, assign) NSUInteger responses;
@property (nonatomic, strong) NSMutableArray<NSString *> *requests;
@end

@implementation CachingServer

- (BOOL)start
{
    self.requests = [NSMutableArray array];
    self.listenSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (self.listenSocket < 0)
        return NO;

    struct sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(self.listenSocket, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(self.listenSocket, 8) != 0)
        return NO;

    socklen_t length = sizeof(address);
    getsockname(self.listenSocket, (struct sockaddr *)&address, &length);
    self.port = ntohs(address.sin_port);

    int listenSocket = self.listenSocket;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (true) {
            int client = accept(listenSocket, nullptr, nullptr);
            if (client < 0)
                return;
            [self respondTo:client];
        }
    });
    return YES;
}

- (void)respondTo:(int)client
{
    NSMutableData *received = [NSMutableData data];
    char buffer[4096];
    while ([received length] < 65536) {
        ssize_t count = read(client, buffer, sizeof(buffer));
        if (count <= 0)
            break;
        [received appendBytes:buffer length:(NSUInteger)count];
        NSString *soFar = [[NSString alloc] initWithData:received encoding:NSUTF8StringEncoding];
        if ([soFar containsString:@"\r\n\r\n"])
            break;
    }

    NSString *request = [[NSString alloc] initWithData:received encoding:NSUTF8StringEncoding] ?: @"";
    NSString *response;
    @synchronized (self) {
        if (![request hasPrefix:@"GET /favicon.ico"])
            [self.requests addObject:request];
        self.responses += 1;
        NSString *body = [NSString stringWithFormat:@"<!doctype html><title>page</title><p id=v>response %lu</p>",
                                                    (unsigned long)self.responses];
        response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nETag: \"page\"\r\n"
                                              @"Cache-Control: max-age=3600\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n%@",
                                              (unsigned long)[body lengthOfBytesUsingEncoding:NSUTF8StringEncoding], body];
    }
    NSData *bytes = [response dataUsingEncoding:NSUTF8StringEncoding];
    write(client, bytes.bytes, bytes.length);
    close(client);
}

- (NSString *)lastRequest
{
    @synchronized (self) {
        return self.requests.lastObject.lowercaseString ?: @"";
    }
}

- (NSUInteger)requestCount
{
    @synchronized (self) {
        return self.requests.count;
    }
}

- (void)stop
{
    close(self.listenSocket);
}

@end

@interface NavigationProbe : NSObject <WKNavigationDelegate>
@property (nonatomic, assign) NSUInteger finishedCount;
@property (nonatomic, strong) NSMutableArray<NSString *> *loadFailedDetails;
@end

@implementation NavigationProbe

- (instancetype)init
{
    self = [super init];
    _loadFailedDetails = [NSMutableArray array];
    return self;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    (void)webView;
    (void)navigation;
    self.finishedCount += 1;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    (void)navigation;
    [self.loadFailedDetails addObject:electrobun::loadFailedEventDetail(error, webView.URL)];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    (void)navigation;
    [self.loadFailedDetails addObject:electrobun::loadFailedEventDetail(error, webView.URL)];
}

@end

static bool runUntil(bool (^condition)(void))
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

static NSString *pageText(WKWebView *webView)
{
    __block NSString *text = nil;
    __block bool done = false;
    [webView evaluateJavaScript:@"document.getElementById('v').textContent"
              completionHandler:^(id result, NSError *error) {
                  (void)error;
                  text = [result isKindOfClass:[NSString class]] ? result : nil;
                  done = true;
              }];
    runUntil(^bool { return done; });
    return text ?: @"";
}

static NSDictionary *parseDetail(NSString *detail)
{
    NSData *data = [detail dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static void testLoadFailedDetail()
{
    NSURL *fallback = [NSURL URLWithString:@"https://fallback.test/"];

    NSError *withURL = [NSError errorWithDomain:NSURLErrorDomain
                                           code:NSURLErrorServerCertificateUntrusted
                                       userInfo:@{
                                           NSURLErrorFailingURLErrorKey : [NSURL URLWithString:@"https://self-signed.test/"],
                                           NSLocalizedDescriptionKey : @"The certificate for \"self-signed.test\" is invalid.\n",
                                       }];
    NSDictionary *detail = parseDetail(electrobun::loadFailedEventDetail(withURL, fallback));
    CHECK(detail != nil, "detail must be valid JSON even when the description contains quotes");
    CHECK([detail[@"url"] isEqualToString:@"https://self-signed.test/"], "detail must carry the failing URL");
    CHECK([detail[@"domain"] isEqualToString:NSURLErrorDomain], "detail must carry the error domain");
    CHECK([detail[@"code"] integerValue] == NSURLErrorServerCertificateUntrusted, "detail must carry the error code");
    CHECK([detail[@"description"] isEqualToString:@"The certificate for \"self-signed.test\" is invalid.\n"],
          "detail must carry the localized description");

    NSError *withoutURL = [NSError errorWithDomain:@"WebKitErrorDomain" code:102 userInfo:nil];
    detail = parseDetail(electrobun::loadFailedEventDetail(withoutURL, fallback));
    CHECK([detail[@"url"] isEqualToString:@"https://fallback.test/"], "detail must fall back to the web view URL");
    detail = parseDetail(electrobun::loadFailedEventDetail(withoutURL, nil));
    CHECK([detail[@"url"] isEqualToString:@""], "detail must use an empty URL when nothing is known");
}

static WKWebView *makeWebView(WKWebsiteDataStore *dataStore, NavigationProbe *probe)
{
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = dataStore;
    WKWebView *webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320) configuration:configuration];
    webView.navigationDelegate = probe;
    return webView;
}

static void testReloadFromOriginBypassesCache()
{
    CachingServer *server = [[CachingServer alloc] init];
    CHECK([server start], "loopback server must start");

    NavigationProbe *probe = [[NavigationProbe alloc] init];
    WKWebView *webView = makeWebView([WKWebsiteDataStore nonPersistentDataStore], probe);

    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:%u/page", server.port];
    [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
    CHECK(runUntil(^bool { return probe.finishedCount == 1; }), "initial load must finish");
    CHECK([pageText(webView) isEqualToString:@"response 1"], "initial load must show the first response");

    [webView reload];
    CHECK(runUntil(^bool { return probe.finishedCount == 2; }), "ordinary reload must finish");
    NSString *ordinary = [server lastRequest];
    CHECK(![ordinary containsString:@"\r\ncache-control: no-cache"] && ![ordinary containsString:@"\r\npragma: no-cache"],
          "ordinary reload must not bypass the cache");

    NSUInteger requestsBeforeHardReload = [server requestCount];
    [webView reloadFromOrigin];
    CHECK(runUntil(^bool { return probe.finishedCount == 3; }), "reload from origin must finish");
    CHECK([server requestCount] == requestsBeforeHardReload + 1, "reload from origin must request the page");
    NSString *hard = [server lastRequest];
    CHECK(![hard containsString:@"\r\nif-none-match:"] && ![hard containsString:@"\r\nif-modified-since:"],
          "reload from origin must not send cache validators");
    CHECK([hard containsString:@"\r\ncache-control: no-cache"] || [hard containsString:@"\r\npragma: no-cache"],
          "reload from origin must ask every cache to bypass its copy");
    NSString *fresh = [NSString stringWithFormat:@"response %lu", (unsigned long)server.responses];
    CHECK([pageText(webView) isEqualToString:fresh], "reload from origin must show the fresh response");
    CHECK([webView.URL.absoluteString isEqualToString:url], "reload from origin must keep the URL unchanged");
    if (failures == 0) {
        std::printf("PASS: reloadFromOrigin sent no-cache without validators and showed %s\n", fresh.UTF8String);
    }

    webView.navigationDelegate = nil;
    [webView stopLoading];
    [server stop];
}

static void testConnectionFailureReachesDelegate()
{
    int probeSocket = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(probeSocket, (struct sockaddr *)&address, sizeof(address));
    socklen_t length = sizeof(address);
    getsockname(probeSocket, (struct sockaddr *)&address, &length);
    close(probeSocket);

    NavigationProbe *probe = [[NavigationProbe alloc] init];
    WKWebView *webView = makeWebView([WKWebsiteDataStore nonPersistentDataStore], probe);
    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:%u/closed", ntohs(address.sin_port)];
    [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];

    CHECK(runUntil(^bool { return probe.loadFailedDetails.count == 1; }), "closed port must fail the navigation");
    NSDictionary *detail = parseDetail(probe.loadFailedDetails.firstObject ?: @"");
    CHECK([detail[@"url"] isEqualToString:url], "failure must carry the requested URL");
    CHECK([detail[@"domain"] isEqualToString:NSURLErrorDomain], "failure must carry NSURLErrorDomain");
    CHECK([detail[@"code"] integerValue] == NSURLErrorCannotConnectToHost, "failure must carry the connection error code");
    CHECK(probe.finishedCount == 0, "failed navigation must not finish");
    if (detail) {
        std::printf("PASS: closed port reported %s\n", probe.loadFailedDetails.firstObject.UTF8String);
    }

    webView.navigationDelegate = nil;
    [webView stopLoading];
}

static void testReplacedNavigationNeverFailsItsReplacement()
{
    // Never accepted, so a navigation to it stays provisional until replaced.
    int silentSocket = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(silentSocket, (struct sockaddr *)&address, sizeof(address));
    listen(silentSocket, 1);
    socklen_t length = sizeof(address);
    getsockname(silentSocket, (struct sockaddr *)&address, &length);

    NavigationProbe *probe = [[NavigationProbe alloc] init];
    WKWebView *webView = makeWebView([WKWebsiteDataStore nonPersistentDataStore], probe);
    NSString *pending = [NSString stringWithFormat:@"http://127.0.0.1:%u/pending", ntohs(address.sin_port)];
    [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:pending]]];
    runUntil(^bool { return webView.isLoading; });
    [webView loadHTMLString:@"<!doctype html><p id=v>replacement</p>" baseURL:nil];

    CHECK(runUntil(^bool { return probe.finishedCount == 1; }), "replacement navigation must finish");
    // WebKit versions differ on whether the replaced navigation reports anything.
    for (NSString *reported in probe.loadFailedDetails) {
        NSDictionary *detail = parseDetail(reported);
        CHECK([detail[@"url"] isEqualToString:pending] && [detail[@"code"] integerValue] == NSURLErrorCancelled,
              "a replaced navigation may only report its own cancellation");
    }
    std::printf("PASS: replacement finished; replaced navigation reported %lu failure(s)\n",
                (unsigned long)probe.loadFailedDetails.count);

    webView.navigationDelegate = nil;
    [webView stopLoading];
    close(silentSocket);
}

int main()
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        testLoadFailedDetail();
        testReloadFromOriginBypassesCache();
        testConnectionFailureReachesDelegate();
        testReplacedNavigationNeverFailsItsReplacement();
    }

    if (failures == 0) {
        std::printf("PASS: macOS webview navigation native tests\n");
        return 0;
    }
    return 1;
}
