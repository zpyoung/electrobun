import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
	storageClearResult,
	storageIdentifierResult,
} from "../proc/sessionStorage";

const statusHeader = readFileSync(
	join(import.meta.dirname, "../../../native/shared/storage_status.h"),
	"utf8",
);

function nativeStatus(name: string): number {
	const match = statusHeader.match(new RegExp(`\\b${name} = (\\d+),`));
	if (!match) throw new Error(`storage_status.h does not define ${name}`);
	return Number(match[1]);
}

describe("Session storage results", () => {
	test("maps every native clear status", () => {
		expect(storageClearResult(nativeStatus("StorageClearCleared"))).toEqual({
			status: "cleared",
		});
		expect(storageClearResult(nativeStatus("StorageClearTimedOut"))).toEqual({
			status: "failed",
			reason: "timeout",
		});
		expect(
			storageClearResult(nativeStatus("StorageClearUnsupportedPlatform")),
		).toEqual({ status: "unsupported", reason: "platform" });
		expect(
			storageClearResult(nativeStatus("StorageClearUnsupportedPartition")),
		).toEqual({ status: "unsupported", reason: "partition" });
		expect(storageClearResult(nativeStatus("StorageClearInvalidTypes"))).toEqual(
			{ status: "failed", reason: "invalid-types" },
		);
	});

	test("maps every native identifier status", () => {
		const identifier = "9B0C5E52-8F3A-4C1D-9E7B-2A6F4D8C1E35";
		expect(
			storageIdentifierResult(nativeStatus("StorageIdentifierSet"), identifier),
		).toEqual({ status: "set", identifier });
		expect(
			storageIdentifierResult(
				nativeStatus("StorageIdentifierUnsupportedPlatform"),
				identifier,
			),
		).toEqual({ status: "unsupported", reason: "platform" });
		expect(
			storageIdentifierResult(
				nativeStatus("StorageIdentifierUnsupportedPartition"),
				identifier,
			),
		).toEqual({ status: "unsupported", reason: "partition" });
		expect(
			storageIdentifierResult(nativeStatus("StorageIdentifierInvalid"), identifier),
		).toEqual({ status: "failed", reason: "invalid-identifier" });
		expect(
			storageIdentifierResult(nativeStatus("StorageIdentifierInUse"), identifier),
		).toEqual({ status: "failed", reason: "in-use" });
	});

	test("reports a set identifier the way WebKit spells it", () => {
		expect(
			storageIdentifierResult(0, "9b0c5e52-8f3a-4c1d-9e7b-2a6f4d8c1e35"),
		).toEqual({ status: "set", identifier: "9B0C5E52-8F3A-4C1D-9E7B-2A6F4D8C1E35" });
	});

	// an unknown code means the SDK and the native wrapper disagree on the ABI.
	test("rejects codes the native wrapper does not define", () => {
		expect(() => storageClearResult(99)).toThrow(/Unknown storage clear status/);
		expect(() => storageIdentifierResult(99, "x")).toThrow(
			/Unknown storage identifier status/,
		);
	});

	test("returns a fresh object each time", () => {
		const first = storageClearResult(0);
		(first as { status: string }).status = "mutated";
		expect(storageClearResult(0)).toEqual({ status: "cleared" });
	});
});
