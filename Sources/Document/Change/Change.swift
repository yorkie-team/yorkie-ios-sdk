/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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
 * `Change` represents a unit of modification in the document.
 */
public struct Change {
    /// The ID of this change.
    private(set) var id: ChangeID

    // `operations` represent a series of user edits.
    private(set) var operations: [Operation]

    // `presenceChange` represents the presenceChange of the user who made the change.
    private(set) var presenceChange: PresenceChange?

    // `message` is used to save a description of the change.
    let message: String?

    init(id: ChangeID, operations: [Operation], presenceChange: PresenceChange? = nil, message: String? = nil) {
        self.id = id
        self.operations = operations
        self.presenceChange = presenceChange
        self.message = message
    }

    /**
     * `setActor` sets the given actor.
     */
    mutating func setActor(_ actorID: ActorID) {
        let operations = self.operations.map {
            var new = $0
            new.setActor(actorID)
            return new
        }

        self.operations = operations
        self.id.setActor(actorID)
    }

    /**
     * `execute` executes the operations of this change to the given root.
     */
    @discardableResult
    func execute(root: CRDTRoot, presences: inout [ActorID: PresenceData]) throws -> [any OperationInfo] {
        let opInfos = try self.operations.flatMap {
            try $0.execute(root: root)
        }

        if let actorID = self.id.getActorID() {
            switch self.presenceChange {
            case .put(let presence):
                presences[actorID] = presence
            default:
                presences.removeValue(forKey: actorID)
            }
        }

        return opInfos
    }

    /**
     * `toTestString` returns a String containing the meta data of this change.
     */
    var toTestString: String {
        return self.operations
            .map { $0.toTestString }
            .joined(separator: ",")
    }

    var hasOperations: Bool {
        self.operations.isEmpty == false
    }
}
