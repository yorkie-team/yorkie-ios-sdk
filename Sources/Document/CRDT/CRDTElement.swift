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
protocol CRDTElement: AnyObject {
    var createdAt: TimeTicket { get set }
    var movedAt: TimeTicket? { get set }
    var removedAt: TimeTicket? { get set }

    func toJSON() -> String

    func toSortedJSON() -> String

    func deepcopy() -> CRDTElement
}

extension CRDTElement {
    /**
     * `isRemoved` check if this element was removed.
     */
    func isRemoved() -> Bool {
        return self.removedAt != nil
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

    func equal(_ target: CRDTElement) -> Bool {
        return self.createdAt == target.createdAt && self.movedAt == target.movedAt && self.removedAt == target.removedAt
    }
}

/**
 *
 * `CRDTContainer` represents CRDTArray or CRDtObject.
 */
protocol CRDTContainer: CRDTElement {
    func subPath(createdAt: TimeTicket) throws -> String

    func purge(element: CRDTElement) throws

    func remove(createdAt: TimeTicket, executedAt: TimeTicket) throws -> CRDTElement

    func getDescendants(callback: (_ element: CRDTElement, _ parent: CRDTContainer) -> Bool)
}

/**
 * `CRDTTextElement` represents CRDTText or CRDTRichText.
 */
protocol CRDTTextElement: CRDTElement {
    func getRemovedNodesLen() -> Int

    func purgeTextNodesWithGarbage(ticket: TimeTicket) -> Int
}
