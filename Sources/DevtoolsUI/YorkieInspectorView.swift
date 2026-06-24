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

import SwiftUI
import Yorkie

/// `YorkieInspectorView` is an in-app debugger for a ``Document``.
///
/// It shows the live document tree and a timeline of the changes flowing to and
/// from the server, and can export the recording in the yorkie-js-sdk devtools
/// format for cross-platform comparison. Present it over any document created
/// with `DocumentOptions(disableGC:enableDevtools: true)`.
///
/// ```swift
/// let doc = Document(key: "mydoc", opts: DocumentOptions(disableGC: false, enableDevtools: true))
/// // ...
/// .sheet(isPresented: $showInspector) { YorkieInspectorView(document: doc) }
/// ```
public struct YorkieInspectorView: View {
    @StateObject private var model = YorkieInspectorModel()
    private let document: Document

    public init(document: Document) {
        self.document = document
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                self.header
                Divider()
                if self.model.isRecording {
                    self.tabs
                } else {
                    self.disabledState
                }
            }
            .navigationTitle("Yorkie Inspector")
        }
        #if os(iOS)
        .navigationViewStyle(.stack)
        #endif
        .onAppear { self.model.start(document: self.document) }
        .onDisappear { self.model.stop() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Circle()
                    .fill(self.model.isRecording ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text("\(self.model.eventCount) events")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") { self.model.clear() }
                    .font(.caption)
                    .disabled(!self.model.isRecording)
                Button("Export") { self.model.export() }
                    .font(.caption)
                    .disabled(!self.model.isRecording)
            }

            if let url = self.model.lastExportURL {
                Text("Saved: \(url.path)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = self.model.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Tabs

    private var tabs: some View {
        TabView {
            self.treeTab
                .tabItem { Label("Tree", systemImage: "list.bullet.indent") }
            self.timelineTab
                .tabItem { Label("Timeline", systemImage: "clock") }
        }
    }

    private var treeTab: some View {
        Group {
            if self.model.tree.isEmpty {
                self.emptyState("No document data yet")
            } else {
                List {
                    OutlineGroup(self.model.tree, children: \.children) { node in
                        self.treeRow(node)
                    }
                }
            }
        }
    }

    private func treeRow(_ node: JSONNode) -> some View {
        HStack {
            Text(node.key)
                .font(.system(.body, design: .monospaced))
            Spacer()
            Text(node.valuePreview)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private var timelineTab: some View {
        Group {
            if self.model.timeline.isEmpty {
                self.emptyState("No events recorded yet")
            } else {
                List(self.model.timeline) { entry in
                    NavigationLink(destination: self.detail(entry)) {
                        self.timelineRow(entry)
                    }
                }
            }
        }
    }

    private func timelineRow(_ entry: DevtoolsTimelineEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: self.directionIcon(entry.direction))
                .foregroundColor(self.directionColor(entry.direction))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.type)
                    .font(.caption)
                    .bold()
                Text(entry.summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(entry.source)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func detail(_ entry: DevtoolsTimelineEntry) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(entry.prettyJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(entry.type)
    }

    // MARK: - States

    private var disabledState: some View {
        self.emptyState("Devtools is not enabled for this document.\nCreate it with DocumentOptions(disableGC:enableDevtools: true).")
    }

    private func emptyState(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func directionIcon(_ direction: DevtoolsTimelineEntry.Direction) -> String {
        switch direction {
        case .push: return "arrow.up.circle.fill"
        case .pull: return "arrow.down.circle.fill"
        case .neutral: return "circle.fill"
        }
    }

    private func directionColor(_ direction: DevtoolsTimelineEntry.Direction) -> Color {
        switch direction {
        case .push: return .blue
        case .pull: return .green
        case .neutral: return .gray
        }
    }
}
