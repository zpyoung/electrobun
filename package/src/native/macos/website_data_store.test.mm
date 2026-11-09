#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include <cstdio>

#include "website_data_store.h"

using electrobun::PartitionDataStores;

static int failures = 0;

#define CHECK(condition, message) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "FAIL: %s\n", message); \
            ++failures; \
        } \
    } while (false)

static bool waitUntil(BOOL (^done)(void))
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return done();
}

static void testStorageTypes()
{
    NSSet *all = [WKWebsiteDataStore allWebsiteDataTypes];
    CHECK([electrobun::websiteDataTypesFromJSON(@"") isEqualToSet:all], "empty types must mean all types");
    CHECK([electrobun::websiteDataTypesFromJSON(@"[\"all\"]") isEqualToSet:all], "\"all\" must mean all types");
    CHECK([electrobun::websiteDataTypesFromJSON(@"[\"cookies\"]")
              isEqualToSet:[NSSet setWithObject:WKWebsiteDataTypeCookies]],
        "cookies must map to the cookie data type");
    CHECK(electrobun::websiteDataTypesFromJSON(@"[\"cookies\",\"history\"]") == nil,
        "an unknown type must reject the whole request");
    CHECK(electrobun::websiteDataTypesFromJSON(@"[]") == nil, "an empty list must be rejected");
    CHECK(electrobun::websiteDataTypesFromJSON(@"{\"all\":true}") == nil, "non-array JSON must be rejected");
}

static void testDerivedIdentifiersAreStable()
{
    // existing persist: partitions must keep resolving to the stores they
    // already have data in.
    CHECK([[PartitionDataStores::shared().identifierForPartition(@"persist:default") UUIDString]
              isEqualToString:@"37A8EEC1-CE19-687D-132F-E29051DCA629"],
        "persist:default must keep its derived identifier");
    CHECK(PartitionDataStores::shared().identifierForPartition(@"temp:session") == nil,
        "non-persistent partitions must have no identifier");
}

static void testAssignIdentifier()
{
    PartitionDataStores &stores = PartitionDataStores::shared();
    NSString *partition = [@"persist:assign-" stringByAppendingString:[NSUUID UUID].UUIDString];
    NSString *identifier = [NSUUID UUID].UUIDString;

    if (!PartitionDataStores::supportsIdentifiers()) {
        CHECK(stores.assignIdentifier(partition, identifier) == electrobun::StorageIdentifierUnsupportedPlatform,
            "macOS before 14 must report identifiers unsupported");
        return;
    }

    CHECK(stores.assignIdentifier(partition, @"not-a-uuid") == electrobun::StorageIdentifierInvalid,
        "a malformed identifier must be rejected");
    CHECK(stores.assignIdentifier(@"temp:session", identifier) == electrobun::StorageIdentifierUnsupportedPartition,
        "non-persistent partitions must reject identifiers");
    CHECK(stores.assignIdentifier(partition, identifier) == electrobun::StorageIdentifierSet,
        "a persistent partition without webviews must accept an identifier");
    CHECK([[stores.identifierForPartition(partition) UUIDString] isEqualToString:identifier],
        "the partition must resolve to the assigned identifier");

    stores.noteWebviewCreated(partition);
    CHECK(stores.assignIdentifier(partition, identifier) == electrobun::StorageIdentifierSet,
        "re-assigning the same identifier must succeed after a webview exists");
    CHECK(stores.assignIdentifier(partition, [NSUUID UUID].UUIDString) == electrobun::StorageIdentifierInUse,
        "a different identifier must be refused once a webview exists");
    CHECK([[stores.identifierForPartition(partition) UUIDString] isEqualToString:identifier],
        "a refused assignment must leave the identifier unchanged");
}

static bool setCookie(WKWebsiteDataStore *store, NSString *name)
{
    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
        NSHTTPCookieDomain : @"electrobun-storage.test",
        NSHTTPCookiePath : @"/",
        NSHTTPCookieName : name,
        NSHTTPCookieValue : @"1",
        NSHTTPCookieExpires : [NSDate dateWithTimeIntervalSinceNow:3600],
    }];
    __block BOOL done = NO;
    [store.httpCookieStore setCookie:cookie completionHandler:^{
        done = YES;
    }];
    return waitUntil(^BOOL { return done; });
}

