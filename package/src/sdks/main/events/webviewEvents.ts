import ElectrobunEvent from "./event";

type DetailData = { detail: string };
type NewWindowOpenData = {
	detail:
		| string
		| {
				url: string;
				isCmdClick: boolean;
				modifierFlags?: number;
				targetDisposition?: number;
				userGesture?: boolean;
		  };
};

type NativeRequestFrame = {
	requestId: number;
	origin: string;
	frameUrl: string;
	isMainFrame: boolean;
};
type NativeRequestData<T> = { detail: T };
type ProtectionSpace = {
	requestId: number;
	origin: string;
	host: string;
	port: number;
	protocol: string;
	isProxy: boolean;
};

export type DialogRequest = NativeRequestFrame & {
	type: "alert" | "confirm" | "prompt";
	message: string;
	defaultText?: string;
};
export type AuthRequest = ProtectionSpace & {
	realm: string;
	authenticationMethod: string;
	previousFailureCount: number;
};
export type CertificateRequest = ProtectionSpace & { error: string };
export type DownloadRequest = NativeRequestFrame & {
	downloadId: number;
	url: string;
	suggestedFilename: string;
	mimeType: string;
	expectedBytes: number;
};
export type PopupRequest = NativeRequestFrame & {
	url: string;
	method: string;
	windowFeatures: {
		x: number | null;
		y: number | null;
		width: number | null;
		height: number | null;
	};
};
export type ExternalAppRequest = NativeRequestFrame & {
	url: string;
	scheme: string;
	isUserGesture: boolean;
};
export type NativeRequestExpired = {
	requestId: number;
	reason: "timeout" | "closed";
};

const nativeRequestEvent =
	<T>(name: string) =>
	(data: NativeRequestData<T>) =>
		new ElectrobunEvent<NativeRequestData<T>, {}>(name, data);

export default {
	willNavigate: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("will-navigate", data),
	didNavigate: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("did-navigate", data),
	didNavigateInPage: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("did-navigate-in-page", data),
	didCommitNavigation: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("did-commit-navigation", data),
	domReady: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("dom-ready", data),
	newWindowOpen: (data: NewWindowOpenData) =>
		new ElectrobunEvent<NewWindowOpenData, {}>("new-window-open", data),
	hostMessage: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("host-message", data),
	downloadStarted: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("download-started", data),
	downloadProgress: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("download-progress", data),
	downloadCompleted: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("download-completed", data),
	downloadFailed: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("download-failed", data),
	dialogRequest: nativeRequestEvent<DialogRequest>("dialog-request"),
	authRequest: nativeRequestEvent<AuthRequest>("auth-request"),
	certificateRequest: nativeRequestEvent<CertificateRequest>(
		"certificate-request",
	),
	downloadRequest: nativeRequestEvent<DownloadRequest>("download-request"),
	popupRequest: nativeRequestEvent<PopupRequest>("popup-request"),
	externalAppRequest: nativeRequestEvent<ExternalAppRequest>(
		"external-app-request",
	),
	nativeRequestExpired: nativeRequestEvent<NativeRequestExpired>(
		"native-request-expired",
	),
	closeRequested: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("close-requested", data),
};
