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
    private let message: String?
    private var delimiter: UInt32

    init(id: ChangeID, root: CRDTRoot, message: String? = nil) {
        self.id = id
        self.root = root
        self.message = message
        self.operations = []
        self.delimiter = TimeTicket.Values.initialDelimiter
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
     * `registerRemovedNodeTextElement` register text element has removed node for
     * garbage collection.
     */
    func registerRemovedNodeTextElement(_ text: CRDTTextElement) {
        self.root.registerTextWithGarbage(text: text)
    }

    /**
     * `getChange` creates a new instance of Change in this context.
     */
    func getChange() -> Change {
        return Change(id: self.id, operations: self.operations, message: self.message)
    }

    /**
     * `hasOperations` returns the whether this context has operations or not.
     */
    func hasOperations() -> Bool {
        return self.operations.isEmpty == false
    }

    /**
     * `issueTimeTicket` creates a time ticket to be used to create a new operation.
     */
    func issueTimeTicket() -> TimeTicket {
        self.delimiter += 1
        return self.id.createTimeTicket(delimiter: self.delimiter)
    }
}
