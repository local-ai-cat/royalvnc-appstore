#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	struct ClientCutText: VNCSendableMessage {
		let messageType: UInt8 = 6

		private let payload: Data
		private let isExtended: Bool

		init(classicText text: String) throws {
			guard let latin1TextData = text.data(using: .isoLatin1) else {
				throw EncodingError.notRepresentableInLatin1
			}

			guard latin1TextData.count <= UInt32.max else {
				throw EncodingError.payloadTooLarge
			}

			self.payload = latin1TextData
			self.isExtended = false
		}

		private init(extendedPayload payload: Data) throws {
			guard payload.count <= Int32.max else {
				throw EncodingError.payloadTooLarge
			}

			self.payload = payload
			self.isExtended = true
		}
	}
}

extension VNCProtocol.ClientCutText {
	enum EncodingError: Error {
		case notRepresentableInLatin1
		case payloadTooLarge
	}

	var data: Data {
		let length = 8 + payload.count
		var data = Data(capacity: length)

		data.append(messageType)
		data.appendPadding(length: 3)

		if isExtended {
			data.append(-Int32(payload.count), bigEndian: true)
		} else {
			data.append(UInt32(payload.count), bigEndian: true)
		}

		data.append(payload)
		return data
	}

	func send(connection: NetworkConnectionWriting) async throws {
		try await connection.write(data: data)
	}
}

extension VNCProtocol.ClientCutText {
	static func extendedClipboardCapabilities() throws -> Self {
		let actions: VNCExtendedClipboardAction = [
			.caps,
			.request,
			.peek,
			.notify,
			.provide
		]

		var payload = extendedClipboardFlags(actions: actions, formats: .text)
		payload.append(UInt32(0), bigEndian: true)
		return try .init(extendedPayload: payload)
	}

	static func extendedClipboardNotify(formats: VNCExtendedClipboardFormat) throws -> Self {
		try .init(extendedPayload: extendedClipboardFlags(actions: .notify, formats: formats))
	}

	static func extendedClipboardRequest(formats: VNCExtendedClipboardFormat) throws -> Self {
		try .init(extendedPayload: extendedClipboardFlags(actions: .request, formats: formats))
	}

	static func extendedClipboardProvide(text: String) throws -> Self {
		let textData = extendedClipboardTextData(text)

		guard textData.count <= UInt32.max else {
			throw EncodingError.payloadTooLarge
		}

		var uncompressedPayload = Data(capacity: 4 + textData.count)
		uncompressedPayload.append(UInt32(textData.count), bigEndian: true)
		uncompressedPayload.append(textData)

		let compressedPayload = try ZlibDeflate.compress(uncompressedPayload)
		var payload = extendedClipboardFlags(actions: .provide, formats: .text)
		payload.append(compressedPayload)
		return try .init(extendedPayload: payload)
	}

	static func extendedClipboardTextData(_ text: String) -> Data {
		let normalizedText = text
			.replacingOccurrences(of: "\r\n", with: "\n")
			.replacingOccurrences(of: "\r", with: "\n")
			.replacingOccurrences(of: "\n", with: "\r\n")

		var textData = Data(normalizedText.utf8)
		textData.append(0)
		return textData
	}

	private static func extendedClipboardFlags(
		actions: VNCExtendedClipboardAction,
		formats: VNCExtendedClipboardFormat
	) -> Data {
		var data = Data(capacity: 4)
		data.append(actions.rawValue | formats.rawValue, bigEndian: true)
		return data
	}
}
