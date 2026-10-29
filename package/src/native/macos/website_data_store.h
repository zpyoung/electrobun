#pragma once

#import <CommonCrypto/CommonCrypto.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

#include "../shared/storage_status.h"

namespace electrobun {

// Maps `persist:` partitions to WKWebsiteDataStore identifiers. A partition
// uses a hash of its name unless the app assigned an identifier before any
// webview was created for it.
class PartitionDataStores {
public:
    static PartitionDataStores &shared()
    {
        static PartitionDataStores instance;
        return instance;
    }

    static bool supportsIdentifiers()
    {
        if (@available(macOS 14.0, *))
            return true;
        return false;
    }

    static NSString *persistentName(NSString *partition)
    {
        if (![partition hasPrefix:@"persist:"])
            return nil;
        return [partition substringFromIndex:8];
    }

    static NSUUID *identifierFromName(NSString *name)
    {
        // hashes `name.length` (a UTF-16 count) bytes of the UTF-8 name; fixing
        // that would move existing non-ASCII partitions to new, empty stores.
        unsigned char hash[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(name.UTF8String, (CC_LONG)name.length, hash);
        uuid_t uuid;
        memcpy(uuid, hash, sizeof(uuid));
        return [[NSUUID alloc] initWithUUIDBytes:uuid];
    }

    // nil for partitions that are not persistent.
    NSUUID *identifierForPartition(NSString *partition)
    {
        NSString *name = persistentName(partition);
        if (!name)
            return nil;
        @synchronized(assigned_) {
            NSUUID *identifier = assigned_[partition];
            if (identifier)
                return identifier;
        }
        return identifierFromName(name);
    }

    StorageIdentifierStatus assignIdentifier(NSString *partition, NSString *identifierString)
    {
        if (!supportsIdentifiers())
            return StorageIdentifierUnsupportedPlatform;
        if (!persistentName(partition))
            return StorageIdentifierUnsupportedPartition;
        NSUUID *identifier = identifierString ? [[NSUUID alloc] initWithUUIDString:identifierString] : nil;
        if (!identifier)
            return StorageIdentifierInvalid;

        @synchronized(assigned_) {
            // Existing webviews keep the store they were created with.
            if ([partitionsWithWebviews_ containsObject:partition]
                && ![identifierForPartitionLocked(partition) isEqual:identifier])
                return StorageIdentifierInUse;
            assigned_[partition] = identifier;
        }
        return StorageIdentifierSet;
    }

    void noteWebviewCreated(NSString *partition)
    {
        if (!persistentName(partition))
            return;
        @synchronized(assigned_) {
            [partitionsWithWebviews_ addObject:partition];
        }
    }

    WKWebsiteDataStore *dataStoreForPartition(NSString *partition)
    {
        NSUUID *identifier = identifierForPartition(partition);
        if (!identifier)
            return [WKWebsiteDataStore nonPersistentDataStore];
        if (@available(macOS 14.0, *))
            return [WKWebsiteDataStore dataStoreForIdentifier:identifier];
        NSLog(@"[Session] Partition-specific data stores require macOS 14.0+, "
              @"using default store");
        return [WKWebsiteDataStore defaultDataStore];
    }

private:
    PartitionDataStores()
        : assigned_([NSMutableDictionary dictionary])
        , partitionsWithWebviews_([NSMutableSet set])
    {
    }

    NSUUID *identifierForPartitionLocked(NSString *partition)
    {
        return assigned_[partition] ?: identifierFromName(persistentName(partition));
    }

    NSMutableDictionary<NSString *, NSUUID *> *assigned_;
    NSMutableSet<NSString *> *partitionsWithWebviews_;
};

// nil when the JSON names no type or a type this platform can't clear.
inline NSSet<NSString *> *websiteDataTypesFromJSON(NSString *typesJson)
{
    if (typesJson.length == 0)
        return [WKWebsiteDataStore allWebsiteDataTypes];

    NSData *jsonData = [typesJson dataUsingEncoding:NSUTF8StringEncoding];
    id types = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    if (![types isKindOfClass:[NSArray class]])
        return nil;

    NSMutableSet<NSString *> *dataTypes = [NSMutableSet set];
    for (id type in (NSArray *)types) {
        if (![type isKindOfClass:[NSString class]])
            return nil;
        if ([type isEqualToString:@"all"]) {
            [dataTypes unionSet:[WKWebsiteDataStore allWebsiteDataTypes]];
        } else if ([type isEqualToString:@"cookies"]) {
            [dataTypes addObject:WKWebsiteDataTypeCookies];
        } else if ([type isEqualToString:@"localStorage"]) {
            [dataTypes addObject:WKWebsiteDataTypeLocalStorage];
        } else if ([type isEqualToString:@"sessionStorage"]) {
            [dataTypes addObject:WKWebsiteDataTypeSessionStorage];
        } else if ([type isEqualToString:@"indexedDB"]) {
            [dataTypes addObject:WKWebsiteDataTypeIndexedDBDatabases];
        } else if ([type isEqualToString:@"webSQL"]) {
            [dataTypes addObject:WKWebsiteDataTypeWebSQLDatabases];
        } else if ([type isEqualToString:@"cache"]) {
            [dataTypes addObject:WKWebsiteDataTypeDiskCache];
            [dataTypes addObject:WKWebsiteDataTypeMemoryCache];
        } else if ([type isEqualToString:@"serviceWorkers"]) {
            [dataTypes addObject:WKWebsiteDataTypeServiceWorkerRegistrations];
        } else {
            return nil;
        }
    }
    return dataTypes.count > 0 ? dataTypes : nil;
}

// Must run on the main thread. `completion` runs once WebKit reports the
// removal finished, or immediately when the request can't be served.
inline void clearPartitionWebsiteData(
    NSString *partition,
    NSString *typesJson,
    void (^completion)(StorageClearStatus status))
{
    // Each non-persistent lookup creates a new store, so it can't reach the
    // store a live webview was given.
    if (!PartitionDataStores::persistentName(partition)) {
        completion(StorageClearUnsupportedPartition);
        return;
    }
    NSSet<NSString *> *dataTypes = websiteDataTypesFromJSON(typesJson);
    if (!dataTypes) {
        completion(StorageClearInvalidTypes);
        return;
    }

    WKWebsiteDataStore *dataStore = PartitionDataStores::shared().dataStoreForPartition(partition);
    [dataStore removeDataOfTypes:dataTypes
                   modifiedSince:[NSDate dateWithTimeIntervalSince1970:0]
               completionHandler:^{
                   completion(StorageClearCleared);
               }];
}

// The UUID string of a webview's data store, or nil when it has none.
inline NSString *dataStoreIdentifierString(WKWebsiteDataStore *dataStore)
{
    if (@available(macOS 14.0, *))
        return dataStore.identifier.UUIDString;
    return nil;
}

} // namespace electrobun
