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
 * `PresenceChangeType` represents the type of presence change.
 */
enum PresenceChangeType {
    case put
    case clear
}

enum PresenceChange {
    case put(presence: StringValueTypeDictionary)
    case clear
}

/**
 * `Presence` represents a proxy for the Presence to be manipulated from the outside.
 */
public class Presence {
    private var changeContext: ChangeContext
    private(set) var presence: StringValueTypeDictionary

    init(changeContext: ChangeContext, presence: StringValueTypeDictionary) {
        self.changeContext = changeContext
        self.presence = presence
    }

    /**
     * `set` updates the presence based on the partial presence.
     */
    public func set(_ presence: PresenceData) {
        for (key, value) in presence {
            guard let encoded = value.toJSONString else {
                Logger.warning("Presence.set: dropping key \"\(key)\"; value is not JSON-encodable")
                continue
            }
            self.presence[key] = encoded
        }

        let presenceChange = PresenceChange.put(presence: self.presence)
        self.changeContext.presenceChange = presenceChange
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
        self.changeContext.presenceChange = PresenceChange.put(presence: self.presence)
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

        let presenceChange = PresenceChange.clear
        self.changeContext.presenceChange = presenceChange
    }
}
