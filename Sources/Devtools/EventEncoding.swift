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

/// `DevtoolsEncoder` converts ``DocEvent`` and ``OperationInfo`` values into the
/// JSON shapes used by the yorkie-js-sdk devtools format.
///
/// The output is intentionally byte-compatible with the events recorded by
/// `yorkie-js-sdk` (`docEventsForReplayByDocKey`), so an iOS recording can be
/// diffed against a JS recording of the same session to locate cross-platform
/// divergence. Field-name differences (`actorID` → `actor`), `Data` → base64,
/// integer sequences → strings, and the kebab-case tree op types are all
/// reconciled here.
enum DevtoolsEncoder {
    // MARK: - Events

    /// Encodes a replayable ``DocEvent`` into its JS devtools JSON object.
    ///
    /// - Parameter event: The event to encode.
    /// - Returns: A JSON object, or `nil` when `event` is not one of the eight
    ///   replayable event types (status / snapshot / local / remote change /
    ///   initialized / watched / unwatched / presence change).
    static func encode(event: DocEvent) -> [String: Any]? {
        switch event {
        case let event as StatusChangedEvent:
            var value: [String: Any] = ["status": event.value.status.rawValue]
            if let actorID = event.value.actorID {
                value["actorID"] = actorID
            }
            return ["type": event.type.rawValue, "source": self.source(event.source), "value": value]

        case let event as SnapshotEvent:
            var value: [String: Any] = [
                "serverSeq": String(event.value.serverSeq),
                "snapshotVector": event.value.snapshotVector
            ]
            // JS: `snapshot: string | undefined`. Encode binary as base64.
            if let snapshot = event.value.snapshot {
                value["snapshot"] = snapshot.base64EncodedString()
            }
            return ["type": event.type.rawValue, "source": "remote", "value": value]

        case let event as LocalChangeEvent:
            return ["type": event.type.rawValue, "source": "local", "value": self.changeInfo(event.value)]

        case let event as RemoteChangeEvent:
            return ["type": event.type.rawValue, "source": "remote", "value": self.changeInfo(event.value)]

        case let event as InitializedEvent:
            let value = event.value.map { self.peer($0) }
            return ["type": event.type.rawValue, "source": "local", "value": value]

        case let event as WatchedEvent:
            return ["type": event.type.rawValue, "source": "remote", "value": self.peer(event.value)]

        case let event as UnwatchedEvent:
            return ["type": event.type.rawValue, "source": "remote", "value": self.peer(event.value)]

        case let event as PresenceChangedEvent:
            // NOTE: iOS does not carry `OpSource` on presence-changed events.
            // The replay panel keys off `type`/`value`; `source` defaults to
            // "remote" here, matching the common remote-presence case.
            return ["type": event.type.rawValue, "source": "remote", "value": self.peer(event.value)]

        // iOS-only diagnostic events. yorkie-js-sdk's devtools does not record
        // these (they are excluded from `isDocEventForReplay`), but they are
        // invaluable for debugging watch-stream reconnect storms, so the iOS
        // recorder captures them. They are tagged so the cross-platform diff can
        // ignore them.
        case let event as ConnectionChangedEvent:
            let status: String
            switch event.value {
            case .connected: status = "connected"
            case .disconnected: status = "disconnected"
            }
            return ["type": event.type.rawValue, "value": status, "iosOnly": true]

        case let event as SyncStatusChangedEvent:
            return ["type": event.type.rawValue, "value": event.value.rawValue, "iosOnly": true]

        default:
            return nil
        }
    }

    // MARK: - Operations

    /// Encodes an ``OperationInfo`` into its JS `OpInfo` JSON object.
    static func encode(operationInfo op: any OperationInfo) -> [String: Any] {
        switch op {
        case let op as AddOpInfo:
            return ["type": "add", "path": op.path, "index": op.index]

        case let op as MoveOpInfo:
            return ["type": "move", "path": op.path, "previousIndex": op.previousIndex, "index": op.index]

        case let op as SetOpInfo:
            return ["type": "set", "path": op.path, "key": op.key]

        case let op as ArraySetOpInfo:
            return ["type": "array-set", "path": op.path]

        case let op as RemoveOpInfo:
            var dict: [String: Any] = ["type": "remove", "path": op.path]
            if let key = op.key {
                dict["key"] = key
            }
            if let index = op.index {
                dict["index"] = index
            }
            return dict

        case let op as IncreaseOpInfo:
            return ["type": "increase", "path": op.path, "value": op.value]

        case let op as EditOpInfo:
            return ["type": "edit", "path": op.path, "from": op.from, "to": op.to,
                    "value": ["attributes": self.sanitize(op.attributes ?? [:]), "content": op.content ?? ""]]

        case let op as StyleOpInfo:
            return ["type": "style", "path": op.path, "from": op.from, "to": op.to,
                    "value": ["attributes": self.sanitize(op.attributes ?? [:])]]

        case let op as TreeEditOpInfo:
            return ["type": "tree-edit", "path": op.path, "from": op.from, "to": op.to,
                    "fromPath": op.fromPath, "toPath": op.toPath, "splitLevel": Int(op.splitLevel),
                    "value": op.value.map { self.treeNode($0) }]

        case let op as TreeStyleOpInfo:
            var value: [String: Any] = [:]
            switch op.value {
            case .attributes(let attributes):
                value["attributes"] = self.sanitize(attributes)
            case .attributesToRemove(let toRemove):
                value["attributesToRemove"] = toRemove
            case .none:
                break
            }
            return ["type": "tree-style", "path": op.path, "from": op.from, "to": op.to,
                    "fromPath": op.fromPath, "toPath": op.toPath, "value": value]

        default:
            // Defensive fallback for op types without a JS counterpart (e.g. `select`).
            return ["type": op.type.rawValue, "path": op.path]
        }
    }

    // MARK: - Helpers

    private static func source(_ source: OpSource) -> String {
        switch source {
        case .local: return "local"
        case .remote: return "remote"
        case .undoRedo: return "undoredo"
        }
    }

    private static func changeInfo(_ info: ChangeInfo) -> [String: Any] {
        ["message": info.message,
         "operations": info.operations.map { self.encode(operationInfo: $0) },
         "actor": info.actorID ?? "",
         "clientSeq": Int(info.clientSeq),
         "serverSeq": info.serverSeq]
    }

    private static func peer(_ peer: PeerElement) -> [String: Any] {
        ["clientID": peer.clientID, "presence": self.sanitize(peer.presence)]
    }

    /// Parses a tree node's JSON string back into a JSON object so it nests
    /// cleanly inside the operation payload.
    private static func treeNode(_ node: any JSONTreeNode) -> Any {
        let string = node.toJSONString
        if let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        {
            return object
        }
        return string
    }

    /// Recursively coerces an arbitrary `[String: Any]` (presence, attributes)
    /// into a value `JSONSerialization` can encode, stringifying anything else.
    static func sanitize(_ dictionary: [String: Any]) -> [String: Any] {
        dictionary.mapValues { self.sanitizeValue($0) }
    }

    private static func sanitizeValue(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return string
        case let bool as Bool where value is Bool:
            return bool
        case let number as NSNumber:
            return number
        case let dictionary as [String: Any]:
            return self.sanitize(dictionary)
        case let array as [Any]:
            return array.map { self.sanitizeValue($0) }
        case is NSNull:
            return NSNull()
        default:
            return String(describing: value)
        }
    }
}
