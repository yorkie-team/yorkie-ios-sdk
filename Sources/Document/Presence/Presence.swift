/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
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

/**
 * PresenceData key, value dictionary
 * Similar to an Indexable in JS SDK
 */
public typealias PresenceData = [String: Codable]

/**
 * `presencePatchCapability` is the name the server advertises in `ChangePack.capabilities` when it
 * can fold a presence patch into the base it holds. Absence means the server does not take patches.
 */
let presencePatchCapability = "presence-patch"

/// The largest presence the server keeps as a patch base, mirroring `maxPresenceBaseSize` on the
/// server. A presence above it is refused by every fold, so patching it only buys a failed round
/// trip.
private let maxPresenceBaseSize = 4 * 1024

/// The per-key cost the server adds on top of the key and value bytes when it measures a presence
/// (`presenceEntryOverhead`).
private let presenceEntryOverhead = 64

/**
 * `PresenceChangeType` represents the type of presence change.
 */
enum PresenceChangeType {
    case put
    case patch
    case clear
}

/**
 * `PresenceChange` is the change of a presence that a ``Change`` carries.
 *
 * A `patch` carries only the top-level keys that changed, so it is cheaper to upload than the whole
 * presence. It is normally produced locally: the server folds each patch into a full `put` before
 * storing, so a pulled pack does not usually carry one. A peer that echoes one back anyway is still
 * decoded rather than failing the whole pack.
 *
 * `full` is the whole presence as of the patch. It never goes on the wire, so only a locally minted
 * patch has it. It is what ``Change/execute(root:presences:source:)`` applies locally and what an
 * `ErrPresenceBaseUnavailable` fallback turns the patch back into. A patch decoded off the wire has
 * none and is merged onto the presence already held for its actor instead.
 */
enum PresenceChange {
    case put(presence: StringValueTypeDictionary)
    case patch(presence: StringValueTypeDictionary, full: StringValueTypeDictionary?)
    case clear
}

/**
 * `Presence` represents a proxy for the Presence to be manipulated from the outside.
 */
public class Presence {
    private var changeContext: ChangeContext
    private(set) var presence: StringValueTypeDictionary

    /// Whether this update may record a patch instead of a full put. The document decides it: the
    /// server has to have advertised `presence-patch` on its last pack and to be holding a base of
    /// ours.
    private let patchable: Bool

    /// The keys recorded by the patch this context holds, if it holds one. Several `set` calls in one
    /// update overwrite each other's presence change, so the keys accumulate here rather than being
    /// taken from the last call alone.
    private var patchedKeys: Set<String>?

    /// Whether this context has already recorded a full put or a `clear`. A context carries at most
    /// one presence change, so a patch recorded after one of those would replace it rather than
    /// follow it, and the server has no base to fold that patch into. Once raised, the rest of the
    /// update stays a full put.
    private var baseless = false

    init(changeContext: ChangeContext, presence: StringValueTypeDictionary, patchable: Bool = false) {
        self.changeContext = changeContext
        self.presence = presence
        self.patchable = patchable
    }

    /**
     * `set` updates the presence based on the partial presence.
     */
    public func set(_ presence: PresenceData) {
        var keys = [String]()
        for (key, value) in presence {
            guard let encoded = value.toJSONString else {
                Logger.warning("Presence.set: dropping key \"\(key)\"; value is not JSON-encodable")
                continue
            }
            self.presence[key] = encoded
            keys.append(key)
        }

        self.record(keys)
    }

    /// Merges already-encoded values into the presence and records the change.
    ///
    /// The counterpart of ``set(_:)`` for values that are already JSON strings, so a presence
    /// read back from a document can be re-applied without a decode/encode round trip.
    ///
    /// - Parameter encoded: The JSON-encoded values, by key.
    func setEncoded(_ encoded: StringValueTypeDictionary) {
        for (key, value) in encoded {
            self.presence[key] = value
        }
        self.record(Array(encoded.keys))
    }

    /// Records the presence change for the keys an update just wrote: a patch of those keys while the
    /// server can fold one, a full put otherwise.
    ///
    /// A patch needs all of: the document says it is patchable, nothing earlier in this update
    /// already recorded a put or a clear, and the whole presence fits the server's base limit.
    /// Anything else falls back to a put, which also stops the rest of the update from patching.
    ///
    /// NOTE(yorkie-js-sdk#1477): the JS SDK also puts when an update removes a key, because a patch
    /// cannot express a deletion. This presence has no way to remove a key (``set(_:)`` only adds or
    /// overwrites, and there is no presence undo), so that fallback has nothing to guard here.
    private func record(_ keys: [String]) {
        if self.patchable, !self.baseless, Self.isCacheable(self.presence) {
            var patchedKeys = self.patchedKeys ?? []
            patchedKeys.formUnion(keys)
            self.patchedKeys = patchedKeys

            let patch = self.presence.filter { patchedKeys.contains($0.key) }
            self.changeContext.presenceChange = .patch(presence: patch, full: self.presence)
        } else {
            self.baseless = true
            self.patchedKeys = nil
            self.changeContext.presenceChange = .put(presence: self.presence)
        }
    }

    /// Reports whether the server would keep the given presence as a patch base.
    ///
    /// Mirrors the server's accounting: the UTF-8 bytes of each key and of its JSON-encoded value,
    /// plus a fixed per-entry overhead. Values are stored JSON-encoded already, so the string is
    /// measured as is. Stops counting as soon as the limit is passed.
    static func isCacheable(_ presence: StringValueTypeDictionary) -> Bool {
        var size = 0
        for (key, value) in presence {
            size += key.utf8.count + value.utf8.count + presenceEntryOverhead
            if size > maxPresenceBaseSize {
                return false
            }
        }
        return true
    }

    /**
     * `get` returns the presence value of the given key.
     */
    public func get<T: Codable>(_ key: PresenceData.Key) -> T? {
        if let data = self.presence[key]?.data(using: .utf8) {
            return try? JSONDecoder().decode(T.self, from: data)
        }

        return nil
    }

    /**
     * `clear` clears the presence.
     */
    func clear() {
        self.presence = [:]
        self.baseless = true
        self.patchedKeys = nil

        let presenceChange = PresenceChange.clear
        self.changeContext.presenceChange = presenceChange
    }
}
