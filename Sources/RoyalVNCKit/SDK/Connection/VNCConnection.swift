#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch

#if canImport(Network)
import Network
#endif

#if canImport(ObjectiveC)
@objc(VNCConnection)
#endif
public final class VNCConnection: NSObjectOrAnyObject {
	// MARK: - Public Properties
#if canImport(ObjectiveC)
	@objc
#endif
	public let settings: Settings

    public let context: UnsafeMutableRawPointer?

#if canImport(ObjectiveC)
	@objc
#endif
	public weak var delegate: VNCConnectionDelegate?

#if canImport(ObjectiveC)
	@objc
#endif
	public var framebuffer: VNCFramebuffer?

#if canImport(ObjectiveC)
	@objc
#endif
	public internal(set) var connectionState = ConnectionState.disconnected

#if canImport(ObjectiveC)
	@objc
#endif
	public let logger: VNCLogger
    
    public let framebufferAllocator: VNCFramebufferAllocator?

	// MARK: - Private Properties
	private let queue = DispatchQueue(label: "com.royalapps.royalvnc.connectionqueue",
									  attributes: .concurrent)

	private let sharedZStream: ZlibStream
    private let sharedZRLEZStream: ZlibStream

	// MARK: - Internal Properties
    let taskPriority = TaskPriority.high

	var receiveTask: Task<(), Error>?
	var sendTask: Task<(), Error>?

	let maxSupportedProtocolVersion = VNCProtocol.ProtocolVersion(majorVersion: 3,
																  minorVersion: 8)

	let state = State()
	let systemSound = VNCSystemSound()

	let clipboard: any VNCClipboardAccessing
	let clipboardMonitor: VNCClipboardMonitor

	var clientToServerMessageQueue = Queue<VNCSendableMessage>()

    var mouseButtonState: VNCProtocol.MousePointerButton = [ ]

    lazy var connection: some NetworkConnection = {
        let connectionSettings = NetworkConnectionSettings(connectionTimeout: 15,
                                                           host: settings.hostname,
                                                           port: settings.port)

        // NOTE: To test SocketNetworkConnection on Darwin (macOS, iOS, etc.), comment out the the #if
#if canImport(Network)
        let connection = NWConnection(settings: connectionSettings)
#else
		let connection = SocketNetworkConnection(settings: connectionSettings)
#endif

        connection.setStatusUpdateHandler(connectionStatusDidChange)

		return connection
	}()

	lazy var encodings: Encodings = {
		let rawEncoding = VNCProtocol.RawEncoding()
		let hextileEncoding = VNCProtocol.HextileEncoding(rawEncoding: rawEncoding)

		let compressionLevelEncodingType = VNCPseudoEncodingType.compressionLevel6.rawValue
		let compressionLevelEncoding = VNCProtocol.CompressionLevelEncoding(encodingType: compressionLevelEncodingType)

		let jpegQualityLevelEncodingType = VNCPseudoEncodingType.jpegQualityLevel6.rawValue
		let jpegQualityLevelEncoding = VNCProtocol.JPEGQualityLevelEncoding(encodingType: jpegQualityLevelEncodingType)

		let encs: Encodings = [
			// Frame Encodings
			VNCFrameEncodingType.copyRect.rawValue: VNCProtocol.CopyRectEncoding(),
            VNCFrameEncodingType.tight.rawValue: VNCProtocol.TightEncoding(),
            VNCFrameEncodingType.zlib.rawValue: VNCProtocol.ZlibEncoding(zStream: sharedZStream),
			VNCFrameEncodingType.zrle.rawValue: VNCProtocol.ZRLEEncoding(zStream: sharedZRLEZStream),
			VNCFrameEncodingType.hextile.rawValue: hextileEncoding,
			VNCFrameEncodingType.coRRE.rawValue: VNCProtocol.RREEncoding(),
			VNCFrameEncodingType.rre.rawValue: VNCProtocol.RREEncoding(),
			VNCFrameEncodingType.raw.rawValue: rawEncoding,

			// Pseudo Encodings
			VNCPseudoEncodingType.lastRect.rawValue: VNCProtocol.LastRectEncoding(),
			VNCPseudoEncodingType.continuousUpdates.rawValue: VNCProtocol.ContinuousUpdatesEncoding(),
			VNCPseudoEncodingType.extendedDesktopSize.rawValue: VNCProtocol.ExtendedDesktopSizeEncoding(),
			VNCPseudoEncodingType.desktopSize.rawValue: VNCProtocol.DesktopSizeEncoding(),
			VNCPseudoEncodingType.desktopName.rawValue: VNCProtocol.DesktopNameEncoding(),
			VNCPseudoEncodingType.cursor.rawValue: VNCProtocol.CursorEncoding(),
			compressionLevelEncodingType: compressionLevelEncoding,
			jpegQualityLevelEncodingType: jpegQualityLevelEncoding
		]

		// Sanity Check
		do {
			let encodingTypes = encs.values.map({ $0.encodingType })

			try encodingTypes.validate()
		} catch {
            // If the sanity check fails here, it's a programming error
			fatalError(error.debugDescription)
		}

		return encs
	}()

