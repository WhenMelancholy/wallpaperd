import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No Dock icon, no menu bar, but can create windows

let delegate = WallpaperDaemonDelegate()
app.delegate = delegate

// Run the AppKit event loop (blocks forever)
app.run()
