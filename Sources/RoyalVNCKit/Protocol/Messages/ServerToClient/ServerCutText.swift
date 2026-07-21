#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	struct ServerCutText: VNCReceivableMessage {
		static let messageType: UInt8 = 3
		static let stringEncoding: String.Encoding = .isoLatin1

		let messageType: UInt8
		let text: String
		let extended: VNCExtendedServerCutText?
	}
}

extension VNCProtocol.ServerCutText {
	static func receive(
		connection: NetworkConnectionReading,
		logger: VNCLogger
	) async throws -> Self {
		try await connection.readPadding(length: 3)
		let length = try await receiveLength(connection: connection)

		if length >= 0 {
			let text = try await connection.readString(
				encoding: Self.stringEncoding,
				length: length
			)

			return .init(messageType: Self.messageType, text: text, extended: nil)
		}

		let extended = try await VNCExtendedServerCutText.receive(
			connection: connection,
			logger: logger,
			length: -length
		)

		return .init(messageType: Self.messageType, text: "", extended: extended)
	}
}

private extension VNCProtocol.ServerCutText {
	static func receiveLength(connection: NetworkConnectionReading) async throws -> Int {
		let lengthDataLength = MemoryLayout<Int32>.size
		let lengthData = try await connection.read(length: lengthDataLength)

		guard lengthData.count == lengthDataLength else {
			throw VNCError.protocol(.invalidData)
		}

		let bigEndianLength = lengthData.withUnsafeBytes {
			$0.loadUnaligned(as: Int32.self)
		}
		let length = Endianness.current == .little
			? Int(Int32(bigEndian: bigEndianLength))
			: Int(bigEndianLength)

		guard length != Int(Int32.min) else {
			throw VNCError.protocol(.invalidData)
		}

		return length
	}
}

struct VNCExtendedServerCutText {
	let formats: VNCExtendedClipboardFormat
	let action: VNCExtendedClipboardAction
	let serverCapabilities: VNCExtendedClipboardCapabilities?
	let text: String?
}

extension VNCExtendedServerCutText {
	static func receive(
		connection: NetworkConnectionReading,
		logger: VNCLogger,
		length: Int
	) async throws -> Self {
		guard length >= 4 else {
			throw VNCError.protocol(.invalidData)
		}

		let flagsRawValue = try await connection.readUInt32()
		let formats = VNCExtendedClipboardFormat(rawValue: flagsRawValue & VNCExtendedClipboard.formatMask)
		let actions = VNCExtendedClipboardAction(rawValue: flagsRawValue & VNCExtendedClipboard.actionMask)

		if actions.contains(.caps) {
			logger.logDebug("ExtendedServerCutText Caps")
			let capabilities = try await receiveCapabilities(
				connection: connection,
				formats: formats,
				actions: actions,
				remainingLength: length - 4
			)

			return .init(
				formats: formats,
				action: .caps,
				serverCapabilities: capabilities,
				text: nil
			)
		}

		guard actions == .request || actions == .peek || actions == .notify || actions == .provide else {
			throw VNCError.protocol(.unexpectedExtendedServerCutTextAction(action: actions.rawValue))
		}

		if actions == .provide {
			logger.logDebug("ExtendedServerCutText Provide")
			let text = try await receiveProvidedText(
				connection: connection,
				formats: formats,
				compressedLength: length - 4
			)

			return .init(
				formats: formats,
				action: actions,
				serverCapabilities: nil,
				text: text
			)
		}

		guard length == 4 else {
			throw VNCError.protocol(.invalidData)
		}

		logger.logDebug("ExtendedServerCutText action: \(actions.rawValue)")
		return .init(
			formats: formats,
			action: actions,
			serverCapabilities: nil,
			text: nil
		)
	}
}

private extension VNCExtendedServerCutText {
	static func receiveCapabilities(
		connection: NetworkConnectionReading,
		formats: VNCExtendedClipboardFormat,
		actions: VNCExtendedClipboardAction,
		remainingLength: Int
	) async throws -> VNCExtendedClipboardCapabilities {
		let supportedFormatValues = (0..<16)
			.map { UInt32(1) << UInt32($0) }
			.filter { formats.contains(VNCExtendedClipboardFormat(rawValue: $0)) }

		guard remainingLength == supportedFormatValues.count * MemoryLayout<UInt32>.size else {
			throw VNCError.protocol(.invalidData)
		}

		var maximumSizes = [UInt32: UInt32]()
		for formatValue in supportedFormatValues {
			maximumSizes[formatValue] = try await connection.readUInt32()
		}

		return .init(formats: formats, actions: actions, maximumSizes: maximumSizes)
	}

	static func receiveProvidedText(
		connection: NetworkConnectionReading,
		formats: VNCExtendedClipboardFormat,
		compressedLength: Int
	) async throws -> String? {
		guard compressedLength > 0 else {
			throw VNCError.protocol(.invalidData)
		}

		let compressedData = try await connection.read(length: compressedLength)
		let uncompressedData = try ZlibStream().decompressedData(compressedData: compressedData)
		var offset = 0
		var text: String?

		for index in 0..<16 {
			let format = VNCExtendedClipboardFormat(rawValue: UInt32(1) << UInt32(index))
			guard formats.contains(format) else { continue }

			guard offset + 4 <= uncompressedData.count else {
				throw VNCError.protocol(.invalidData)
			}

			let lengthData = uncompressedData.subdata(in: offset..<(offset + 4))
			let bigEndianLength = lengthData.withUnsafeBytes {
				$0.loadUnaligned(as: UInt32.self)
			}
			let formatLength = Endianness.current == .little
				? UInt32(bigEndian: bigEndianLength)
				: bigEndianLength
			offset += 4

			guard Int(formatLength) <= uncompressedData.count - offset else {
				throw VNCError.protocol(.invalidData)
			}

			let formatData = uncompressedData.subdata(in: offset..<(offset + Int(formatLength)))
			offset += Int(formatLength)

			if format == .text {
				var textData = formatData
				if textData.last == 0 {
					textData.removeLast()
				}

				guard let decodedText = String(data: textData, encoding: .utf8) else {
					throw VNCError.protocol(.invalidData)
				}

				text = decodedText.replacingOccurrences(of: "\r\n", with: "\n")
			}
		}

		guard offset == uncompressedData.count else {
			throw VNCError.protocol(.invalidData)
		}

		return text
	}
}
