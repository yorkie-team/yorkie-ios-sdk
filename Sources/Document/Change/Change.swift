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
struct Change {
    /// The ID of this change.
    private(set) var id: ChangeID

    // `operations` represent a series of user edits.
    private(set) var operations: [Operation]

    // `message` is used to save a description of the change.
    let message: String?

    init(id: ChangeID, operations: [Operation], message: String? = nil) {
        self.id = id
        self.operations = operations
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
    func execute(root: CRDTRoot) throws {
        try self.operations.forEach {
            try $0.execute(root: root)
        }
    }

    /**
     * `structureAsString` returns a String containing the meta data of this change.
     */
    var structureAsString: String {
        return self.operations
            .map { $0.structureAsString }
            .joined(separator: ",")
    }
}
