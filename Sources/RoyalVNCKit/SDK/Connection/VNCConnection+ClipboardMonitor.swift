#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCConnection {
	func startMonitoringClipboard() {
		guard settings.isClipboardRedirectionEnabled,
			  settings.isClipboardAutoSyncEnabled else { return }

		clipboardMonitor.startMonitoring()
	}

	func stopMonitoringClipboard() {
		clipboardMonitor.stopMonitoring()
	}
}

// MARK: - VNCClipboardMonitorDelegate
extension VNCConnection: VNCClipboardMonitorDelegate {
	func clipboardMonitorShouldMonitor(_ clipboardMonitor: VNCClipboardMonitor) -> Bool {
		let isConnected = connectionState.status == .connected

		return isConnected
			&& settings.isClipboardRedirectionEnabled
			&& settings.isClipboardAutoSyncEnabled
	}

	func clipboardMonitor(_ clipboardMonitor: VNCClipboardMonitor,
						  didChangeText text: String) {
		logger.logDebug("Clipboard Monitor did change text")

		guard settings.isClipboardRedirectionEnabled,
			  settings.isClipboardAutoSyncEnabled else { return }

		enqueueClientCutTextMessage(text)
	}
}
