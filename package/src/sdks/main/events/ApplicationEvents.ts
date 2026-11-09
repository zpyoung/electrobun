import ElectrobunEvent from "./event";

type MenuClickedData = { id?: number; action: string; data?: unknown };
type OpenUrlData = { url: string };
type NotificationResponseData = { id: string };

export default {
	applicationMenuClicked: (data: MenuClickedData) =>
		new ElectrobunEvent<MenuClickedData, { allow: boolean }>(
			"application-menu-clicked",
			data,
		),
	contextMenuClicked: (data: MenuClickedData) =>
		new ElectrobunEvent<MenuClickedData, { allow: boolean }>(
			"context-menu-clicked",
			data,
		),
	openUrl: (data: OpenUrlData) =>
		new ElectrobunEvent<OpenUrlData, void>("open-url", data),
	reopen: (data: {}) => new ElectrobunEvent<{}, void>("reopen", data),
	notificationClick: (data: NotificationResponseData) =>
		new ElectrobunEvent<NotificationResponseData, void>(
			"notification-click",
			data,
		),
	notificationDismiss: (data: NotificationResponseData) =>
		new ElectrobunEvent<NotificationResponseData, void>(
			"notification-dismiss",
			data,
		),
	beforeQuit: (data: {}) =>
		new ElectrobunEvent<{}, { allow: boolean }>("before-quit", data),
};
