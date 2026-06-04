/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
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

/// `EditOperation` is an operation representing editing Text.
///
/// It is a `class` (reference type) because undo/redo mutates its range in place — `refinePos`
/// remaps the range to the current split chain, and `reconcileOperation` shifts it when remote
/// edits occur while the operation sits on the undo/redo stack.
final class EditOperation: Operation {
    var parentCreatedAt: TimeTicket
    var executedAt: TimeTicket

    /// `fromPos` returns the start point of the editing range.
    private(set) var fromPos: RGATreeSplitPos
    /// `toPos` returns the end point of the editing range.
    private(set) var toPos: RGATreeSplitPos

    /// `content` returns the content of RichEdit.
    private(set) var content: String

    /// `attributes` returns the attributes of this Edit.
    private(set) var attributes: [String: String]?

    /// Whether this operation was produced as the reverse of an edit (i.e. lives on a history stack).
    private let isUndoOp: Bool

    init(
        parentCreatedAt: TimeTicket,
        fromPos: RGATreeSplitPos,
        toPos: RGATreeSplitPos,
        content: String,
        attributes: [String: String]?,
        executedAt: TimeTicket,
        isUndoOp: Bool = false
    ) {
        self.parentCreatedAt = parentCreatedAt
        self.fromPos = fromPos
        self.toPos = toPos
        self.content = content
        self.attributes = attributes
        self.executedAt = executedAt
        self.isUndoOp = isUndoOp
    }

    /**
     * `execute` executes this operation on the given document(`root`).
     */
    @discardableResult
    func execute(
        root: CRDTRoot,
        versionVector: VersionVector? = nil,
        source: OpSource = .local
    ) throws -> ExecutionResult? {
        let parent = root.find(createdAt: self.parentCreatedAt)
        guard let text = parent as? CRDTText else {
            let log: String
            if let parent {
                log = "fail to execute, only Text can execute edit: \(parent)"
            } else {
                log = "fail to find \(self.parentCreatedAt)"
            }
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        // When replaying a reverse edit, the range may reference a split chain that has since
        // changed; refine it back onto the current chain before editing.
        if self.isUndoOp {
            self.fromPos = try text.refinePos(self.fromPos)
            self.toPos = try text.refinePos(self.toPos)
        }

        let (changes, pairs, diff, _, removedValues) = try text.edit(
            (self.fromPos, self.toPos),
            self.content,
            self.executedAt,
            self.attributes,
            versionVector
        )

        let reverseOp = try self.toReverseOperation(removedValues, text.normalizePos(self.fromPos))

        root.acc(diff)

        for pair in pairs {
            root.registerGCPair(pair)
        }

        let path = try root.createPath(createdAt: self.parentCreatedAt)

        let opInfos: [any OperationInfo] = changes.compactMap {
            EditOpInfo(path: path, from: $0.from, to: $0.to, attributes: $0.attributes?.createdDictionary, content: $0.content)
        }

        return ExecutionResult(opInfos: opInfos, reverseOp: reverseOp)
    }

    /// Builds the reverse edit: re-inserts the removed content over the range that this edit's
    /// inserted content now occupies.
    private func toReverseOperation(_ removedValues: [CRDTTextValue], _ fromPos: RGATreeSplitPos) -> Operation {
        let reverseContent = removedValues.isEmpty ? "" : removedValues.map { $0.toString }.joined()

        var reverseAttributes: [String: String]?
        if removedValues.count == 1 {
            let attrs = removedValues[0].getAttributes()
            if !attrs.isEmpty {
                reverseAttributes = attrs.mapValues { $0.value }
            }
        }

        let contentLength = Int32((self.content as NSString).length)
        // executedAt is reassigned just before execution when Document.undo() is called.
        return EditOperation(
            parentCreatedAt: self.parentCreatedAt,
            fromPos: fromPos,
            toPos: RGATreeSplitPos(fromPos.id, fromPos.relativeOffset + contentLength),
            content: reverseContent,
            attributes: reverseAttributes,
            executedAt: TimeTicket.initial,
            isUndoOp: true
        )
    }

    /// `normalizePos` returns the absolute `(from, to)` offsets of this edit's range.
    func normalizePos(_ root: CRDTRoot) throws -> (Int, Int) {
        let parent = root.find(createdAt: self.parentCreatedAt)
        guard let text = parent as? CRDTText else {
            throw YorkieError(code: .errInvalidArgument, message: "only Text can normalize edit")
        }

        let rangeFrom = try text.normalizePos(self.fromPos).relativeOffset
        let rangeTo = try text.normalizePos(self.toPos).relativeOffset
        return (Int(rangeFrom), Int(rangeTo))
    }

    /// `reconcileOperation` shifts this (undo) edit's range when a remote edit changes the text
    /// while the operation is parked on the undo/redo stack, so a later undo lands in the right spot.
    func reconcileOperation(_ remoteFrom: Int, _ remoteTo: Int, _ contentLen: Int) {
        guard self.isUndoOp, remoteFrom <= remoteTo else {
            return
        }

        let remoteRangeLen = remoteTo - remoteFrom
        let localFrom = Int(self.fromPos.relativeOffset)
        let localTo = Int(self.toPos.relativeOffset)

        func apply(_ na: Int, _ nb: Int) {
            self.fromPos = RGATreeSplitPos(self.fromPos.id, Int32(max(0, na)))
            self.toPos = RGATreeSplitPos(self.toPos.id, Int32(max(0, nb)))
        }

        // Case 1: remote edit entirely left of the undo range.
        if remoteTo <= localFrom {
            apply(localFrom - remoteRangeLen + contentLen, localTo - remoteRangeLen + contentLen)
            return
        }
        // Case 2: remote edit entirely right of the undo range.
        if localTo <= remoteFrom {
            return
        }
        // Case 3: undo range contained within the remote range.
        if remoteFrom <= localFrom, localTo <= remoteTo, remoteFrom != remoteTo {
            apply(remoteFrom, remoteFrom)
            return
        }
        // Case 4: remote range contained within the undo range.
        if localFrom <= remoteFrom, remoteTo <= localTo, localFrom != localTo {
            apply(localFrom, localTo - remoteRangeLen + contentLen)
            return
        }
        // Case 5: remote range overlaps the start of the undo range.
        if remoteFrom < localFrom, localFrom < remoteTo, remoteTo < localTo {
            apply(remoteFrom, remoteFrom + (localTo - remoteTo))
            return
        }
        // Case 6: remote range overlaps the end of the undo range.
        if localFrom < remoteFrom, remoteFrom < localTo, localTo < remoteTo {
            apply(localFrom, remoteFrom)
            return
        }
    }

    /**
     * `effectedCreatedAt` returns the creation time of the effected element.
     */
    var effectedCreatedAt: TimeTicket {
        self.parentCreatedAt
    }

    /**
     * `toTestString` returns a string containing the meta data.
     */
    var toTestString: String {
        let parent = self.parentCreatedAt.toTestString
        let fromPos = self.fromPos.toTestString
        let toPos = self.toPos.toTestString
        let content = self.content
        return "\(parent).EDIT(\(fromPos),\(toPos),\(content)"
    }
}
