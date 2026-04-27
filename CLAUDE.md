# docstat

macOS menubar app. Swift + SwiftUI + AppKit. Xcode project. Deployment target macOS 14. Bundle id `uk.bennington.docstat`. Local-only ad-hoc signing, no notarization.

Read `README.md` for the user-facing description and design overview before changing behavior.

## Build

`./build.sh` at project root. Requires the full Xcode app, not just Command Line Tools. If `xcodebuild` isn't found, the user needs to `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

For a sanity check without a full build, `swiftc -typecheck -target arm64-apple-macos14.0 -sdk $(xcrun --show-sdk-path --sdk macosx) <every .swift file>` works and is fast. Typecheck does not prove the bundle builds.

## Non-obvious decisions

### Single Docker connection (keep-alive). Don't break this.
The Engine API has no batch stats endpoint, so every refresh requires `GET /containers/json` plus one `GET /containers/{id}/stats?stream=false` per container. Without HTTP/1.1 keep-alive, every request opens and closes a Unix socket, and `Network.framework` emits `nw_protocol_socket_reset_linger ... SO_LINGER failed [22: Invalid argument]` and `Connection has no local endpoint` warnings on each cancel. These are framework log lines, not bugs in our code, but they scale linearly with cancels. Keep-alive collapses 1+N connections per refresh into one persistent connection per popover session.

If you change `DockerClient.swift`, preserve: one `NWConnection` reused across requests, no `Connection: close` header, framing via `Content-Length` or chunked transfer-encoding so the receiver knows when each response ends without closing the socket.

### Streaming `/stats` was rejected
It would force continuous per-second JSON parsing per container regardless of user attention. Audit determined it adds overhead vs the current keep-alive design. Don't switch without a real reason.

### Popover sizing locked from three sides
`NSPopover` plus `NSHostingController` can enter a `_NSDetectedLayoutRecursion` loop when SwiftUI reports a changed intrinsic size mid-layout. All three of these are required, removing any one re-introduces the warning:

1. `popover.contentSize = NSSize(...)` set explicitly in `AppDelegate`.
2. SwiftUI root uses `.frame(width:height:)`, not min.
3. `hostingController.sizingOptions = []` to stop SwiftUI sizing propagating to AppKit.

### Right-click menu pattern
`statusItem.menu = menu; button.performClick(nil); statusItem.menu = nil`. This makes the menu only appear on right-click while leaving left-click routed to `statusItemClicked(_:)`. `popUpMenu` is private API; don't switch to it.

### Actor serializes the task group
`withTaskGroup` in `StatsViewModel.refresh()` looks parallel but `DockerClient` is an actor, so per-container `stats(for:)` calls run sequentially. With keep-alive on one socket this is correct - HTTP/1.1 requests must serialize over a single connection. Don't try to parallelize by dropping the actor isolation without also reworking the connection model.

### CPU% / memory math
Formulas match the `docker stats` CLI exactly. CPU deltas are converted to `Int64` before subtraction to avoid `UInt64` underflow when `precpu > cpu` (rare but possible). Memory uses `usage - cache` with a `cache > usage` guard. See `StatsViewModel.normalize`.

### Custom table, not SwiftUI `Table`
SwiftUI's `Table` has too much built-in chrome (zebra stripes, header borders, column separators) and is hard to style cleanly. The popover uses a hand-rolled header row plus `LazyVStack` of `StatRow`. Each row tracks its own `@State hovering` for bold-on-hover via `.onHover`. Sort state is `(SortColumn, Bool)` on the view model, with `applySort()` running after each refresh.

### Custom Xcode project file
`docstat.xcodeproj/project.pbxproj` was written by hand (no xcodegen). If you add a new `.swift` file, you must add it as a `PBXFileReference`, a `PBXBuildFile`, into the appropriate `PBXGroup`, and into the `PBXSourcesBuildPhase`. Or regenerate with xcodegen if available.

## Files not in git
`build/`, `.DS_Store`, `xcuserdata/`, `*.xcuserstate`. See `.gitignore`.
