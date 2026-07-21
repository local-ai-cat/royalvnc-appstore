import XCTest
@testable import RoyalVNCKit

final class ClipboardSettingsTests: XCTestCase {
	func testLegacySettingsInitializerKeepsClipboardAutoSyncEnabled() {
		let settings = makeSettings()

		XCTAssertTrue(settings.isClipboardAutoSyncEnabled)
	}

	func testAutoSyncDisabledDoesNotStartOrReadClipboard() {
		let clipboard = SpyClipboard()
		let connection = makeConnection(autoSyncEnabled: false, clipboard: clipboard)

		connection.startMonitoringClipboard()

		XCTAssertFalse(connection.clipboardMonitor.isMonitoring)
		XCTAssertEqual(clipboard.changeCountReads, 0)
		XCTAssertEqual(clipboard.textReads, 0)
	}

	func testAutoSyncDisabledIgnoresMonitorDelegateCallback() {
		let connection = makeConnection(autoSyncEnabled: false)

		connection.clipboardMonitor(connection.clipboardMonitor, didChangeText: "ignored")

		XCTAssertTrue(connection.clientToServerMessageQueue.isEmpty)
	}

	func testAutoSyncEnabledQueuesOneClipboardMessage() {
		let connection = makeConnection(autoSyncEnabled: true)

		connection.clipboardMonitor(connection.clipboardMonitor, didChangeText: "hello")

		XCTAssertEqual(connection.clientToServerMessageQueue.count, 1)
		XCTAssertNotNil(connection.clientToServerMessageQueue.dequeue())
		XCTAssertNil(connection.clientToServerMessageQueue.dequeue())
	}

	func testServerClipboardWriteStillWorksWithAutoSyncDisabled() {
		let clipboard = SpyClipboard()
		let connection = makeConnection(autoSyncEnabled: false, clipboard: clipboard)

		connection.updateClipboardFromServer("from server")

		XCTAssertEqual(clipboard.writtenTexts, ["from server"])
		XCTAssertEqual(clipboard.textReads, 0)
	}

	func testClipboardRedirectionDisabledSuppressesServerWrite() {
		let clipboard = SpyClipboard()
		let connection = makeConnection(
			autoSyncEnabled: false,
			redirectionEnabled: false,
			clipboard: clipboard
		)

		connection.updateClipboardFromServer("ignored")

		XCTAssertTrue(clipboard.writtenTexts.isEmpty)
	}
}

private extension ClipboardSettingsTests {
	func makeConnection(
		autoSyncEnabled: Bool,
		redirectionEnabled: Bool = true,
		clipboard: SpyClipboard = SpyClipboard()
	) -> VNCConnection {
		VNCConnection(
			settings: makeSettings(
				autoSyncEnabled: autoSyncEnabled,
				redirectionEnabled: redirectionEnabled
			),
			logger: VNCPrintLogger(),
			framebufferAllocator: nil,
			context: nil,
			clipboard: clipboard
		)
	}

	func makeSettings(
		autoSyncEnabled: Bool? = nil,
		redirectionEnabled: Bool = true
	) -> VNCConnection.Settings {
		if let autoSyncEnabled {
			return VNCConnection.Settings(
				isDebugLoggingEnabled: false,
				hostname: "localhost",
				port: 5900,
				isShared: true,
				isScalingEnabled: true,
				useDisplayLink: false,
				inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
				isClipboardRedirectionEnabled: redirectionEnabled,
				isClipboardAutoSyncEnabled: autoSyncEnabled,
				colorDepth: .depth24Bit,
				frameEncodings: .default
			)
		}

		return VNCConnection.Settings(
			isDebugLoggingEnabled: false,
			hostname: "localhost",
			port: 5900,
			isShared: true,
			isScalingEnabled: true,
			useDisplayLink: false,
			inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
			isClipboardRedirectionEnabled: redirectionEnabled,
			colorDepth: .depth24Bit,
			frameEncodings: .default
		)
	}
}

private final class SpyClipboard: VNCClipboardAccessing {
	private var storedText: String?

	private(set) var textReads = 0
	private(set) var changeCountReads = 0
	private(set) var writtenTexts = [String?]()

	var text: String? {
		get {
			textReads += 1
			return storedText
		}
		set {
			storedText = newValue
			writtenTexts.append(newValue)
		}
	}

	var changeCount: Int {
		changeCountReads += 1
		return writtenTexts.count
	}
}
