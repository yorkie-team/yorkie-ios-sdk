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
class Change {
    private var id: ChangeID

    // `operations` represent a series of user edits.
    private var operations: [Operation]

    // `message` is used to save a description of the change.
    private let message: String?

    init(id: ChangeID, operations: [Operation], message: String?) {
        self.id = id
        self.operations = operations
        self.message = message
    }

    /**
     * `getID` returns the ID of this change.
     */
    func getID() -> ChangeID {
        return self.id
    }

    /**
     * `getMessage` returns the message of this change.
     */
    func getMessage() -> String? {
        return self.message
    }

    /**
     * `getOperations` returns the operations of this change.
     */
    func getOperations() -> [Operation] {
        return self.operations
    }

    /**
     * `setActor` sets the given actor.
     */
    func setActor(actorID: ActorID) {
        self.operations.forEach {
            $0.setActor(actorID)
        }

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
     * `getStructureAsString` returns a String containing the meta data of this change.
     */
    func getStructureAsString() -> String {
        return self.operations
            .map { $0.getStructureAsString() }
            .joined(separator: ",")
    }
}
