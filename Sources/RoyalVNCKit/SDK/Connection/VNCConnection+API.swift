#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Connect/Disconnect
public extension VNCConnection {
#if canImport(ObjectiveC)
	@objc
#endif
	func connect() {
		beginConnecting()
	}

#if canImport(ObjectiveC)
    @objc
#endif
	func disconnect() {
		beginDisconnecting()
	}
}

public enum VNCClipboardTextSendResult: Equatable, Sendable {
	case extendedUTF8
	case classicLatin1
	case unsupported
}

// MARK: - Clipboard Input
public extension VNCConnection {
	func sendClipboardText(_ text: String) async -> VNCClipboardTextSendResult {
		guard settings.isClipboardRedirectionEnabled else {
			return .unsupported
		}

		if let capabilities = state.extendedClipboardServerCapabilities,
		   capabilities.formats.contains(.text),
		   capabilities.actions.contains(.provide) {
			let result = await sendExtendedClipboardText(text, capabilities: capabilities)
			if result == .extendedUTF8 {
				return result
			}
		}

		return sendClassicClipboardText(text)
	}
}

extension VNCConnection {
	func sendClassicClipboardText(_ text: String) -> VNCClipboardTextSendResult {
		do {
			let message = try VNCProtocol.ClientCutText(classicText: text)
			enqueueClientToServerMessage(message)
			return .classicLatin1
		} catch {
			logger.logWarning("Clipboard text cannot be sent losslessly with classic Latin-1: \(error)")
			return .unsupported
		}
	}
}

private extension VNCConnection {
	static var extendedClipboardRequestTimeoutNanoseconds: UInt64 { 1_000_000_000 }
	static var extendedClipboardPollNanoseconds: UInt64 { 10_000_000 }

	func sendExtendedClipboardText(
		_ text: String,
		capabilities: VNCExtendedClipboardCapabilities
	) async -> VNCClipboardTextSendResult {
		var ownedSendID: UInt64?

		do {
			let textDataLength = VNCProtocol.ClientCutText.extendedClipboardTextData(text).count
			let maximumSize = capabilities.maximumSize(for: .text) ?? 0

			if maximumSize > 0, textDataLength <= maximumSize {
				let message = try VNCProtocol.ClientCutText.extendedClipboardProvide(text: text)
				enqueueClientToServerMessage(message)
				return .extendedUTF8
			}

			guard capabilities.actions.contains(.notify) else {
				return .unsupported
			}

			state.nextClipboardSendID &+= 1
			let sendID = state.nextClipboardSendID
			ownedSendID = sendID
			state.pendingClipboardText = text
			state.pendingClipboardSendID = sendID
			state.completedClipboardSendID = nil
			enqueueClientToServerMessage(try VNCProtocol.ClientCutText.extendedClipboardNotify(formats: .text))

			let pollCount = Self.extendedClipboardRequestTimeoutNanoseconds
				/ Self.extendedClipboardPollNanoseconds
			for _ in 0..<pollCount {
				try await Task.sleep(nanoseconds: Self.extendedClipboardPollNanoseconds)
				if state.completedClipboardSendID == sendID {
					return .extendedUTF8
				}
				if state.pendingClipboardSendID != sendID {
					return .unsupported
				}
			}

			clearPendingClipboardSend(sendID: sendID)
			logger.logWarning("Extended clipboard server did not request notified UTF-8 text")
			return .unsupported
		} catch {
			if let sendID = ownedSendID {
				clearPendingClipboardSend(sendID: sendID)
			}
			logger.logError("Failed to encode extended UTF-8 clipboard text: \(error)")
			return .unsupported
		}
	}

	func clearPendingClipboardSend(sendID: UInt64) {
		guard state.pendingClipboardSendID == sendID else { return }
		state.pendingClipboardText = nil
		state.pendingClipboardSendID = nil
	}
}

public extension VNCConnection {
#if canImport(ObjectiveC)
    @objc
#endif
	func updateColorDepth(_ colorDepth: Settings.ColorDepth) {
		guard let framebuffer = framebuffer else { return }

		let newPixelFormat = VNCProtocol.PixelFormat(depth: colorDepth.rawValue)

		state.pixelFormat = newPixelFormat

		let sendPixelFormatMessage = VNCProtocol.SetPixelFormat(pixelFormat: newPixelFormat)

		clientToServerMessageQueue.enqueue(sendPixelFormatMessage)

		recreateFramebuffer(size: framebuffer.size,
							screens: framebuffer.screens,
							pixelFormat: newPixelFormat)
	}
}

// MARK: - Mouse Input
public extension VNCConnection {
#if canImport(ObjectiveC)
	@objc
#endif
	func mouseMove(x horizontalPosition: UInt16, y verticalPosition: UInt16) {
		enqueueMouseEvent(nonNormalizedX: horizontalPosition,
						  nonNormalizedY: verticalPosition)
	}

#if canImport(ObjectiveC)
	@objc
#endif
	func mouseButtonDown(_ button: VNCMouseButton,
						 x horizontalPosition: UInt16, y verticalPosition: UInt16) {
		updateMouseButtonState(button: button,
						   isDown: true)

		enqueueMouseEvent(nonNormalizedX: horizontalPosition,
						  nonNormalizedY: verticalPosition)
	}

#if canImport(ObjectiveC)
	@objc
#endif
	func mouseButtonUp(_ button: VNCMouseButton,
					   x horizontalPosition: UInt16, y verticalPosition: UInt16) {
		updateMouseButtonState(button: button,
						   isDown: false)

		enqueueMouseEvent(nonNormalizedX: horizontalPosition,
						  nonNormalizedY: verticalPosition)
	}

#if canImport(ObjectiveC)
	@objc
#endif
	func mouseWheel(_ wheel: VNCMouseWheel,
					x horizontalPosition: UInt16, y verticalPosition: UInt16,
					steps: UInt32) {
		for _ in 0..<steps {
			updateMouseButtonState(wheel: wheel,
								   isDown: true)

			enqueueMouseEvent(nonNormalizedX: horizontalPosition,
							  nonNormalizedY: verticalPosition)

			updateMouseButtonState(wheel: wheel,
								   isDown: false)
		}
	}
}

extension VNCConnection {
    func updateMouseButtonState(button: VNCMouseButton,
                                isDown: Bool) {
        updateMouseButtonState(mousePointerButton: button.mousePointerButton,
                               isDown: isDown)
    }

    func updateMouseButtonState(wheel: VNCMouseWheel,
                                isDown: Bool) {
        updateMouseButtonState(mousePointerButton: wheel.mousePointerButton,
                               isDown: isDown)
    }

    func updateMouseButtonState(mousePointerButton: VNCProtocol.MousePointerButton,
                                isDown: Bool) {
        if isDown {
            mouseButtonState.insert(mousePointerButton)
        } else {
            mouseButtonState.remove(mousePointerButton)
        }
    }
}

// MARK: - Keyboard Input
public extension VNCConnection {
	func keyDown(_ key: VNCKeyCode) {
		enqueueKeyEvent(key: key,
						isDown: true)
	}

#if canImport(ObjectiveC)
	@objc(keyDown:)
#endif
	func _objc_keyDown(_ key: UInt32) {
		keyDown(.init(key))
	}

	func keyUp(_ key: VNCKeyCode) {
		enqueueKeyEvent(key: key,
						isDown: false)
	}

#if canImport(ObjectiveC)
	@objc(keyUp:)
#endif
	func _objc_keyUp(_ key: UInt32) {
		keyUp(.init(key))
	}
}
