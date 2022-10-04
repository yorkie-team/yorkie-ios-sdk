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
 * `CRDTElement` represents element type containing logical clock.
 */
class CRDTElement {
    private var createdAt: TimeTicket
    private var movedAt: TimeTicket?
    private var removedAt: TimeTicket?

    init(createdAt: TimeTicket) {
        self.createdAt = createdAt
    }

    /**
     * `getCreatedAt` returns the creation time of this element.
     */
    func getCreatedAt() -> TimeTicket {
        return self.createdAt
    }

    /**
     * `getID` returns the creation time of this element.
     */
    func getID() -> TimeTicket {
        return self.createdAt
    }

    /**
     * `getMovedAt` returns the move time of this element.
     */
    func getMovedAt() -> TimeTicket? {
        return self.movedAt
    }

    /**
     * `getRemovedAt` returns the removal time of this element.
     */
    func getRemovedAt() -> TimeTicket? {
        return self.removedAt
    }

    /**
     * `setMovedAt` sets the move time of this element.
     */
    @discardableResult
    func setMovedAt(_ movedAt: TimeTicket?) -> Bool {
        guard let currentMoveAt = self.movedAt else {
            self.movedAt = movedAt
            return true
        }

        if let movedAt = movedAt, movedAt.after(currentMoveAt) {
            self.movedAt = movedAt
            return true
        }

        return false
    }

    /**
     * `setRemovedAt` sets the remove time of this element.
     */
    func setRemovedAt(_ removedAt: TimeTicket?) {
        self.removedAt = removedAt
    }

    /**
     * `remove` removes this element.
     */
    @discardableResult
    func remove(_ removedAt: TimeTicket?) -> Bool {
        guard let removedAt, removedAt.after(self.createdAt) else {
            return false
        }

        if self.removedAt == nil {
            self.removedAt = removedAt
            return true
        }

        if let currentRemovedAt = self.removedAt, removedAt.after(currentRemovedAt) {
            self.removedAt = removedAt
            return true
        }

        return false
    }

    /**
     * `isRemoved` check if this element was removed.
     */
    func isRemoved() -> Bool {
        return self.removedAt != nil
    }

    func toJSON() -> String {
        fatalError("Must be implemented.")
    }

    func toSortedJSON() -> String {
        fatalError("Must be implemented.")
    }

    func deepcopy() -> CRDTElement {
        fatalError("Must be implemented.")
    }
}

extension CRDTElement: Equatable {
    static func == (lhs: CRDTElement, rhs: CRDTElement) -> Bool {
        return lhs.createdAt == rhs.createdAt && lhs.movedAt == rhs.movedAt && lhs.removedAt == rhs.removedAt
    }
}

/**
 *
 * `CRDTContainer` represents CRDTArray or CRDtObject.
 */
class CRDTContainer: CRDTElement {
    func subPath(createdAt: TimeTicket) throws -> String {
        fatalError("Must be implemented.")
    }

    func purge(element: CRDTElement) throws {
        fatalError("Must be implemented.")
    }

    func remove(createdAt: TimeTicket, executedAt: TimeTicket) throws -> CRDTElement {
        fatalError("Must be implemented.")
    }

    func getDescendants(callback: (_ element: CRDTElement, _ parent: CRDTContainer) -> Bool) {
        fatalError("Must be implemented.")
    }
}

/**
 * `CRDTTextElement` represents CRDTText or CRDTRichText.
 */
class CRDTTextElement: CRDTElement {
    func getRemovedNodesLen() -> Int {
        fatalError("Must be implemented.")
    }

    func purgeTextNodesWithGarbage(ticket: TimeTicket) -> Int {
        fatalError("Must be implemented.")
    }
}
