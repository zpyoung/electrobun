// Typed results for the session storage FFI calls. The numeric codes are
// defined in src/native/shared/storage_status.h.

/**
 * The outcome of `Session.clearStorageData`. `"cleared"` means the native
 * engine reported that removal finished; every other status means the data
 * may still be present.
 */
export type StorageClearResult =
	| { status: "cleared" }
	| { status: "failed"; reason: "timeout" | "invalid-types" }
	| { status: "unsupported"; reason: "platform" | "partition" };

/**
 * The outcome of `Session.setStorageIdentifier`. `"set"` means webviews
 * created for the partition from now on use the data store named by
 * `identifier`, given in the uppercase form WebKit reports.
 */
export type StorageIdentifierResult =
	| { status: "set"; identifier: string }
	| { status: "failed"; reason: "invalid-identifier" | "in-use" }
	| { status: "unsupported"; reason: "platform" | "partition" };

const storageClearResults: Record<number, StorageClearResult> = {
	0: { status: "cleared" },
	1: { status: "failed", reason: "timeout" },
	2: { status: "unsupported", reason: "platform" },
	3: { status: "unsupported", reason: "partition" },
	4: { status: "failed", reason: "invalid-types" },
};

const storageIdentifierFailures: Record<
	number,
	Exclude<StorageIdentifierResult, { status: "set" }>
> = {
	1: { status: "unsupported", reason: "platform" },
	2: { status: "unsupported", reason: "partition" },
	3: { status: "failed", reason: "invalid-identifier" },
	4: { status: "failed", reason: "in-use" },
};

export function storageClearResult(code: number): StorageClearResult {
	const result = storageClearResults[code];
	if (!result) throw new Error(`Unknown storage clear status ${code}`);
	return { ...result };
}

export function storageIdentifierResult(
	code: number,
	identifier: string,
): StorageIdentifierResult {
	if (code === 0) return { status: "set", identifier: identifier.toUpperCase() };
	const result = storageIdentifierFailures[code];
	if (!result) throw new Error(`Unknown storage identifier status ${code}`);
	return { ...result };
}
