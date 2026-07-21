#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct VNCExtendedClipboardFormat: OptionSet {
	let rawValue: UInt32

	static let text = Self(rawValue: 1)
	static let rtf = Self(rawValue: 1 << 1)
	static let html = Self(rawValue: 1 << 2)
	static let dib = Self(rawValue: 1 << 3)
	static let files = Self(rawValue: 1 << 4)
}

struct VNCExtendedClipboardAction: OptionSet {
	let rawValue: UInt32

	static let caps = Self(rawValue: 1 << 24)
	static let request = Self(rawValue: 1 << 25)
	static let peek = Self(rawValue: 1 << 26)
	static let notify = Self(rawValue: 1 << 27)
	static let provide = Self(rawValue: 1 << 28)
}

struct VNCExtendedClipboardCapabilities {
	let formats: VNCExtendedClipboardFormat
	let actions: VNCExtendedClipboardAction
	let maximumSizes: [UInt32: UInt32]

	func maximumSize(for format: VNCExtendedClipboardFormat) -> UInt32? {
		maximumSizes[format.rawValue]
	}
}

enum VNCExtendedClipboard {
	static let formatMask: UInt32 = 0x0000_FFFF
	static let actionMask: UInt32 = 0xFF00_0000
}
