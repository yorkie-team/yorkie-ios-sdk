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
 * `HistoryOperation` is a unit stored in the undo/redo stacks. It is either a
 * reverse CRDT operation or a reverse presence change.
 */
enum HistoryOperation {
    case operation(any Operation)
    case presence(StringValueTypeDictionary)
}

/**
 * `maxUndoRedoStackDepth` is the maximum depth of the undo/redo stack.
 */
let maxUndoRedoStackDepth = 50

/**
 * `History` stores the undo/redo history of a ``Document``.
 */
final class History {
    private var undoStack: [[HistoryOperation]] = []
    private var redoStack: [[HistoryOperation]] = []

    /**
     * `hasUndo` returns whether there are undo operations.
     */
    var hasUndo: Bool {
        self.undoStack.isEmpty == false
    }

    /**
     * `hasRedo` returns whether there are redo operations.
     */
    var hasRedo: Bool {
        self.redoStack.isEmpty == false
    }

    /**
     * `pushUndo` pushes the reverse operations of a change to the undo stack.
     */
    func pushUndo(_ undoOps: [HistoryOperation]) {
        if self.undoStack.count >= maxUndoRedoStackDepth {
            self.undoStack.removeFirst()
        }
        self.undoStack.append(undoOps)
    }

    /**
     * `popUndo` pops the last reverse operations of a change from the undo stack.
     */
    func popUndo() -> [HistoryOperation]? {
        self.undoStack.popLast()
    }

    /**
     * `pushRedo` pushes the reverse operations of a change to the redo stack.
     */
    func pushRedo(_ redoOps: [HistoryOperation]) {
        if self.redoStack.count >= maxUndoRedoStackDepth {
            self.redoStack.removeFirst()
        }
        self.redoStack.append(redoOps)
    }

    /**
     * `popRedo` pops the last reverse operations of a change from the redo stack.
     */
    func popRedo() -> [HistoryOperation]? {
        self.redoStack.popLast()
    }

    /**
     * `clearRedo` flushes the remaining redo operations.
     */
    func clearRedo() {
        self.redoStack = []
    }

    /**
     * `clearUndo` flushes the remaining undo operations.
     */
    func clearUndo() {
        self.undoStack = []
    }

    /**
     * `getUndoStackForTest` returns the undo stack for testing.
     */
    func getUndoStackForTest() -> [[HistoryOperation]] {
        self.undoStack
    }

    /**
     * `getRedoStackForTest` returns the redo stack for testing.
     */
    func getRedoStackForTest() -> [[HistoryOperation]] {
        self.redoStack
    }

    /**
     * `reconcileCreatedAt` updates the createdAt and prevCreatedAt fields.
     *
     * When an element is replaced (e.g. UndoRemove as Add, or Set), it receives a new
     * createdAt (executedAt). Existing history operations may still reference the old
     * createdAt or prevCreatedAt, so this scans both stacks and replaces matches.
     */
    func reconcileCreatedAt(prevCreatedAt: TimeTicket, currCreatedAt: TimeTicket) {
        self.replaceCreatedAt(in: &self.undoStack, prevCreatedAt: prevCreatedAt, currCreatedAt: currCreatedAt)
        self.replaceCreatedAt(in: &self.redoStack, prevCreatedAt: prevCreatedAt, currCreatedAt: currCreatedAt)
    }

    /**
     * `reconcileTextEdit` reconciles the range of edit operations on both stacks when a text
     * edit occurs, so a later undo/redo lands at the correct position.
     */
    func reconcileTextEdit(parentCreatedAt: TimeTicket, rangeFrom: Int, rangeTo: Int, contentLength: Int) {
        // NOTE: iterating copies of the stacks is intentional and harmless — `EditOperation` is a
        // class, so `reconcileOperation` mutates the stored instance through its reference.
        for stack in [self.undoStack, self.redoStack] {
            for ops in stack {
                for case .operation(let op) in ops {
                    if let edit = op as? EditOperation, edit.parentCreatedAt == parentCreatedAt {
                        edit.reconcileOperation(rangeFrom, rangeTo, contentLength)
                    }
                }
            }
        }
    }

    private func replaceCreatedAt(in stack: inout [[HistoryOperation]], prevCreatedAt: TimeTicket, currCreatedAt: TimeTicket) {
        for i in stack.indices {
            for j in stack[i].indices {
                guard case .operation(let op) = stack[i][j] else { continue }
                if let reconciled = Self.reconcile(op, prevCreatedAt: prevCreatedAt, currCreatedAt: currCreatedAt) {
                    stack[i][j] = .operation(reconciled)
                }
            }
        }
    }

    /// Returns the operation with its createdAt/prevCreatedAt reconciled, or `nil` if unchanged.
    private static func reconcile(_ op: any Operation, prevCreatedAt: TimeTicket, currCreatedAt: TimeTicket) -> (any Operation)? {
        // `setCreatedAt` for ArraySetOperation / RemoveOperation / MoveOperation.
        // `setPrevCreatedAt` for AddOperation / MoveOperation.
        if let arraySet = op as? ArraySetOperation {
            guard arraySet.getCreatedAt() == prevCreatedAt else { return nil }
            arraySet.setCreatedAt(currCreatedAt) // class: mutated in place
            return arraySet
        }
        if var remove = op as? RemoveOperation {
            guard remove.createdAt == prevCreatedAt else { return nil }
            remove.setCreatedAt(currCreatedAt)
            return remove
        }
        if var move = op as? MoveOperation {
            var mutated = false
            if move.createdAt == prevCreatedAt {
                move.setCreatedAt(currCreatedAt)
                mutated = true
            }
            if move.previousCreatedAt == prevCreatedAt {
                move.setPrevCreatedAt(currCreatedAt)
                mutated = true
            }
            return mutated ? move : nil
        }
        if var add = op as? AddOperation {
            guard add.previousCreatedAt == prevCreatedAt else { return nil }
            add.setPrevCreatedAt(currCreatedAt)
            return add
        }
        return nil
    }
}
