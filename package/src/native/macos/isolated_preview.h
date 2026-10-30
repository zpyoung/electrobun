#pragma once

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

#include <cstdint>

// An isolated preview is a WKWebView whose documents and assets come only from
// one app-owned URL scheme. Every fence lives in WebKit configuration and
// delegate decisions, so page script and response headers cannot lift them.

typedef void (^ElectrobunIsolatedPreviewRequestHandler)(uint32_t requestId,
                                                        NSURLRequest *request,
                                                        NSData *body);

// Request bodies past this size get a 413 without reaching the app.
static const NSUInteger kElectrobunIsolatedPreviewMaxBodyBytes = 16 * 1024 * 1024;

// WebKit hands some bodies (form posts, fetch with a stream) over as a stream
// rather than HTTPBody. Returns nil when the body exceeds the limit.
inline NSData *electrobunIsolatedPreviewRequestBody(NSURLRequest *request) {
  if (request.HTTPBody) {
    return request.HTTPBody.length <= kElectrobunIsolatedPreviewMaxBodyBytes
               ? request.HTTPBody
               : nil;
  }
  NSInputStream *stream = request.HTTPBodyStream;
  if (!stream) {
    return [NSData data];
  }
  NSMutableData *body = [NSMutableData data];
  uint8_t buffer[16384];
  [stream open];
  while (true) {
    NSInteger read = [stream read:buffer maxLength:sizeof(buffer)];
    if (read <= 0) {
      break;
    }
    if (body.length + (NSUInteger)read > kElectrobunIsolatedPreviewMaxBodyBytes) {
      body = nil;
      break;
    }
    [body appendBytes:buffer length:(NSUInteger)read];
  }
  [stream close];
  return body;
}

// Hands each scheme request to the app and holds the WebKit task until the app
// answers or WebKit stops it. Main thread only, like WKURLSchemeHandler itself.
@interface ElectrobunIsolatedPreviewSchemeHandler : NSObject <WKURLSchemeHandler>
- (instancetype)initWithRequestHandler:
    (ElectrobunIsolatedPreviewRequestHandler)requestHandler;
- (BOOL)respondToRequest:(uint32_t)requestId
                  status:(NSInteger)status
                 headers:(NSDictionary<NSString *, NSString *> *)headers
                    body:(NSData *)body;
- (NSUInteger)pendingRequestCount;
@end

@implementation ElectrobunIsolatedPreviewSchemeHandler {
  ElectrobunIsolatedPreviewRequestHandler _requestHandler;
  NSMutableDictionary<NSNumber *, id<WKURLSchemeTask>> *_tasks;
  uint32_t _nextRequestId;
}

- (instancetype)initWithRequestHandler:
    (ElectrobunIsolatedPreviewRequestHandler)requestHandler {
  self = [super init];
  if (self) {
    _requestHandler = [requestHandler copy];
    _tasks = [NSMutableDictionary dictionary];
    _nextRequestId = 1;
  }
  return self;
}

- (void)webView:(WKWebView *)webView
    startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
  uint32_t requestId = _nextRequestId++;
  if (_nextRequestId == 0) {
    _nextRequestId = 1;
  }
  _tasks[@(requestId)] = urlSchemeTask;
  NSData *body = electrobunIsolatedPreviewRequestBody(urlSchemeTask.request);
  if (!body) {
    [self respondToRequest:requestId
                    status:413
                   headers:@{@"Content-Type" : @"text/plain; charset=utf-8"}
                      body:[NSData data]];
    return;
  }
  if (_requestHandler) {
    _requestHandler(requestId, urlSchemeTask.request, body);
  }
}

- (void)webView:(WKWebView *)webView
    stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
  // WebKit raises if a stopped task is answered, so forget it before the app
  // replies.
  for (NSNumber *requestId in [_tasks allKeys]) {
    if (_tasks[requestId] == urlSchemeTask) {
      [_tasks removeObjectForKey:requestId];
    }
  }
}

