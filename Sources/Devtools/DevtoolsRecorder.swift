/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

/// `DevtoolsRecorder` captures a document's replayable events into a bounded,
/// always-on ring buffer for cross-platform debugging.
///
/// When ``Document`` is created with `enableDevtools`, every replayable
/// ``DocEvent`` is forwarded here and encoded into the yorkie-js-sdk devtools
/// JSON format (see ``DevtoolsEncoder``). The buffer keeps only the most recent
/// ``maxEvents`` events, so when an issue surfaces the dump contains the lead-up
/// *before* the failure rather than only what happened after recording started.
///
/// The exported payload is `Array<DocEventsForReplay>` — directly comparable to
/// a JS recording of the same session.
@MainActor
public final class DevtoolsRecorder {
    /// Default ring-buffer capacity.
    public nonisolated static let defaultMaxEvents = 500

    private let docKey: String
    private let maxEvents: Int
    /// Encoded replayable events, oldest first.
    private var events: [[String: Any]] = []

    /// Observers notified on the main actor after the buffer changes (a recorded
    /// event or ``clear()``). Multiple inspectors (e.g. the browser server and
    /// the in-app SwiftUI inspector) can observe concurrently without clobbering
    /// each other — register with ``addObserver(_:)`` and release with
    /// ``removeObserver(_:)``.
    private var observers: [UUID: () -> Void] = [:]

    /// Registers an observer, returning a token to pass to ``removeObserver(_:)``.
    @discardableResult
    public func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        self.observers[token] = observer
        return token
    }

    /// Removes a previously-registered observer.
    public func removeObserver(_ token: UUID) {
        self.observers.removeValue(forKey: token)
    }

    private func notifyObservers() {
        // Snapshot before iterating: an observer callback may add or remove an
        // observer, which would mutate the dictionary mid-iteration.
        let callbacks = Array(self.observers.values)
        for observer in callbacks {
            observer()
        }
    }

    init(docKey: String, maxEvents: Int = DevtoolsRecorder.defaultMaxEvents) {
        self.docKey = docKey
        self.maxEvents = max(1, maxEvents)
    }

    /// The number of events currently held in the buffer.
    public var count: Int {
        self.events.count
    }

    /// Records a recordable event, dropping the oldest entries past capacity.
    ///
    /// Captures the eight JS-replayable event types plus the iOS-only diagnostic
    /// `connection-changed` / `sync-status-changed` events (tagged `iosOnly`).
    /// `auth-error` / `epoch-mismatch` are ignored.
    func record(_ event: DocEvent) {
        guard let encoded = DevtoolsEncoder.encode(event: event) else {
            return
        }

        self.events.append(encoded)
        if self.events.count > self.maxEvents {
            self.events.removeFirst(self.events.count - self.maxEvents)
        }
        self.notifyObservers()
    }

    /// Clears the buffer and notifies observers so inspectors refresh.
    public func clear() {
        self.events.removeAll()
        self.notifyObservers()
    }

    /// Throws the recording away and starts it again from `baseline`, notifying observers once.
    ///
    /// The panel replays a document from its initial root by applying the raw changes the recording
    /// carries. A document that re-issues its pre-attach tickets to the client's actor rewrites those
    /// changes in place, so the recorded copies name an actor nothing in the document uses any more:
    /// replaying them and then the changes that follow diverges from the live root or throws on an
    /// operation whose target the replay never created. Nothing can repair the recorded copies, so
    /// the history is dropped. The panel replays onto a freshly built empty document and cannot be
    /// told "start from here", so a recording that merely started over would be a history missing its
    /// beginning; `baseline` -- a snapshot of the document as it stands -- becomes the first entry so
    /// that what the panel holds is a complete history again.
    ///
    /// - Parameter baseline: The event the new recording starts with, or `nil` for an empty one.
    func reset(baseline: DocEvent?) {
        self.events.removeAll()
        if let baseline {
            if let encoded = DevtoolsEncoder.encode(event: baseline) {
                self.events.append(encoded)
            } else {
                Logger.warning("[DT] d:\"\(self.docKey)\" could not encode the baseline event \(type(of: baseline)); the recording starts empty")
            }
        }
        self.notifyObservers()
    }

    /// Returns the recording as `Array<DocEventsForReplay>`.
    ///
    /// Each iOS event is delivered individually, so it is wrapped as a
    /// single-event batch to match the JS array-of-batches shape.
    public func dump() -> [[[String: Any]]] {
        self.events.map { [$0] }
    }

    /// Wraps the recording in a `doc::sync::full` SDK-to-panel message envelope.
    public func dumpFullSyncMessage() -> [String: Any] {
        ["source": DevtoolsEventSource.sdk,
         "msg": DevtoolsMessageType.fullSync.rawValue,
         "docKey": self.docKey,
         "events": self.dump()]
    }

    /// Serialises the recording to deterministic, JS-comparable JSON.
    ///
    /// - Parameter pretty: Pretty-prints with sorted keys when `true`.
    /// - Returns: The encoded data, or `nil` if serialisation fails.
    public func exportJSON(pretty: Bool = true) -> Data? {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty {
            options.insert(.prettyPrinted)
        }
        return try? JSONSerialization.data(withJSONObject: self.dump(), options: options)
    }

    /// Writes the recording to `url` as JSON.
    ///
    /// - Parameter url: The destination file URL.
    /// - Returns: `url`, for chaining.
    /// - Throws: A serialisation error when the buffer cannot be encoded, plus
    ///   any error raised while writing.
    @discardableResult
    public func export(to url: URL) throws -> URL {
        guard let data = self.exportJSON() else {
            throw YorkieError(code: .errUnexpected, message: "Failed to serialise devtools recording for \(self.docKey).")
        }
        try data.write(to: url)
        return url
    }
}