	func orderedEncodingTypes() throws -> [VNCEncodingType] {
		// Frame Encodings (Required)
		var encs: [VNCEncodingType] = [
			VNCFrameEncodingType.copyRect.rawValue
		]

		// Frame Encodings (Customizable)
		var customizedFrameEncodings = settings.frameEncodings.map({ $0.rawValue })

		// TODO: Remove once we support ZRLE for non-24-bit pixel formats
		if let pixelFormat = state.pixelFormat,
		   customizedFrameEncodings.contains(VNCFrameEncodingType.zrle.rawValue),
		   !VNCProtocol.ZRLEEncoding.supportsPixelFormat(pixelFormat) {
			customizedFrameEncodings.removeAll(where: { $0 == VNCFrameEncodingType.zrle.rawValue })
		}

		if let pixelFormat = state.pixelFormat,
		   customizedFrameEncodings.contains(VNCFrameEncodingType.tight.rawValue),
		   !VNCProtocol.TightEncoding.supportsPixelFormat(pixelFormat) {
			customizedFrameEncodings.removeAll(where: { $0 == VNCFrameEncodingType.tight.rawValue })
		}

		let usesTightEncoding = customizedFrameEncodings.contains(VNCFrameEncodingType.tight.rawValue)

		encs.append(contentsOf: customizedFrameEncodings)

		// Frame Encodings (Required)
		encs.append(VNCFrameEncodingType.raw.rawValue)

		// Pseudo Encodings
		encs.append(contentsOf: [
			VNCPseudoEncodingType.lastRect.rawValue,
			VNCPseudoEncodingType.continuousUpdates.rawValue,
			VNCPseudoEncodingType.extendedDesktopSize.rawValue,
			VNCPseudoEncodingType.desktopSize.rawValue,
			VNCPseudoEncodingType.desktopName.rawValue,
			VNCPseudoEncodingType.cursor.rawValue,
			// TODO: Implement
//			VNCPseudoEncodingType.extendedClipboard.rawValue,
            
            // TODO: Make configurable
			VNCPseudoEncodingType.compressionLevel6.rawValue
		])

		if usesTightEncoding {
            // TODO: Make configurable
			encs.append(VNCPseudoEncodingType.jpegQualityLevel6.rawValue)
		}

		let uniqueEncs = encs.uniqued()

		// Sanity Check
        // If the sanity check fails here, it could be a programming error, but it could also be an error by the SDK user if he/she specified encodings with invalid values in settings. So we bubble the error up but don't crash.
		try uniqueEncs.validate()

		return uniqueEncs
	}

	// MARK: - Public Initializers
	public convenience init(settings: Settings,
							logger: VNCLogger,
							framebufferAllocator: VNCFramebufferAllocator?,
							context: UnsafeMutableRawPointer?) {
		self.init(settings: settings,
				  logger: logger,
				  framebufferAllocator: framebufferAllocator,
				  context: context,
				  clipboard: VNCClipboard())
	}

