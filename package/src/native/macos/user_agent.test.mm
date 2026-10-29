#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include <arpa/inet.h>
#include <cstdio>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include "user_agent.h"

static int failures = 0;

#define CHECK(condition, message) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "FAIL: %s\n", message); \
            ++failures; \
        } \
    } while (false)

// Records the User-Agent header of each request path, so the test checks what
// WebKit actually sends rather than only what the page sees.
@interface UserAgentRecordingServer : NSObject
@property (nonatomic, assign) int listenSocket;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *userAgentsByPath;
- (BOOL)start;
- (NSString *)userAgentForPath:(NSString *)path;
@end

@implementation UserAgentRecordingServer
- (BOOL)start
{
    self.userAgentsByPath = [NSMutableDictionary dictionary];
    self.listenSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (self.listenSocket < 0) {
        return NO;
    }

    struct sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    socklen_t length = sizeof(address);
    if (bind(self.listenSocket, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(self.listenSocket, 8) != 0 ||
        getsockname(self.listenSocket, (struct sockaddr *)&address, &length) != 0) {
        return NO;
    }
    self.port = ntohs(address.sin_port);

    [NSThread detachNewThreadWithBlock:^{
        while (true) {
            int client = accept(self.listenSocket, nullptr, nullptr);
            if (client < 0) {
                return;
            }
            // WebKit can open a connection it never sends on; serving it inline would stall the next request.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                [self handleClient:client];
            });
        }
    }];
    return YES;
}

- (void)handleClient:(int)client
{
    NSMutableData *request = [NSMutableData data];
    char buffer[4096];
    while ([request length] < 65536) {
        ssize_t received = recv(client, buffer, sizeof(buffer), 0);
        if (received <= 0) {
            break;
        }
        [request appendBytes:buffer length:(NSUInteger)received];
        NSString *soFar = [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding];
        if ([soFar containsString:@"\r\n\r\n"]) {
            break;
        }
    }

    NSString *text = [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
    NSString *path = requestLine.count > 1 ? requestLine[1] : @"";
    for (NSString *line in lines) {
        if ([line.lowercaseString hasPrefix:@"user-agent:"]) {
            NSString *value = [[line substringFromIndex:11]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            @synchronized (self) {
                self.userAgentsByPath[path] = value;
            }
        }
    }

    // The page overrides navigator.userAgent to prove reads don't trust page scripts.
    NSString *body =
        @"<!doctype html><script>Object.defineProperty(navigator,'userAgent',{get:()=>'spoofed'})</script>ok";
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\n"
        @"Content-Type: text/html\r\n"
        @"Cache-Control: no-store\r\n"
        @"Connection: close\r\n"
        @"Content-Length: %lu\r\n"
        @"\r\n"
        @"%@",
        (unsigned long)[body lengthOfBytesUsingEncoding:NSUTF8StringEncoding], body];
    const char *bytes = response.UTF8String;
    send(client, bytes, strlen(bytes), 0);
    close(client);
}

- (NSString *)userAgentForPath:(NSString *)path
{
    @synchronized (self) {
        return self.userAgentsByPath[path];
    }
}
@end

@interface UserAgentNavigationProbe : NSObject <WKNavigationDelegate>
@property (nonatomic, assign) NSUInteger finishedCount;
@property (nonatomic, assign) NSUInteger failedCount;
@end

@implementation UserAgentNavigationProbe
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    (void)webView;
    (void)navigation;
    self.finishedCount += 1;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    (void)webView;
    (void)navigation;
    std::fprintf(stderr, "navigation failed: %s\n", error.localizedDescription.UTF8String);
    self.failedCount += 1;
}
@end

static bool spinUntil(bool (^done)(void))
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return done();
}

static NSString *readUserAgentSync(WKWebView *webView)
{
    __block bool finished = false;
    __block NSString *userAgent = nil;
    electrobun::readUserAgent(webView, ^(NSString *result) {
        userAgent = result;
        finished = true;
    });
    spinUntil(^bool { return finished; });
    return userAgent;
}

static bool loadPath(WKWebView *webView, UserAgentNavigationProbe *probe, UserAgentRecordingServer *server, NSString *path)
{
    NSUInteger expected = probe.finishedCount + 1;
    NSUInteger failuresBefore = probe.failedCount;
    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:%u%@", server.port, path];
    [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
    return spinUntil(^bool { return probe.finishedCount >= expected || probe.failedCount > failuresBefore; }) &&
        probe.finishedCount >= expected;
}

static void testRealWKWebViewRequests()
{
    [NSApplication sharedApplication];

    UserAgentRecordingServer *server = [[UserAgentRecordingServer alloc] init];
    CHECK([server start], "local HTTP server must start");

    WKWebView *probeView = electrobun::createDefaultUserAgentProbe();
    NSString *defaultUserAgent = readUserAgentSync(probeView);
    CHECK(defaultUserAgent.length > 0, "default probe must report WebKit's user agent");
    CHECK([defaultUserAgent containsString:@"AppleWebKit/"], "default user agent must be WebKit's");

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    WKWebView *webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320)
                                            configuration:configuration];
    UserAgentNavigationProbe *probe = [[UserAgentNavigationProbe alloc] init];
    webView.navigationDelegate = probe;

    NSString *initial = @"Mozilla/5.0 (Macintosh) ElectrobunUserAgentTest/1";
    electrobun::setCustomUserAgent(webView, initial);
    CHECK(loadPath(webView, probe, server, @"/initial"), "first navigation must finish");
    CHECK([[server userAgentForPath:@"/initial"] isEqualToString:initial],
          "first request must carry the user agent set before loading");
    CHECK([readUserAgentSync(webView) isEqualToString:initial],
          "client-world read must return the override despite the page spoofing navigator.userAgent");

    NSString *changed = @"Mozilla/5.0 (Macintosh) ElectrobunUserAgentTest/2";
    electrobun::setCustomUserAgent(webView, changed);
    CHECK(loadPath(webView, probe, server, @"/changed"), "navigation after change must finish");
    CHECK([[server userAgentForPath:@"/changed"] isEqualToString:changed],
          "a user agent changed after load must reach the next request");

    electrobun::setCustomUserAgent(webView, nil);
    CHECK(webView.customUserAgent.length == 0, "clearing must remove the override");
    CHECK(loadPath(webView, probe, server, @"/reset"), "navigation after reset must finish");
    CHECK([[server userAgentForPath:@"/reset"] isEqualToString:defaultUserAgent],
          "after clearing, requests must carry the default the probe reported");
    CHECK([readUserAgentSync(webView) isEqualToString:defaultUserAgent],
          "after clearing, the page must see the default the probe reported");

    electrobun::setCustomUserAgent(webView, @"");
    CHECK(webView.customUserAgent.length == 0, "an empty string must also clear the override");

    if (failures == 0) {
        std::printf("PASS: request and page user agents follow customUserAgent, default reads WebKit's own\n");
    }
    webView.navigationDelegate = nil;
    [webView stopLoading];
}

int main()
{
    @autoreleasepool {
        testRealWKWebViewRequests();
    }

    if (failures == 0) {
        std::printf("PASS: macOS user-agent native tests\n");
        return 0;
    }
    return 1;
}