static NSInteger recordCount(WKWebsiteDataStore *store)
{
    __block NSInteger count = -1;
    [store fetchDataRecordsOfTypes:[WKWebsiteDataStore allWebsiteDataTypes]
                 completionHandler:^(NSArray<WKWebsiteDataRecord *> *records) {
                     count = (NSInteger)records.count;
                 }];
    waitUntil(^BOOL { return count >= 0; });
    return count;
}

static electrobun::StorageClearStatus clear(NSString *partition, NSString *typesJson)
{
    __block BOOL done = NO;
    __block electrobun::StorageClearStatus result = electrobun::StorageClearTimedOut;
    electrobun::clearPartitionWebsiteData(partition, typesJson, ^(electrobun::StorageClearStatus status) {
        result = status;
        done = YES;
    });
    waitUntil(^BOOL { return done; });
    return result;
}

static void removeStore(NSString *identifier)
{
    if (@available(macOS 14.0, *)) {
        __block BOOL done = NO;
        [WKWebsiteDataStore removeDataStoreForIdentifier:[[NSUUID alloc] initWithUUIDString:identifier]
                                       completionHandler:^(NSError *error) {
                                           if (error)
                                               std::fprintf(stderr, "note: store %s not removed: %s\n",
                                                   identifier.UTF8String,
                                                   error.localizedDescription.UTF8String);
                                           done = YES;
                                       }];
        waitUntil(^BOOL { return done; });
    }
}

static void testClearReportsCompletionPerStore()
{
    CHECK(clear(@"temp:session", @"") == electrobun::StorageClearUnsupportedPartition,
        "non-persistent partitions must report the clear unsupported");
    CHECK(clear(@"persist:unused", @"[\"history\"]") == electrobun::StorageClearInvalidTypes,
        "unknown types must fail before touching the store");

    if (!PartitionDataStores::supportsIdentifiers()) {
        std::printf("SKIP: per-partition stores need macOS 14\n");
        return;
    }

    PartitionDataStores &stores = PartitionDataStores::shared();
    NSString *clearedPartition = [@"persist:cleared-" stringByAppendingString:[NSUUID UUID].UUIDString];
    NSString *keptPartition = [@"persist:kept-" stringByAppendingString:[NSUUID UUID].UUIDString];
    NSString *clearedIdentifier = [NSUUID UUID].UUIDString;
    NSString *keptIdentifier = [NSUUID UUID].UUIDString;
    CHECK(stores.assignIdentifier(clearedPartition, clearedIdentifier) == electrobun::StorageIdentifierSet,
        "test partition must accept its identifier");
    CHECK(stores.assignIdentifier(keptPartition, keptIdentifier) == electrobun::StorageIdentifierSet,
        "second test partition must accept its identifier");

    @autoreleasepool {
        WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
        configuration.websiteDataStore = stores.dataStoreForPartition(clearedPartition);
        WKWebView *webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 320, 240)
                                                configuration:configuration];
        CHECK([electrobun::dataStoreIdentifierString(webView.configuration.websiteDataStore)
                  isEqualToString:clearedIdentifier],
            "a webview must report the identifier its partition was assigned");

        WKWebsiteDataStore *clearedStore = stores.dataStoreForPartition(clearedPartition);
        WKWebsiteDataStore *keptStore = stores.dataStoreForPartition(keptPartition);
        CHECK(setCookie(clearedStore, @"cleared"), "cookie must be written to the first store");
        CHECK(setCookie(keptStore, @"kept"), "cookie must be written to the second store");
        CHECK(recordCount(clearedStore) > 0, "first store must hold data before the clear");

        CHECK(clear(clearedPartition, @"[\"all\"]") == electrobun::StorageClearCleared,
            "the clear must report completion");
        CHECK(recordCount(clearedStore) == 0, "the cleared store must hold no website data");
        CHECK(recordCount(keptStore) > 0, "another partition's store must keep its data");

        [webView removeFromSuperview];
    }

    removeStore(clearedIdentifier);
    removeStore(keptIdentifier);
}

int main()
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        testStorageTypes();
        testDerivedIdentifiersAreStable();
        testAssignIdentifier();
        testClearReportsCompletionPerStore();
    }

    if (failures == 0) {
        std::printf("PASS: macOS website data store native tests\n");
        return 0;
    }
    return 1;
}
