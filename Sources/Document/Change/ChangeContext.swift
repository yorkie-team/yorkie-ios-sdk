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
 * `ChangeContext` is used to record the context of modification when editing
 * a document. Each time we add an operation, a new time ticket is issued.
 * Finally returns a Change after the modification has been completed.
 */
class ChangeContext {
    private let id: ChangeID
    private let root: CRDTRoot
    private var operations: [Operation]
    var presenceChange: PresenceChange?
    private let message: String?
    private var delimiter: UInt32

    init(id: ChangeID, root: CRDTRoot, message: String? = nil) {
        self.id = id
        self.root = root
        self.message = message
        self.operations = []
        self.delimiter = TimeTicket.Values.initialDelimiter
    }

    func deepcopy() -> ChangeContext {
        let clone = ChangeContext(id: self.id, root: self.root.deepcopy(), message: self.message)

        clone.operations = self.operations
        clone.delimiter = self.delimiter

        return clone
    }

    /**
     * `push` pushes the given operation to this context.
     */
    func push(operation: Operation) {
        self.operations.append(operation)
    }

    /**
     * `registerElement` registers the given element to the root.
     */
    func registerElement(_ element: CRDTElement, parent: CRDTContainer) {
        self.root.registerElement(element, parent: parent)
    }

    /**
     * `registerRemovedElement` register removed element for garbage collection.
     */
    func registerRemovedElement(_ element: CRDTElement) {
        self.root.registerRemovedElement(element)
    }

    /**
     * `registerElementHasRemovedNodes` register GC element has removed node for
     * garbage collection.
     */
    func registerElementHasRemovedNodes(_ element: CRDTGCElement) {
        self.root.registerElementHasRemovedNodes(element)
    }

    /**
     * `registerGCPair` registers the given pair to hash table.
     */
    func registerGCPair(_ pair: GCPair) {
        self.root.registerGCPair(pair)
    }

    /**
     * `getChange` creates a new instance of Change in this context.
     */
    func getChange() -> Change {
        return Change(id: self.id, operations: self.operations, presenceChange: self.presenceChange, message: self.message)
    }

    /**
     * `hasChange` returns whether this context has change or not.
     */
    var hasChange: Bool {
        self.operations.isEmpty == false || self.presenceChange != nil
    }

    /**
     * `issueTimeTicket` creates a time ticket to be used to create a new operation.
     */
    var issueTimeTicket: TimeTicket {
        self.delimiter += 1
        return self.id.createTimeTicket(delimiter: self.delimiter)
    }

    /**
     * `letLastTimeTicket` returns the last time ticket issued in this context.
     */
    var lastTimeTicket: TimeTicket {
        self.id.createTimeTicket(delimiter: self.delimiter)
    }
}
