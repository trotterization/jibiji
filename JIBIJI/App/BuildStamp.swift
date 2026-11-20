import Foundation
import SwiftUI

/// Which commit and settings this binary was built with, so an installed app can be verified.
/// The commit comes from the `JIBIJI_BUILD_COMMIT` build setting (the git short SHA, passed to xcodebuild).
enum BuildStamp {
    static var commit: String { Bundle.main.object(forInfoDictionaryKey: "JibijiBuildCommit") as? String ?? "unknown" }

    static var summary: String {
        let defaults = UserDefaults.standard
        let grouping = NoteReading.isEnabled ? "on" : "off"
        let paddle = defaults.bool(forKey: "JibijiUsePaddlePipeline") ? "on" : "off"
        #if DEBUG
        let configuration = "Debug (Paddle models \(PaddleTextPipeline.isInstalled ? "bundled" : "absent"))"
        #else
        let configuration = "Release"
        #endif
        return "build \(commit) · \(configuration)\ngrouping \(grouping) · paddle pipeline \(paddle)"
    }

    #if DEBUG
    static var label: some View {
        Text("build \(commit)")
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(6)
            .allowsHitTesting(false)
            .accessibilityIdentifier("buildStamp")
    }
    #endif
}
