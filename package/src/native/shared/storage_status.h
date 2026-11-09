// storage_status.h - Result codes for session storage calls.
// Every platform wrapper returns these values; sdks/main/proc/sessionStorage.ts
// maps them to typed results, so the numbers are part of the FFI contract.

#ifndef ELECTROBUN_STORAGE_STATUS_H
#define ELECTROBUN_STORAGE_STATUS_H

#include <cstdint>

namespace electrobun {

enum StorageClearStatus : int32_t {
    StorageClearCleared = 0,
    StorageClearTimedOut = 1,
    StorageClearUnsupportedPlatform = 2,
    StorageClearUnsupportedPartition = 3,
    StorageClearInvalidTypes = 4,
};

enum StorageIdentifierStatus : int32_t {
    StorageIdentifierSet = 0,
    StorageIdentifierUnsupportedPlatform = 1,
    StorageIdentifierUnsupportedPartition = 2,
    StorageIdentifierInvalid = 3,
    StorageIdentifierInUse = 4,
};

} // namespace electrobun

#endif // ELECTROBUN_STORAGE_STATUS_H
