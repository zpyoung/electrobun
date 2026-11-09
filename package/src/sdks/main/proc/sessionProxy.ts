export type SessionProxy = {
	/** `"http"` opens every connection, plain HTTP included, as an HTTP CONNECT tunnel. */
	type: "http" | "socks5";
	host: string;
	port: number;
	/** Only requests for these domains and their subdomains use the proxy. */
	matchDomains?: string[];
	/** Requests for these domains and their subdomains never use the proxy. */
	excludedDomains?: string[];
};

/**
 * Validates a session proxy and hands it to the native wrapper.
 * Throws when the platform can't route a session through a proxy, so callers
 * never mistake an unsupported platform for a configured one.
 */
export function setSessionProxy(
	symbols: {
		supportsProxy: () => boolean;
		setProxy: (partition: string, proxyJson: string) => boolean;
	},
	partition: string,
	proxy: SessionProxy | null,
): void {
	if (!symbols.supportsProxy()) {
		throw new Error(
			`Session proxies are not supported on ${process.platform}; on macOS they need macOS 14 or later`,
		);
	}
	if (proxy !== null) {
		validateSessionProxy(proxy);
	}
	if (!symbols.setProxy(partition, JSON.stringify(proxy))) {
		throw new Error(`Failed to set the proxy for session "${partition}"`);
	}
}

function validateSessionProxy(proxy: SessionProxy): void {
	if (proxy.type !== "http" && proxy.type !== "socks5") {
		throw new TypeError(`Unknown proxy type: ${String(proxy.type)}`);
	}
	if (typeof proxy.host !== "string" || proxy.host.length === 0) {
		throw new TypeError("Proxy host must be a non-empty string");
	}
	if (!Number.isInteger(proxy.port) || proxy.port < 1 || proxy.port > 65535) {
		throw new TypeError(`Proxy port must be an integer from 1 to 65535: ${proxy.port}`);
	}
	for (const key of ["matchDomains", "excludedDomains"] as const) {
		const domains = proxy[key];
		if (
			domains !== undefined &&
			(!Array.isArray(domains) ||
				domains.some((domain) => typeof domain !== "string" || domain.length === 0))
		) {
			throw new TypeError(`Proxy ${key} must be an array of non-empty strings`);
		}
	}
}