	init(settings: Settings,
		 logger: VNCLogger,
		 framebufferAllocator: VNCFramebufferAllocator?,
		 context: UnsafeMutableRawPointer?,
		 clipboard: any VNCClipboardAccessing) {
        self.settings = settings

        logger.isDebugLoggingEnabled = settings.isDebugLoggingEnabled

        self.logger = logger
        self.context = context
        
        self.sharedZStream = .init()
        self.sharedZRLEZStream = .init()

        let clipboardMonitor = VNCClipboardMonitor(clipboard: clipboard,
                                                   monitoringInterval: 0.5,
                                                   tolerance: 0.15)

        self.clipboard = clipboard
        self.clipboardMonitor = clipboardMonitor
        self.framebufferAllocator = framebufferAllocator

        super.init()

        self.clipboardMonitor.delegate = self
    }

#if canImport(ObjectiveC)
	@objc
#endif
    public convenience init(settings: Settings,
                            logger: VNCLogger) {
        self.init(settings: settings,
                  logger: logger,
                  framebufferAllocator: nil,
                  context: nil)
	}

#if canImport(ObjectiveC)
	@objc
#endif
	public convenience init(settings: Settings) {
        self.init(settings: settings,
                  context: nil)
	}
    
    public convenience init(settings: Settings,
                            framebufferAllocator: VNCFramebufferAllocator?) {
        self.init(settings: settings,
                  framebufferAllocator: framebufferAllocator,
                  context: nil)
    }

    public convenience init(settings: Settings,
                            framebufferAllocator: VNCFramebufferAllocator?,
                            context: UnsafeMutableRawPointer?) {
#if canImport(OSLog)
        let logger = VNCOSLogLogger()
#else
        let logger = VNCPrintLogger()
#endif

        self.init(settings: settings,
                  logger: logger,
                  framebufferAllocator: framebufferAllocator,
                  context: context)
    }
    
    public convenience init(settings: Settings,
                            context: UnsafeMutableRawPointer?) {
        self.init(settings: settings,
                  framebufferAllocator: nil,
                  context: context)
    }

	deinit {
		let _self = self

		_self.clipboardMonitor.delegate = nil

		stopMonitoringClipboard()
	}
}

// MARK: - Internal Connection State API
extension VNCConnection {
	func beginConnecting() {
		updateConnectionState(.connecting)

		connection.start(queue: queue)
	}

	func beginDisconnecting(error: Error? = nil) {
		guard !state.disconnectRequested else { return }

		state.disconnectRequested = true
		cancelWaitingGrace()
		updateConnectionState(.disconnecting)

		connection.setStatusUpdateHandler(nil)
		connection.cancel()

		if let error = error {
			updateConnectionState(.disconnected(error: error))
		} else {
			updateConnectionState(.disconnected)
		}
	}

	func handleBreakingError(_ error: Error) {
		beginDisconnecting(error: error)
	}

	func updateConnectionState(_ newConnectionState: ConnectionState) {
		self.connectionState = newConnectionState

		switch newConnectionState.status {
			case .connecting:
				break

			case .connected:
				startMonitoringClipboard()

			case .disconnecting:
				stopMonitoringClipboard()

			case .disconnected:
				stopMonitoringClipboard()
		}

		notifyDelegateAboutConnectionStateChange(newConnectionState)
	}
}

