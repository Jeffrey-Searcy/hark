// swift-tools-version:6.0
//
// Package.swift — build definition for Hark, a macOS app with a small floating bar.
// Hark records the microphone ("Me") and all computer audio ("Them"), transcribes
// both locally with whisper.cpp, and saves a merged .txt transcript. It also reads
// selected text or web articles aloud with a local voice model (Read Aloud).
// Built with SwiftPM; build.sh wraps the binary into Hark.app (needed so macOS can
// grant mic / audio / Accessibility permissions).
import PackageDescription

let package = Package(
    name: "Hark",
    // macOS 15+: needed for AVAudioFile.close(); the Core Audio process tap API
    // itself needs 14.2+.
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Hark",
            path: "Sources/Hark",
            // why: Swift 5 language mode; the audio callbacks share state via locks, not actors.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
