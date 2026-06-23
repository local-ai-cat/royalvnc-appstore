#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch

extension VNCConnection {
    final class State {
		var disconnectRequested = false

		/// Set once the connection has reached `.ready` and run the VNC handshake.
		/// Used to (a) run the handshake exactly once, and (b) decide how to treat a
		/// later NWConnection `.waiting`: tolerated (with a grace timer) *before* the
		/// session is established, but a prompt failure *after* — so an established
		/// session that loses its path disconnects fast instead of stalling.
		var didBecomeReady = false

		/// Pending "still waiting for a viable path" grace timer. Scheduled when a
		/// pre-`.ready` connection enters `.waiting`; if it fires while the connection
		/// is *still* `.waiting`, the connection is failed so a genuinely unreachable
		/// host doesn't hang forever. Cancelled when the connection leaves `.waiting`
		/// (`.preparing`/`.ready`/`.failed`/`.cancelled`/disconnect), and the timer
		/// closure re-checks the live status so a forward transition never false-fails.
		var waitingGraceWorkItem: DispatchWorkItem?

		var serverProtocolVersion: VNCProtocol.ProtocolVersion?
		var agreedProtocolVersion: VNCProtocol.ProtocolVersion?

		var isTightSecurityEnabled = false

		var framebufferWidth: UInt16 = 0
		var framebufferHeight: UInt16 = 0

		var serverPixelFormat: VNCProtocol.PixelFormat?
		var pixelFormat: VNCProtocol.PixelFormat?

		var desktopName: String?

		var incrementalUpdatesEnabled = false

		var areContinuousUpdatesSupported = false
		var areContinuousUpdatesEnabled = false
	}
}

extension VNCConnection.State {
	var isAppleRemoteDesktop: Bool {
		return serverProtocolVersion?.isAppleRemoteDesktop ?? false
	}
}
