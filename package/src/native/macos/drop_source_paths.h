#pragma once

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

namespace electrobun {

// File URLs on a drag pasteboard, as filesystem paths in pasteboard order.
// Non-file items (web URLs, text, file promises) are left out.
inline NSArray<NSString *> *dropSourcePaths(NSPasteboard *pasteboard)
{
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[ [NSURL class] ]
                                                       options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        // Finder can hand out file reference URLs (file:///.file/id=...).
        NSString *path = url.filePathURL.path;
        if (path.length > 0)
            [paths addObject:path];
    }
    return paths;
}

inline NSString *dropSourcePathsEventDetail(NSArray<NSString *> *paths)
{
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"paths" : paths ?: @[]}
                                                   options:0
                                                     error:nil];
    return json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
}

} // namespace electrobun

// Reports the source paths of a native file drop that WebKit accepted, without
// changing what the page receives.
@interface ElectrobunWKWebView : WKWebView
@property(nonatomic, copy) void (^dropSourcePathsHandler)(NSArray<NSString *> *paths);
@end

@implementation ElectrobunWKWebView

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    NSArray<NSString *> *paths = electrobun::dropSourcePaths(sender.draggingPasteboard);
    BOOL accepted = [super performDragOperation:sender];
    if (accepted && paths.count > 0 && self.dropSourcePathsHandler)
        self.dropSourcePathsHandler(paths);
    return accepted;
}

@end
