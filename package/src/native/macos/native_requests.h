#pragma once

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

#include <cstdint>
#include <unordered_map>
#include <vector>

// Native page requests: WebKit callbacks that wait for an application answer
// (JavaScript dialogs, auth and certificate challenges, download destinations,
// popups and external-app launches). Each pending request is resolved exactly
// once, either by the application's response or by its timeout, and every
// timeout resolves to the fail-closed outcome.
//
// All registry access happens on the main thread: WebKit invokes its delegates
// there, and the FFI entry points hop to it before touching the registry.

namespace electrobun {

enum NativeRequestKind : uint32_t {
    NativeRequestDialog = 1u << 0,
    NativeRequestAuth = 1u << 1,
    NativeRequestCertificate = 1u << 2,
    NativeRequestDownload = 1u << 3,
    NativeRequestPopup = 1u << 4,
    NativeRequestExternalApp = 1u << 5,
};

constexpr uint32_t kAllNativeRequestKinds = 0x3f;
constexpr double kDefaultNativeRequestTimeoutMs = 120000;

// `response` is nil when the request expired instead of being answered.
typedef void (^NativeRequestResolver)(NSDictionary *response);
typedef void (^NativeRequestExpired)(uint32_t requestId, NSString *reason);

class NativeRequestRegistry {
public:
    uint32_t add(uint32_t webviewId,
                 double timeoutMs,
                 NativeRequestResolver resolver,
                 NativeRequestExpired expired)
    {
        uint32_t requestId = nextRequestId_++;
        if (nextRequestId_ == 0)
            nextRequestId_ = 1;
        pending_[requestId] = Entry { webviewId, resolver, expired };

        double delayMs = timeoutMs > 0 ? timeoutMs : kDefaultNativeRequestTimeoutMs;
        NativeRequestRegistry *registry = this;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(),
                       ^{
                           registry->expire(requestId, @"timeout");
                       });
        return requestId;
    }

    // Returns false when the request is unknown, already resolved, expired, or
    // belongs to another webview.
    bool respond(uint32_t webviewId, uint32_t requestId, NSDictionary *response)
    {
        auto it = pending_.find(requestId);
        if (it == pending_.end() || it->second.webviewId != webviewId)
            return false;
        NativeRequestResolver resolver = it->second.resolver;
        pending_.erase(it);
        resolver(response ?: @{});
        return true;
    }

    bool expire(uint32_t requestId, NSString *reason)
    {
        auto it = pending_.find(requestId);
        if (it == pending_.end())
            return false;
        Entry entry = it->second;
        pending_.erase(it);
        entry.resolver(nil);
        if (entry.expired)
            entry.expired(requestId, reason);
        return true;
    }

    void expireAllForWebview(uint32_t webviewId, NSString *reason)
    {
        std::vector<uint32_t> requestIds;
        for (const auto &pair : pending_) {
            if (pair.second.webviewId == webviewId)
                requestIds.push_back(pair.first);
        }
        for (uint32_t requestId : requestIds)
            expire(requestId, reason);
    }

    bool isPending(uint32_t webviewId, uint32_t requestId) const
    {
        auto it = pending_.find(requestId);
        return it != pending_.end() && it->second.webviewId == webviewId;
    }

    size_t pendingCount() const { return pending_.size(); }

private:
    struct Entry {
        uint32_t webviewId;
        NativeRequestResolver resolver;
        NativeRequestExpired expired;
    };

    uint32_t nextRequestId_ = 1;
    std::unordered_map<uint32_t, Entry> pending_;
};

inline NSDictionary *parseNativeRequestResponse(const char *json)
{
    if (!json)
        return @{};
    NSData *data = [NSData dataWithBytes:json length:strlen(json)];
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [parsed isKindOfClass:[NSDictionary class]] ? parsed : @{};
}

inline bool responseAccepted(NSDictionary *response)
{
    id accept = response[@"accept"];
    return [accept isKindOfClass:[NSNumber class]] && [accept boolValue];
}

