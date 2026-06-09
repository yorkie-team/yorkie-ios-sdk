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
 * `ChangeExecutionResult` is the result of executing a ``Change``.
 */
struct ChangeExecutionResult {
    /// The operations that were actually executed (skipped operations are excluded).
    let operations: [Operation]
    /// The operation infos describing what was executed.
    let opInfos: [any OperationInfo]
    /// The reverse operations to push onto the undo/redo stack.
    let reverseOps: [HistoryOperation]
}

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
        self.id = self.id.setActor(actorID)
    }

    /**
     * `execute` executes the operations of this change to the given root.
     */
    @discardableResult
    func execute(
        root: CRDTRoot,
        presences: inout [ActorID: StringValueTypeDictionary],
        source: OpSource = .local
    ) throws -> ChangeExecutionResult {
        let versionVector = self.id.getVersionVector()
        var changeOpInfos: [any OperationInfo] = []
        var executedOperations: [Operation] = []
        var reverseOps: [HistoryOperation] = []

        for operation in self.operations {
            // NOTE: a nil result means the operation was skipped during undo/redo
            // (e.g. the target element was already removed).
            guard let result = try operation.execute(root: root, versionVector: versionVector, source: source) else {
                continue
            }
            changeOpInfos.append(contentsOf: result.opInfos)
            executedOperations.append(operation)
            if let reverseOp = result.reverseOp {
                reverseOps.insert(.operation(reverseOp), at: 0)
            }
        }

        if let presenceChange = self.presenceChange, let actorID = self.id.getActorID() {
            switch presenceChange {
            case .put(let presence):
                presences[actorID] = presence
            default:
                presences.removeValue(forKey: actorID)
            }
        }

        return ChangeExecutionResult(operations: executedOperations, opInfos: changeOpInfos, reverseOps: reverseOps)
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