// MARK: - Connection State Change Handling
private extension VNCConnection {
	func connectionStatusDidChange(_ newState: NetworkConnectionStatus) {
		switch newState {
			case .setup:
				logger.logDebug("Connection State - Setup")

			case .preparing:
				logger.logDebug("Connection State - Preparing")

				// A viable path was found and the connection is establishing — it has
				// left `.waiting`, so drop the grace timer.
				cancelWaitingGrace()

			case .ready:
				logger.logDebug("Connection State - Ready")

				cancelWaitingGrace()
				connectionDidBecomeReady()

			case .waiting(let error):
				// NWConnection enters `.waiting` when it temporarily lacks a viable
				// path (Wi-Fi⇄cellular handoff, brief network loss, app resuming from
				// suspension). How we react depends on whether the session is already up:
				if state.didBecomeReady {
					// Established session lost its path. Fail promptly so the higher-level
					// reconnect machine rebuilds a fresh connection — don't silently stall
					// the UI on a stale framebuffer waiting for a recovery that may not come.
					logger.logDebug("Connection State - Waiting after established — failing to trigger reconnect: \(error)")

					connectionDidFail(error: .connection(.failed(error)))
				} else {
					// Pre-establishment: NWConnection is still trying to reach the host.
					// This is RECOVERABLE — it keeps retrying and transitions to `.ready`
					// on its own (e.g. once the new Wi-Fi path comes up). Failing on the
					// first `.waiting` tore down otherwise-recoverable connects and, under
					// the reconnect machine, drove a connection storm (every retry failing
					// instantly). So tolerate it, but bound the wait with a grace timer so a
					// genuinely unreachable host still fails instead of hanging forever.
					logger.logDebug("Connection State - Waiting (pre-ready, allowing grace) with error: \(error)")

					scheduleWaitingGrace(error: error)
				}

			case .failed(let error):
				logger.logDebug("Connection State - Failed with error: \(error)")

				cancelWaitingGrace()
				connectionDidFail(error: .connection(.failed(error)))

			case .cancelled:
				logger.logDebug("Connection State - Cancelled")

				cancelWaitingGrace()
				connectionDidFail(error: .connection(.cancelled))

            case .unknown(let underlyingState):
				logger.logDebug("Connection State - Unknown (\(underlyingState))")
		}
	}

	func connectionDidBecomeReady() {
		// Run the VNC handshake exactly once per connection. Re-running it on an
		// already-established session would corrupt the protocol stream. (A post-
		// establishment `.waiting` now fails the connection rather than recovering,
		// so a second `.ready` shouldn't occur — but guard regardless.)
		guard !state.didBecomeReady else {
			logger.logDebug("Connection State - Ready (again, already handshook) — ignoring")

			return
		}
		state.didBecomeReady = true

		Task {
			do {
				try await handshake()
				try await sendFramebufferUpdateRequest()
			} catch {
				handleBreakingError(error)

                return
			}

			updateConnectionState(.connected)

			startReceiveLoop()
			startSendLoop()
		}
	}

	func connectionDidFail(error: VNCError) {
		handleBreakingError(error)
	}

	/// How long a pre-`.ready` connection is allowed to sit in `.waiting` (retrying
	/// for a viable path) before we give up and fail. Slightly under the socket's
	/// 15s `connectionTimeout` so this is the effective bound for the "no path yet"
	/// case (where the TCP-level timeout may not fire on its own).
	private var waitingGraceInterval: TimeInterval { 12 }

	/// Schedule (or refresh) the grace timer for a pre-`.ready` `.waiting`. If the
	/// connection hasn't become ready or been torn down by the time it fires, fail
	/// it so the higher-level reconnect machine can react. Runs on the connection
	/// queue, matching where state transitions are delivered.
	func scheduleWaitingGrace(error: Error) {
		state.waitingGraceWorkItem?.cancel()

		let work = DispatchWorkItem { [weak self] in
			guard let self else { return }
			guard !self.state.didBecomeReady, !self.state.disconnectRequested else { return }

			// `queue` is concurrent, so this can run alongside a state-change callback
			// and `cancel()` can't stop an already-started closure. Gate on NWConnection's
			// own thread-safe live status: only fail if it's *still* `.waiting`. If it has
			// moved on (`.preparing`/`.ready`/etc.) it's making progress, so leave it be —
			// this is race-free against any forward transition, not just `.ready`.
			guard case .waiting = self.connection.status else { return }

			self.logger.logDebug("Connection State - Waiting grace expired — failing")
			self.connectionDidFail(error: .connection(.failed(error)))
		}

		state.waitingGraceWorkItem = work
		queue.asyncAfter(deadline: .now() + waitingGraceInterval, execute: work)
	}

	/// Cancel any pending waiting-grace timer (the connection left `.waiting`).
	func cancelWaitingGrace() {
		state.waitingGraceWorkItem?.cancel()
		state.waitingGraceWorkItem = nil
	}
}
