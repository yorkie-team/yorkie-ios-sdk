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
    /// `createdAt` returns the creation time of this element.
    var createdAt: TimeTicket { get }
    /// `movedAt` returns the move time of this element.
    var movedAt: TimeTicket? { get set }
    /// `removedAt` returns the removal time of this element.
    var removedAt: TimeTicket? { get set }

    func toJSON() -> String

    func toSortedJSON() -> String

    func deepcopy() -> CRDTElement
}

extension CRDTElement {
    /**
     * `isRemoved` check if this element was removed.
     */
    var isRemoved: Bool {
        return self.removedAt != nil
    }

    /**
     * `id` returns the creation time of this element.
     */
    var id: TimeTicket {
        return self.createdAt
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

    func equals(_ target: CRDTElement) -> Bool {
        return self.createdAt == target.createdAt && self.movedAt == target.movedAt && self.removedAt == target.removedAt
    }
}

/**
 *
 * `CRDTContainer` represents CRDTArray or CRDtObject.
 */
protocol CRDTContainer: CRDTElement {
    func subPath(createdAt: TimeTicket) throws -> String

    func delete(element: CRDTElement) throws

    func remove(createdAt: TimeTicket, executedAt: TimeTicket) throws -> CRDTElement

    func getDescendants(callback: (_ element: CRDTElement, _ parent: CRDTContainer?) -> Bool)
}

/**
 * `CRDTTextElement` represents CRDTText or CRDTRichText.
 */
protocol CRDTTextElement: CRDTElement {
    var removedNodesLength: Int { get }

    func purgeTextNodesWithGarbage(ticket: TimeTicket) -> Int
}
