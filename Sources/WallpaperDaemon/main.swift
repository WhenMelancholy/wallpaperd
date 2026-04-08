// wallpaperd — Bare Mach-O video wallpaper daemon
// Invisible to macOS Screen Time (no .app bundle, no bundle identifier)
// Launched via LaunchAgent, renders video to desktop-level windows

import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // No Dock icon, no menu bar, but can create windows

let delegate = WallpaperDaemonDelegate()
app.delegate = delegate

// Run the AppKit event loop (blocks forever)
app.run()
