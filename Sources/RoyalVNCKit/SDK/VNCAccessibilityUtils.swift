#if os(macOS)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AppKit
// `import ApplicationServices` (and the `AXIsProcessTrusted()` call below)
// were removed for App Store static-analysis compliance: nothing in the
// host app actually calls `VNCAccessibilityUtils.hasAccessibilityPermissions`,
// but the reference contributed an Accessibility-framework symbol to the
// shipped binary, which Mac App Review flags under Guideline 2.4.5. The
// API surface is preserved (returns `false` so callers can fall back), so
// if a future caller needs real AX detection, re-introduce the call behind
// a non-APPSTORE_BUILD compile flag at the package level. — 2026-05-19

@objc(VNCAccessibilityUtils)
public final class VNCAccessibilityUtils: NSObject {
	private static let accessibilityPreferencePaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    @objc
	public static func inputModeRequiresAccessibilityPermissions(_ inputMode: VNCConnection.Settings.InputMode) -> Bool {
		inputMode.requiresAccessibilityPermissions
	}

    @objc
	public static var hasAccessibilityPermissions: Bool {
		// Stubbed for App Store compliance — see file header. Currently no
		// callers in the host app. Returning `false` is safe: callers would
		// just route the user to the System Settings deep link instead of
		// assuming permission is already granted.
		return false
	}

	@discardableResult
    @objc
	public static func openAccessibilityPermissionsPreferencePane() -> Bool {
		let success = NSWorkspace.shared.open(accessibilityPreferencePaneURL)

		return success
	}
}
#endif
