# Yorkie Replay — live browser inspector

A browser tool for watching a Yorkie document's changes **in real time**, and for
**diffing** recordings across platforms (iOS / Android / JS) to find where a sync issue
originates. No export step, no install, no external service — it runs locally.

## Live inspection (recommended)

Start the server from your app on a document that has devtools enabled:

```swift
import YorkieDevtoolsServer

let doc = Document(key: "mydoc", opts: DocumentOptions(disableGC: false, enableDevtools: true))
let server = DevtoolsServer(document: doc)   // debug builds only
try server.start()                            // listens on :9123
print(server.urls())                          // ["http://localhost:9123", "http://192.168.x.x:9123"]
```

Open one of those URLs in a browser:

- **Simulator + Mac browser:** use `http://localhost:9123` (the simulator shares localhost).
- **Physical device + Mac browser:** use the LAN URL (`http://<device-ip>:9123`) from a browser on
  the same Wi-Fi. On-device, iOS will prompt for Local Network access and you must add
  `NSLocalNetworkUsageDescription` to the app's Info.plist.

The page streams every change the client pushes (↑ local) or pulls (↓ remote) as it happens, with
the operations each carries and the data-tree paths the session writes to.

> The server binds all interfaces so a device is reachable over the LAN. It is **debug-only** —
> start it only in debug builds and only on devtools-enabled documents.

In the bundled **RichTextEditor** example, tap the **globe** button to see the live URLs (and the
**ladybug** for the in-app SwiftUI inspector).

## Cross-platform diff

Load a second recording into slot **B** to diff the live session (A) against a recording from
another platform. Rows align by **operation semantics** (op type, path, content, message); actor
IDs and sequence numbers are ignored because they legitimately differ between clients of the same
session. The first divergent operation is highlighted — that's where the platforms stopped
agreeing.

## Offline / file-only mode

The viewer page (`../Sources/DevtoolsServer/Resources/viewer.html`) also works when opened directly
via `file://` — it falls back to drag-and-drop of one or two exported JSON files. Export a recording
with `doc.dumpDevtools()` / `doc.exportDevtools(to:)` on iOS, or the equivalent on JS / Android.

Try it with the included samples: load [`sample-recording-ios.json`](./sample-recording-ios.json) as
A and [`sample-recording-js.json`](./sample-recording-js.json) as B — they agree for four operations
(despite different actor IDs) and diverge on the fifth (`add $.list[0]` vs `set $.list.0`).

## Format

`Array<DocEventsForReplay>` — an array of event batches, each event `{ type, source, value }`.
Mirrors `yorkie-js-sdk/packages/sdk/src/devtools`. See `Sources/Devtools` (recorder),
`Sources/DevtoolsServer` (live server + viewer), and `Sources/DevtoolsUI` (in-app SwiftUI inspector).
