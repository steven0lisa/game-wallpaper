import AppKit
import Heroes3Engine

// MARK: - Entry point
//
// Two modes:
//   GUI (default): menu-bar app that renders the registered game engine's scene
//                  as the desktop wallpaper (see WallpaperCore / docs/architecture.md).
//   CLI:     engine-provided headless tools (--snapshot / --probe-def / --tile),
//            see Heroes3Engine/Heroes3CLI.swift.

let arguments = CommandLine.arguments
if Heroes3CLI.dispatch(arguments) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
