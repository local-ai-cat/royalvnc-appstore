import XCTest
@testable import RoyalVNCKit

final class ExtendedClipboardTests: XCTestCase {
	func testCapabilitiesNegotiationRecordsServerCapsAndQueuesClientResponse() async throws {
		var serverMessageData = Data([0, 0, 0])
		serverMessageData.append(Int32(-8), bigEndian: true)
		serverMessageData.append(UInt32(0x1F00_0001), bigEndian: true)
		serverMessageData.append(UInt32(0), bigEndian: true)

		let reader = DataNetworkConnectionReader(data: serverMessageData)
		let message = try await VNCProtocol.ServerCutText.receive(
			connection: reader,
			logger: VNCPrintLogger()
		)
		let extended = try XCTUnwrap(message.extended)
		let capabilities = try XCTUnwrap(extended.serverCapabilities)

		XCTAssertTrue(capabilities.formats.contains(.text))
		XCTAssertTrue(capabilities.actions.contains(.provide))
		XCTAssertTrue(capabilities.actions.contains(.notify))
		XCTAssertTrue(capabilities.actions.contains(.request))
		XCTAssertEqual(capabilities.maximumSize(for: .text), 0)
		XCTAssertEqual(reader.remainingByteCount, 0)

		let connection = makeConnection()
		try connection.handleExtendedServerCutText(extended)

		XCTAssertTrue(connection.state.extendedClipboardServerCapabilities?.formats.contains(.text) == true)
		let response = try XCTUnwrap(connection.clientToServerMessageQueue.dequeue())
		XCTAssertEqual(
			response.data,
			Data([
				0x06, 0x00, 0x00, 0x00,
				0xFF, 0xFF, 0xFF, 0xF8,
				0x1F, 0x00, 0x00, 0x01,
				0x00, 0x00, 0x00, 0x00
			])
		)
	}

	func testExtendedClipboardPseudoEncodingIsAdvertised() throws {
		let connection = makeConnection()

		XCTAssertTrue(try connection.orderedEncodingTypes().contains(VNCPseudoEncodingType.extendedClipboard.rawValue))
	}

	func testProvideMessageMatchesGoldenUTF8WireBytes() throws {
		let message = try VNCProtocol.ClientCutText.extendedClipboardProvide(text: "hé🙂\n")

		XCTAssertEqual(
			message.data,
			Data([
				0x06, 0x00, 0x00, 0x00,
				0xFF, 0xFF, 0xFF, 0xE6,
				0x10, 0x00, 0x00, 0x01,
				0x78, 0x9C, 0x63, 0x60, 0x60, 0xE0, 0xCA, 0x38,
				0xBC, 0xF2, 0xC3, 0xFC, 0x99, 0x4D, 0xBC, 0x5C,
				0x0C, 0x00, 0x20, 0x39, 0x04, 0xA0
			])
		)
	}

	func testClassicClipboardAcceptsLosslessLatin1() throws {
		let message = try VNCProtocol.ClientCutText(classicText: "café £")

		XCTAssertEqual(
			message.data,
			Data([
				0x06, 0x00, 0x00, 0x00,
				0x00, 0x00, 0x00, 0x06,
				0x63, 0x61, 0x66, 0xE9, 0x20, 0xA3
			])
		)
	}

	func testClassicClipboardRejectsNonLatin1WithoutQueueingEmptyText() async {
		XCTAssertThrowsError(try VNCProtocol.ClientCutText(classicText: "hello 🌍"))

		let connection = makeConnection()
		let result = await connection.sendClipboardText("hello 🌍")

		XCTAssertEqual(result, .unsupported)
		XCTAssertTrue(connection.clientToServerMessageQueue.isEmpty)
	}
}

private extension ExtendedClipboardTests {
	func makeConnection() -> VNCConnection {
		let settings = VNCConnection.Settings(
			isDebugLoggingEnabled: false,
			hostname: "localhost",
			port: 5900,
			isShared: true,
			isScalingEnabled: true,
			useDisplayLink: false,
			inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
			isClipboardRedirectionEnabled: true,
			isClipboardAutoSyncEnabled: false,
			colorDepth: .depth24Bit,
			frameEncodings: .default
		)

		return VNCConnection(
			settings: settings,
			logger: VNCPrintLogger(),
			framebufferAllocator: nil,
			context: nil,
			clipboard: TestClipboard()
		)
	}
}

private final class DataNetworkConnectionReader: NetworkConnectionReading {
	private let data: Data
	private var offset = 0

	init(data: Data) {
		self.data = data
	}

	var remainingByteCount: Int {
		data.count - offset
	}

	func read(minimumLength: Int, maximumLength: Int) async throws -> Data {
		guard remainingByteCount >= minimumLength else {
			throw VNCError.protocol(.noData)
		}

		let length = min(maximumLength, remainingByteCount)
		let result = data.subdata(in: offset..<(offset + length))
		offset += length
		return result
	}
}

private final class TestClipboard: VNCClipboardAccessing {
	var text: String?
	var changeCount = 0
}