- (BOOL)respondToRequest:(uint32_t)requestId
                  status:(NSInteger)status
                 headers:(NSDictionary<NSString *, NSString *> *)headers
                    body:(NSData *)body {
  id<WKURLSchemeTask> task = _tasks[@(requestId)];
  if (!task) {
    return NO;
  }
  [_tasks removeObjectForKey:@(requestId)];

  NSMutableDictionary<NSString *, NSString *> *headerFields =
      [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
  BOOL hasContentType = NO;
  for (NSString *name in headerFields) {
    if ([name caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame) {
      hasContentType = YES;
    }
  }
  if (!hasContentType) {
    headerFields[@"Content-Type"] = @"application/octet-stream";
  }

  NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
       initWithURL:task.request.URL
        statusCode:(status >= 100 && status <= 599) ? status : 500
       HTTPVersion:@"HTTP/1.1"
      headerFields:headerFields];
  [task didReceiveResponse:response];
  if (body.length > 0) {
    [task didReceiveData:body];
  }
  [task didFinish];
  return YES;
}

- (NSUInteger)pendingRequestCount {
  return _tasks.count;
}
@end

namespace electrobun {

// Letters, digits and hyphens only: the scheme is embedded in content rule
// regexes, where `+` and `.` would need escaping.
inline bool isValidIsolatedPreviewScheme(NSString *scheme) {
  if (scheme.length == 0 || scheme.length > 64) {
    return false;
  }
  static NSRegularExpression *pattern = [NSRegularExpression
      regularExpressionWithPattern:@"^[a-z][a-z0-9-]*$"
                           options:0
                             error:nil];
  if ([pattern numberOfMatchesInString:scheme
                               options:0
                                 range:NSMakeRange(0, scheme.length)] != 1) {
    return false;
  }
  // views:// and appdata:// would expose the app bundle and its data folder.
  if ([scheme isEqualToString:@"views"] || [scheme isEqualToString:@"appdata"]) {
    return false;
  }
  return ![WKWebView handlesURLScheme:scheme];
}

inline NSString *isolatedPreviewContentRuleListIdentifier(NSString *scheme) {
  return [@"electrobun-isolated-preview-" stringByAppendingString:scheme];
}

// Blocks every load, then exempts the preview scheme and the schemes that never
// leave the process. WebKit applies content rules to every load a page or its
// workers start: subresources, fetch, beacons, WebSockets and preconnects.
inline NSString *isolatedPreviewContentRuleList(NSString *scheme) {
  NSArray *rules = @[
    @{
      @"trigger" : @{@"url-filter" : @".*"},
      @"action" : @{@"type" : @"block"}
    },
    @{
      @"trigger" : @{@"url-filter" : [NSString stringWithFormat:@"^%@:", scheme]},
      @"action" : @{@"type" : @"ignore-previous-rules"}
    },
    @{
      @"trigger" : @{@"url-filter" : @"^about:"},
      @"action" : @{@"type" : @"ignore-previous-rules"}
    },
    @{
      @"trigger" : @{@"url-filter" : @"^data:"},
      @"action" : @{@"type" : @"ignore-previous-rules"}
    },
    @{
      @"trigger" : @{@"url-filter" : @"^blob:"},
      @"action" : @{@"type" : @"ignore-previous-rules"}
    },
  ];
  NSData *json = [NSJSONSerialization dataWithJSONObject:rules
                                                 options:0
                                                   error:nil];
  return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

inline void loadIsolatedPreviewContentRuleList(
    NSString *scheme,
    void (^completion)(WKContentRuleList *ruleList, NSError *error)) {
  [[WKContentRuleListStore defaultStore]
      compileContentRuleListForIdentifier:
          isolatedPreviewContentRuleListIdentifier(scheme)
                   encodedContentRuleList:isolatedPreviewContentRuleList(scheme)
                        completionHandler:completion];
}

// Content rules cannot see WebRTC, which opens UDP straight from the network
// stack. Lockdown Mode removes RTCPeerConnection (and WebAssembly, WebGL and
// service workers) from the page, so ICE never gathers.
inline void configureIsolatedPreview(WKWebViewConfiguration *configuration,
                                     NSString *scheme,
                                     id<WKURLSchemeHandler> schemeHandler) {
  configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
  configuration.defaultWebpagePreferences.lockdownModeEnabled = YES;
  configuration.preferences.javaScriptCanOpenWindowsAutomatically = NO;
  configuration.preferences.fraudulentWebsiteWarningEnabled = NO;
  [configuration setURLSchemeHandler:schemeHandler forURLScheme:scheme];
}

// Documents may only come from the preview scheme. about:blank stays reachable
// because a view starts there and an iframe may be blank or srcdoc.
inline bool isolatedPreviewAllowsNavigation(NSURL *url, NSString *scheme) {
  NSString *urlScheme = url.scheme.lowercaseString;
  if (urlScheme.length == 0) {
    return false;
  }
  if ([urlScheme isEqualToString:scheme]) {
    return true;
  }
  if ([urlScheme isEqualToString:@"about"]) {
    NSString *specifier = url.resourceSpecifier ?: @"";
    return [specifier isEqualToString:@"blank"] ||
           [specifier isEqualToString:@"srcdoc"];
  }
  return false;
}

inline WKNavigationActionPolicy
isolatedPreviewNavigationActionPolicy(WKNavigationAction *navigationAction,
                                      NSString *scheme) {
  if (navigationAction.shouldPerformDownload ||
      !isolatedPreviewAllowsNavigation(navigationAction.request.URL, scheme)) {
    return WKNavigationActionPolicyCancel;
  }
  return WKNavigationActionPolicyAllow;
}

// A response WebKit cannot render would otherwise become a download.
inline WKNavigationResponsePolicy
isolatedPreviewNavigationResponsePolicy(WKNavigationResponse *navigationResponse) {
  return navigationResponse.canShowMIMEType ? WKNavigationResponsePolicyAllow
                                            : WKNavigationResponsePolicyCancel;
}

} // namespace electrobun
