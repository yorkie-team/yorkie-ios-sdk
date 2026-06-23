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
import Yorkie

/// `YorkieInspectorModel` drives ``YorkieInspectorView``.
///
/// It attaches to a ``Document``'s ``DevtoolsRecorder`` and refreshes the change
/// timeline and document tree whenever a new event is recorded. The document
/// must have been created with `enableDevtools: true`; otherwise the inspector
/// reports that recording is unavailable.
@MainActor
public final class YorkieInspectorModel: ObservableObject {
    /// The change timeline, newest first.
    @Published public private(set) var timeline: [DevtoolsTimelineEntry] = []

    /// The current document tree, parsed from `toSortedJSON()`.
    @Published public private(set) var tree: [JSONNode] = []

    /// Whether a recorder is attached and capturing.
    @Published public private(set) var isRecording = false

    /// The destination of the most recent export, surfaced for the UI.
    @Published public private(set) var lastExportURL: URL?

    /// The most recent error message, surfaced for the UI.
    @Published public private(set) var lastError: String?

    private weak var document: Document?
    private var recorder: DevtoolsRecorder?

    public init() {}

    /// The number of events currently buffered.
    public var eventCount: Int {
        self.recorder?.count ?? 0
    }

    private var observerToken: UUID?

    /// Attaches to `document` and performs an initial refresh.
    public func start(document: Document) {
        self.document = document
        self.recorder = document.attachDevtoolsRecorder()
        self.isRecording = self.recorder != nil
        self.observerToken = self.recorder?.addObserver { [weak self] in
            self?.refresh()
        }
        self.refresh()
    }

    /// Detaches the update observer.
    public func stop() {
        if let token = self.observerToken {
            self.recorder?.removeObserver(token)
            self.observerToken = nil
        }
        self.isRecording = false
    }

    /// Clears the recording buffer.
    public func clear() {
        self.recorder?.clear()
        self.refresh()
    }

    /// Exports the recording to a JSON file in the temporary directory.
    public func export() {
        guard let document = self.document else {
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yorkie-devtools-\(UUID().uuidString.prefix(8)).json")
        do {
            try document.exportDevtools(to: url)
            self.lastExportURL = url
            self.lastError = nil
        } catch {
            self.lastError = String(describing: error)
        }
    }

    private func refresh() {
        if let batches = self.recorder?.dump() {
            let flattened = batches.flatMap { $0 }
            self.timeline = flattened.enumerated()
                .map { DevtoolsTimelineEntry(id: $0.offset, json: $0.element) }
                .reversed()
        }

        if let json = self.document?.toSortedJSON() {
            self.tree = JSONNode.parse(sortedJSON: json)
        }
    }
}
