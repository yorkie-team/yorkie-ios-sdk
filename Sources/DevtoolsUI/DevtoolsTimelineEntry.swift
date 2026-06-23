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

/// `DevtoolsTimelineEntry` is one row in the inspector's change timeline,
/// derived from a single encoded devtools event.
public struct DevtoolsTimelineEntry: Identifiable {
    public let id: Int

    /// The event type, e.g. `local-change`, `remote-change`, `snapshot`.
    public let type: String

    /// The event source, e.g. `local`, `remote`, `undoredo`.
    public let source: String

    /// A one-line human summary of the event.
    public let summary: String

    /// A directional hint: outbound local edits push to the server, inbound
    /// remote edits pull from it.
    public let direction: Direction

    /// The event re-serialised as pretty JSON for the detail view.
    public let prettyJSON: String

    public enum Direction {
        case push
        case pull
        case neutral
    }

    init(id: Int, json: [String: Any]) {
        self.id = id
        let type = json["type"] as? String ?? "?"
        self.type = type
        self.source = json["source"] as? String ?? ""

        switch type {
        case "local-change":
            self.direction = .push
        case "remote-change", "snapshot":
            self.direction = .pull
        default:
            self.direction = .neutral
        }

        self.summary = Self.summarize(type: type, json: json)

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let string = String(data: data, encoding: .utf8)
        {
            self.prettyJSON = string
        } else {
            self.prettyJSON = "\(json)"
        }
    }

    private static func summarize(type: String, json: [String: Any]) -> String {
        let value = json["value"] as? [String: Any]

        switch type {
        case "local-change", "remote-change":
            let operations = value?["operations"] as? [[String: Any]] ?? []
            let opTypes = operations.compactMap { $0["type"] as? String }
            let message = value?["message"] as? String ?? ""
            let opsLabel = opTypes.isEmpty ? "no ops" : opTypes.joined(separator: ", ")
            return message.isEmpty ? opsLabel : "\(opsLabel) — \(message)"

        case "snapshot":
            let serverSeq = value?["serverSeq"] as? String ?? "?"
            return "serverSeq \(serverSeq)"

        case "status-changed":
            return value?["status"] as? String ?? ""

        case "watched", "unwatched", "presence-changed", "initialized":
            return json["source"] as? String ?? type

        default:
            return type
        }
    }
}