inline NSString *responseString(NSDictionary *response, NSString *key)
{
    id value = response[key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

// window.prompt() returns null when dismissed and a string when accepted.
inline NSString *promptResult(NSDictionary *response)
{
    if (!responseAccepted(response))
        return nil;
    return responseString(response, @"text") ?: @"";
}

// A declined, expired or credential-less auth response yields nil, which the
// caller turns into a cancelled challenge rather than default handling, so no
// stored credential is ever sent without the application's answer.
inline NSURLCredential *credentialForAuthResponse(NSDictionary *response)
{
    if (!responseAccepted(response))
        return nil;
    NSString *username = responseString(response, @"username");
    NSString *password = responseString(response, @"password");
    if (!username || !password)
        return nil;
    return [NSURLCredential credentialWithUser:username
                                      password:password
                                   persistence:NSURLCredentialPersistenceNone];
}

inline NSString *originString(WKSecurityOrigin *origin)
{
    if (!origin || origin.protocol.length == 0)
        return @"";
    if (origin.host.length == 0)
        return [NSString stringWithFormat:@"%@://", origin.protocol];
    if (origin.port == 0)
        return [NSString stringWithFormat:@"%@://%@", origin.protocol, origin.host];
    return [NSString stringWithFormat:@"%@://%@:%ld", origin.protocol, origin.host, (long)origin.port];
}

inline NSDictionary *frameDetails(WKFrameInfo *frame)
{
    return @{
        @"origin" : originString(frame.securityOrigin),
        @"frameUrl" : frame.request.URL.absoluteString ?: @"",
        @"isMainFrame" : @(frame ? frame.isMainFrame : YES),
    };
}

inline NSString *eventJSON(NSDictionary *details)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:details options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

// A URL the webview cannot load itself: neither a scheme WebKit handles nor
// one with a registered WKURLSchemeHandler. Loading it would hand it to
// another application.
inline bool isExternalAppURL(NSURL *url, WKWebViewConfiguration *configuration)
{
    NSString *scheme = url.scheme.lowercaseString;
    if (scheme.length == 0)
        return false;
    if ([WKWebView handlesURLScheme:scheme])
        return false;
    if (configuration && [configuration urlSchemeHandlerForURLScheme:scheme])
        return false;
    return true;
}

// Returns an absolute destination that does not exist yet, numbering the name
// like Finder does ("report (1).pdf") when the requested file is taken.
// Returns nil for relative paths or a missing parent directory.
inline NSString *uniqueDownloadPath(NSString *requestedPath)
{
    if (requestedPath.length == 0 || !requestedPath.isAbsolutePath)
        return nil;
    NSString *path = requestedPath.stringByStandardizingPath;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:path.stringByDeletingLastPathComponent isDirectory:&isDirectory] || !isDirectory)
        return nil;

    NSString *basePath = path.stringByDeletingPathExtension;
    NSString *extension = path.pathExtension;
    NSString *candidate = path;
    for (int counter = 1; [fileManager fileExistsAtPath:candidate]; ++counter) {
        candidate = extension.length > 0
            ? [NSString stringWithFormat:@"%@ (%d).%@", basePath, counter, extension]
            : [NSString stringWithFormat:@"%@ (%d)", basePath, counter];
    }
    return candidate;
}

} // namespace electrobun

// A popup WebKit asked for, created with WebKit's configuration so the opener
// relationship and the original request (method, body, target name) survive,
// but not yet owned by an application view. Its first navigation decision is
// held until the application adopts the popup or the request expires.
@interface ElectrobunParkedPopup : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, assign) uint32_t openerWebviewId;
@property (nonatomic, assign) BOOL openerSandboxed;
@property (nonatomic, assign) BOOL adopting;
@property (nonatomic, strong) WKNavigationAction *heldAction;
@property (nonatomic, copy) void (^heldDecision)(WKNavigationActionPolicy);

- (instancetype)initWithConfiguration:(WKWebViewConfiguration *)configuration;
// Replays the held decision through the adopting view's navigation delegate.
- (void)releaseToNavigationDelegate:(id<WKNavigationDelegate>)delegate;
// Cancels the held navigation and drops the webview, which closes the page and
// lets the opener observe `closed`.
- (void)discard;
@end

@implementation ElectrobunParkedPopup

- (instancetype)initWithConfiguration:(WKWebViewConfiguration *)configuration
{
    self = [super init];
    if (self) {
        // The opener's user content controller carries its webview-specific
        // scripts and message handlers; the adopting view installs its own.
        configuration.userContentController = [[WKUserContentController alloc] init];
        _webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
        _webView.navigationDelegate = self;
    }
    return self;
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    (void)webView;
    if (self.heldDecision) {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    self.heldAction = navigationAction;
    self.heldDecision = decisionHandler;
}

- (void)releaseToNavigationDelegate:(id<WKNavigationDelegate>)delegate
{
    WKWebView *webView = self.webView;
    WKNavigationAction *action = self.heldAction;
    void (^decision)(WKNavigationActionPolicy) = self.heldDecision;
    self.heldAction = nil;
    self.heldDecision = nil;
    self.webView = nil;
    webView.navigationDelegate = delegate;
    if (!decision)
        return;
    if ([delegate respondsToSelector:@selector(webView:decidePolicyForNavigationAction:decisionHandler:)]) {
        [delegate webView:webView decidePolicyForNavigationAction:action decisionHandler:decision];
    } else {
        decision(WKNavigationActionPolicyAllow);
    }
}

- (void)discard
{
    void (^decision)(WKNavigationActionPolicy) = self.heldDecision;
    self.heldAction = nil;
    self.heldDecision = nil;
    if (decision)
        decision(WKNavigationActionPolicyCancel);
    self.webView.navigationDelegate = nil;
    [self.webView stopLoading];
    self.webView = nil;
}

@end
