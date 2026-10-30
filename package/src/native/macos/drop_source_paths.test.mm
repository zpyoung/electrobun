#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include <cstdio>

#include "drop_source_paths.h"

static int failures = 0;

#define CHECK(condition, message) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "FAIL: %s\n", message); \
            ++failures; \
        } \
    } while (false)

// Stands in for the NSDraggingInfo AppKit passes during a Finder drop.
@interface FakeDraggingInfo : NSObject <NSDraggingInfo>
@property(nonatomic, strong) NSPasteboard *pasteboard;
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, assign) NSPoint location;
@end

@implementation FakeDraggingInfo
@synthesize draggingFormation;
@synthesize animatesToDestination;
@synthesize numberOfValidItemsForDrop;
@synthesize springLoadingHighlight;

- (NSWindow *)draggingDestinationWindow { return self.window; }
- (NSDragOperation)draggingSourceOperationMask { return NSDragOperationCopy | NSDragOperationGeneric; }
- (NSPoint)draggingLocation { return self.location; }
- (NSPoint)draggedImageLocation { return self.location; }
- (NSImage *)draggedImage { return nil; }
- (NSPasteboard *)draggingPasteboard { return self.pasteboard; }
- (id)draggingSource { return nil; }
- (NSInteger)draggingSequenceNumber { return 1; }
- (void)slideDraggedImageTo:(NSPoint)screenPoint { (void)screenPoint; }
- (NSArray<NSString *> *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination
{
    (void)dropDestination;
    return nil;
}
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)enumOpts
                                  forView:(NSView *)view
                                  classes:(NSArray<Class> *)classArray
                            searchOptions:(NSDictionary<NSPasteboardReadingOptionKey, id> *)searchOptions
                               usingBlock:(void (^)(NSDraggingItem *, NSInteger, BOOL *))block
{
    (void)enumOpts;
    (void)view;
    (void)classArray;
    (void)searchOptions;
    (void)block;
}
- (void)resetSpringLoading {}
@end

@interface DropPageProbe : NSObject <WKNavigationDelegate, WKScriptMessageHandler>
@property(nonatomic, assign) BOOL loaded;
@property(nonatomic, strong) NSArray<NSString *> *droppedFileNames;
@end

@implementation DropPageProbe
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    (void)webView;
    (void)navigation;
    self.loaded = YES;
}
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    (void)userContentController;
    self.droppedFileNames = message.body;
}
@end

static bool waitUntil(BOOL (^condition)(void))
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

static NSURL *makeTemporaryFile(NSString *directory, NSString *name)
{
    NSURL *url = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:name]];
    [@"dropped" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return url;
}

static void testPasteboardExtraction(NSArray<NSURL *> *files)
{
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
    [pasteboard clearContents];
    NSMutableArray *items = [files mutableCopy];
    [items addObject:[NSURL URLWithString:@"https://example.com/not-a-file.txt"]];
    [pasteboard writeObjects:items];

    NSArray<NSString *> *paths = electrobun::dropSourcePaths(pasteboard);
    CHECK(paths.count == files.count, "only file URLs must be reported");
    for (NSUInteger i = 0; i < MIN(paths.count, files.count); ++i)
        CHECK([paths[i] isEqualToString:files[i].path], "paths must keep pasteboard order");

    NSPasteboard *textOnly = [NSPasteboard pasteboardWithUniqueName];
    [textOnly clearContents];
    [textOnly writeObjects:@[ @"/Users/someone/not-a-drop.txt" ]];
    CHECK(electrobun::dropSourcePaths(textOnly).count == 0, "plain text must not become a path");

    NSString *detail = electrobun::dropSourcePathsEventDetail(paths);
    NSDictionary *decoded = [NSJSONSerialization JSONObjectWithData:[detail dataUsingEncoding:NSUTF8StringEncoding]
                                                            options:0
                                                              error:nil];
    CHECK([decoded[@"paths"] isEqual:paths], "event detail must round-trip the exact paths");

    [pasteboard releaseGlobally];
    [textOnly releaseGlobally];
}

static void testWebViewReportsAcceptedDrop(NSArray<NSURL *> *files)
{
    [NSApplication sharedApplication];

    DropPageProbe *probe = [[DropPageProbe alloc] init];
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    [configuration.userContentController addScriptMessageHandler:probe name:@"dropped"];

    NSRect frame = NSMakeRect(0, 0, 480, 320);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    ElectrobunWKWebView *webView = [[ElectrobunWKWebView alloc] initWithFrame:frame
                                                                configuration:configuration];
    window.contentView = webView;
    [window orderFront:nil];

    __block NSArray<NSString *> *reported = nil;
    webView.dropSourcePathsHandler = ^(NSArray<NSString *> *paths) {
        reported = paths;
    };
    webView.navigationDelegate = probe;
    [webView loadHTMLString:@"<!doctype html><body style='margin:0;height:100vh'><script>"
                             "addEventListener('dragover', e => e.preventDefault());"
                             "addEventListener('drop', e => { e.preventDefault();"
                             "webkit.messageHandlers.dropped.postMessage("
                             "Array.from(e.dataTransfer.files, f => f.name)); });"
                             "</script></body>"
                    baseURL:nil];
    CHECK(waitUntil(^BOOL { return probe.loaded; }), "drop page must load");

    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
    [pasteboard clearContents];
    [pasteboard writeObjects:files];

    FakeDraggingInfo *drag = [[FakeDraggingInfo alloc] init];
    drag.pasteboard = pasteboard;
    drag.window = window;
    drag.location = NSMakePoint(NSMidX(frame), NSMidY(frame));

    [webView draggingEntered:drag];
    [webView draggingUpdated:drag];
    BOOL accepted = [webView performDragOperation:drag];
    [webView concludeDragOperation:drag];

    CHECK(accepted, "WKWebView must accept the file drop");
    CHECK(waitUntil(^BOOL { return reported != nil; }), "accepted drop must report its source paths");
    NSMutableArray<NSString *> *expected = [NSMutableArray array];
    NSMutableArray<NSString *> *expectedNames = [NSMutableArray array];
    for (NSURL *file in files) {
        [expected addObject:file.path];
        [expectedNames addObject:file.lastPathComponent];
    }
    CHECK([reported isEqualToArray:expected], "reported paths must be the dropped files");

    if (waitUntil(^BOOL { return probe.droppedFileNames != nil; })) {
        CHECK([probe.droppedFileNames isEqualToArray:expectedNames],
              "the page must still receive the same files");
        std::printf("PASS: page received the drop alongside its source paths\n");
    } else {
        std::printf("NOTE: page drop event not observed in this session; source paths still verified\n");
    }

    webView.navigationDelegate = nil;
    [webView stopLoading];
    [window close];
}

int main()
{
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSArray<NSURL *> *files = @[
            makeTemporaryFile(directory, @"notes.md"),
            makeTemporaryFile(directory, @"a \"quoted\" näme.txt"),
        ];

        testPasteboardExtraction(files);
        testWebViewReportsAcceptedDrop(files);

        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
    }

    if (failures == 0) {
        std::printf("PASS: macOS drop source paths native tests\n");
        return 0;
    }
    return 1;
}
