# docstat

`docstat` is a macOS menubar app which when clicked will show the current CPU%, Mem usage and mem% for all running containers from `docker stats` (or the api via the socket directly). It then shows the results of individual containers in a table, which can be sorted.

There is a small refresh icon at the top. Data is fetched when the icon is clicked, and on this refresh button. Data also auto-refreshes every 5 seconds while the popover is open.

Table columns are `Name`, `CPU %`, `Mem`, `Mem %`. Click a column header to sort; click again to flip direction. Hovering a row bolds it.

There is a right click option to close the app.

## Build and install

Requires the full Xcode app (not just Command Line Tools). After installing Xcode from the App Store:

    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

Then from the project root:

    ./build.sh

This builds Release, copies the `.app` to `/Applications/docstat.app`, and strips the Gatekeeper quarantine bit so it launches without a warning. Open via Spotlight or from `/Applications`.

## Design overview

### Components

- `AppDelegate` (AppKit) owns the `NSStatusItem`, `NSPopover`, right-click `NSMenu`, and the 5-second refresh timer. Left vs right click is distinguished via `NSApp.currentEvent.type`.
- `DockerClient` (Swift `actor`) is an HTTP/1.1 client speaking to the Docker Engine API over its Unix socket using `Network.framework`'s `NWConnection`. It holds one persistent connection for the lifetime of a popover session and reuses it across requests via keep-alive.
- `StatsViewModel` (`@MainActor ObservableObject`) orchestrates each refresh (fan-out via `withTaskGroup`), normalizes raw Docker JSON into `ContainerStats` rows, and holds sort state.
- `PopoverView` (SwiftUI) is the popover's contents: aggregate header on top, custom sortable table built from a `LazyVStack` of `StatRow` views below. Each row tracks its own hover state.

### Docker query pattern

The Docker Engine API has no aggregate stats endpoint. Per refresh the app issues:

1. `GET /containers/json` to list running containers.
2. `GET /containers/{id}/stats?stream=false` per container.

This N+1 fanout is unavoidable; even the `docker stats` CLI does the same. To keep socket churn minimal, the client uses HTTP/1.1 keep-alive on a single persistent `NWConnection`. Without keep-alive every request would open and close a Unix-domain socket, which causes `Network.framework` to emit benign but noisy log lines on each cancel. With keep-alive a connection is opened lazily on first refresh and torn down only when the popover closes.

Streaming `/stats` was considered and rejected: it would force continuous per-second JSON parsing per container even when the user isn't looking, adding overhead rather than removing it.

### Popover sizing

`NSPopover` and SwiftUI's `NSHostingController` can enter a layout-feedback loop when SwiftUI's intrinsic size changes mid-layout (e.g. on row count change). Three things together prevent it:

1. `popover.contentSize` is set explicitly to a fixed `NSSize`.
2. The SwiftUI root has a fixed `.frame(width:height:)`, not a min frame.
3. `hostingController.sizingOptions = []` disables propagation of SwiftUI sizing to AppKit.

### Refresh lifecycle

The 5s timer is started on popover open and invalidated on popover close. The `DockerClient` connection is also torn down on close so nothing sits open when the user isn't looking. The manual refresh button and the timer call the same `refresh()` on the view model.
