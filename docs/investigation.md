# Investigation: How macOS Screen Time Tracks Apps (and How to Avoid It)

## The Problem

Every dynamic wallpaper app on macOS (Plash, Dynamic Wallpaper, Pap.er, etc.) shows up as 24 hours of daily usage in Screen Time. This happens because:

1. These apps create a full-screen borderless `NSWindow` at desktop level
2. macOS Screen Time (introduced in Catalina) records any app with a visible window as "in use"
3. Unlike iOS, macOS Screen Time tracks "app open time", not "foreground time"
4. **There is no way to exclude specific apps from Screen Time** — Apple has confirmed this

## The Screen Time Data Pipeline

```
WindowServer event (app gains visible window)
    → usaged daemon
    → NSRunningApplication.bundleIdentifier
    → knowledgeC.db (ZOBJECT table, ZVALUESTRING = bundle ID)
    → Biome SEGB files (~/Library/Biome/streams/public/App.InFocus/)
    → Screen Time UI
```

The entire pipeline depends on `CFBundleIdentifier`. No bundle ID → no record.

## Three Attack Surfaces We Investigated

### Path A: Clean the Data (modify what gets recorded)

- **knowledgeC.db** (`~/Library/Application Support/Knowledge/knowledgeC.db`) — SQLite, can DELETE rows matching a bundle ID
- **Biome SEGB** (`~/Library/Biome/`) — binary protobuf, harder to edit, can delete files
- Automate via LaunchAgent every 5 minutes
- **Verdict**: Works but fragile. Schema can change, iCloud sync can re-introduce deleted records

### Path B: Don't Generate Events (bare Mach-O binary) ← Winner

- A process without `.app` bundle has no `CFBundleIdentifier`
- `NSRunningApplication.bundleIdentifier` returns `nil`
- Screen Time cannot file a record with a nil key
- The process can still create `NSWindow`, use `AVPlayerLayer`, etc. — AppKit doesn't care about bundle identity
- **Verified**: After 30+ minutes of running, `wallpaperd` does not appear in `knowledgeC.db`

### Path C: Hijack System Processes (WallpaperAgent / ExtensionKit)

- macOS Sonoma has internal wallpaper extensions: `WallpaperVideoExtension.appex`, `WallpaperImageExtension.appex`
- Extension point name is `wallpaper` (private, third-party cannot register)
- Cindori's Backdrop reverse-engineered this using Hopper + LLM to enable custom lock screen video
- **Verdict**: Most elegant but requires deep reverse engineering, private APIs, and breaks across macOS updates

## Key Technical Details

### .app Bundle vs Bare Mach-O Binary

| Aspect | .app | Bare Mach-O |
|--------|------|-------------|
| `CFBundleIdentifier` | Present | **Absent** |
| `NSRunningApplication` listing | Listed | Not listed |
| Screen Time tracking | Tracked | **Not tracked** |
| Can create NSWindow | Yes | Yes (in GUI session) |
| Can use AVPlayer | Yes | Yes |
| Launch method | LaunchServices | LaunchAgent / exec() |

### Why LaunchAgent Works

LaunchAgents run in the user's login session → they inherit the GUI session → they can connect to WindowServer → they can create windows. This is different from LaunchDaemons which run at system level without GUI access.

### The Window Configuration

```swift
window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
window.ignoresMouseEvents = true
window.isOpaque = true
window.backgroundColor = .black
```

This places the window above the system wallpaper but below desktop icons. `.canJoinAllSpaces` makes it visible on all Spaces. `.ignoresCycle` excludes it from Cmd+\` switching. `ignoresMouseEvents` makes clicks pass through to the desktop.

## macOS Wallpaper System Internals (Sonoma+)

Apple's internal wallpaper system uses ExtensionKit:

- **WallpaperAgent** (`/System/Library/CoreServices/`) — coordinator
- **WallpaperVideoExtension.appex** — plays Aerial videos via custom VideoToolbox player
- **CAPluginLayer** (private API) — renders into offscreen window
- **SkyLight notifications** (`kSLSCoordinatedScreenUnlock`) — login/logout video transitions
- **idleassetsd** — downloads and manages Aerial videos
- Wallpaper choices stored in `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`

Oskar Groth (Cindori/Backdrop) documented parts of this via reverse engineering:
https://mastodon.social/@oskargroth/112808773912435050

## Seamless Looping

The loop stutter with `AVPlayer.seek(to: .zero)` is caused by decoder re-initialization at the seek point. We solve this with:

1. **ffmpeg crossfade preprocessing** — make the video visually seamless at the loop boundary
2. **AVMutableComposition** — repeat the video 50× so the seek only happens every ~6 minutes
3. **Encoding optimization** — closed GOP, faststart, keyframe at frame 0

## References

- knowledgeC.db forensics: [mac4n6 APOLLO](https://github.com/mac4n6/APOLLO)
- Biome SEGB parser: [ccl-segb](https://github.com/cclgroupltd/ccl-segb)
- Bundleless NSWindow: [karstenBriksoft/bundlelessApplication](https://gist.github.com/karstenBriksoft/2bfe71e97e9b3ae1edd5bf4c37d55ecb)
- Apple wallpaper internals: [Oskar Groth on Mastodon](https://mastodon.social/@oskargroth/112808773912435050)
- WWDC 2016 "Advances in AVFoundation Playback" — AVPlayerLooper treadmill pattern
