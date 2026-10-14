/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
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

/// Re-issues the tickets of a never-synced document to another actor, going through the wire
/// format so that no per-operation list of ticket fields can silently fall out of date.
///
/// Port of yorkie-js-sdk `api/reissue.ts` (yorkie-js-sdk#1449). See
/// `docs/design/pre-attach-ticket-reissue.md` upstream.
enum Reissue {
    /// Returns copies of `operations` in which every ticket issued by the actor `from` names the
    /// actor `to` instead.
    ///
    /// Lamports and delimiters are kept, so the order among the tickets is unchanged. A ticket with
    /// lamport 0 is never re-issued: that is the initial ticket, the root object's and every
    /// sentinel node's identity, shared by all replicas.
    ///
    /// Each operation goes through ``Converter/toOperation(_:)`` and back on purpose: the walk
    /// reaches every `TimeTicket` the protocol carries -- positions, node ids, split tickets,
    /// restore spans and the elements nested in a Set/Add/ArraySet value -- and the operations come
    /// back as the server would decode them (except a Text value, see ``reissueTextValue(_:decoded:)``).
    ///
    /// Only sound when every ticket naming `from` was issued locally and never left this replica,
    /// which is the case for a document that has never synced.
    ///
    /// - Parameters:
    ///   - operations: The operations to copy.
    ///   - from: The actor whose tickets are rewritten.
    ///   - to: The actor the rewritten tickets name.
    /// - Returns: The re-issued copies. The given operations are not mutated.
    /// - Throws: ``YorkieError`` when an operation cannot be encoded or does not decode back.
    static func reissueOperations(_ operations: [Operation], from: ActorID, to: ActorID) throws -> [Operation] {
        let reissuer = TicketReissuer(from: from, to: to)
        if let failure = reissuer.failure {
            throw failure
        }

        var reissued = [Operation]()
        reissued.reserveCapacity(operations.count)
        for operation in operations {
            // NOTE: the throwing single-operation converter, not `toOperations`, which drops an
            // operation it cannot encode: dropping one here would silently shorten the change.
            var pbOperation = try Converter.toOperation(operation)
            reissuer.walk(&pbOperation)
            if let failure = reissuer.failure {
                throw failure
            }

            let decoded = try Converter.fromOperations([pbOperation])
            guard decoded.count == 1, let decodedOperation = decoded.first else {
                throw YorkieError(
                    code: .errInvalidArgument,
                    message: "reissue operations: \(type(of: operation)) did not decode"
                )
            }

            // The wire drops a Text value's content: it carries the Text alone and the Edits that
            // fill it. A Set/Add/ArraySet that restores a removed Text -- the reverse of a Remove,
            // run by undo -- carries the content, and a later Edit may target its nodes.
            reissued.append(try reissuer.reissueTextValue(operation, decoded: decodedOperation))
        }
        return reissued
    }
}

/// Rewrites the actor of the `TimeTicket`s in a protobuf message.
///
/// swift-protobuf has no mutable reflection, so the walk is written out per message type. Two rules
/// keep it correct:
///
/// - A message field of a generated struct is a computed property: passing `&pb.removedAt` inout
///   *sets* the field's presence even when it was absent. Every optional message field is therefore
///   guarded by its `hasX` before it is touched.
/// - Actor ids are compared as bytes, not as strings, so the comparison does not depend on hex case.
final class TicketReissuer {
    private let from: Data
    private let to: Data

    /// The first error a nested element could not be decoded or re-encoded with, if any. The walk
    /// itself cannot throw, so a caller checks this once it is done: a nested element left unwalked
    /// would keep naming the old actor.
    private(set) var failure: Error?

    init(from: ActorID, to: ActorID) {
        // An actor that is not hex has no byte form. Falling back to empty bytes would rewrite
        // the tickets onto an empty actor, so the failure is recorded for the caller instead.
        let fromData = from.toData
        let toData = to.toData
        self.from = fromData ?? Data()
        self.to = toData ?? Data()
        if fromData == nil || toData == nil {
            self.failure = YorkieError(
                code: .errInvalidArgument,
                message: "reissue operations: actor is not a valid actor id (from: \(from), to: \(to))"
            )
        }
    }

    // MARK: Text value

    /// Returns `decoded` with its Text value replaced by a re-issued copy of the original one,
    /// content included. Any other operation is returned unchanged.
    func reissueTextValue(_ original: Operation, decoded: Operation) throws -> Operation {
        switch (original, decoded) {
        case let (original as SetOperation, decoded as SetOperation):
            guard let text = try self.reissuedText(original.value) else { return decoded }
            return SetOperation(
                key: decoded.key,
                value: text,
                parentCreatedAt: decoded.parentCreatedAt,
                executedAt: decoded.executedAt
            )
        case let (original as AddOperation, decoded as AddOperation):
            guard let text = try self.reissuedText(original.value) else { return decoded }
            return AddOperation(
                parentCreatedAt: decoded.parentCreatedAt,
                previousCreatedAt: decoded.previousCreatedAt,
                value: text,
                executedAt: decoded.executedAt
            )
        case let (original as ArraySetOperation, decoded as ArraySetOperation):
            guard let text = try self.reissuedText(original.getValue()) else { return decoded }
            return ArraySetOperation(
                parentCreatedAt: decoded.parentCreatedAt,
                createdAt: decoded.getCreatedAt(),
                value: text,
                executedAt: decoded.executedAt
            )
        default:
            return decoded
        }
    }

    private func reissuedText(_ value: CRDTElement) throws -> CRDTElement? {
        guard value is CRDTText else {
            return nil
        }

        var pbElement = try Converter.toElement(value)
        self.walk(&pbElement)
        return try Converter.fromElement(pbElement: pbElement)
    }

    // MARK: Ticket

    func walk(_ ticket: inout PbTimeTicket) {
        if ticket.lamport != 0, ticket.actorID == self.from {
            ticket.actorID = self.to
        }
    }

    // MARK: Operation

    func walk(_ operation: inout PbOperation) {
        switch operation.body {
        case .set(var body)?:
            self.walk(&body)
            operation.body = .set(body)
        case .add(var body)?:
            self.walk(&body)
            operation.body = .add(body)
        case .move(var body)?:
            self.walk(&body)
            operation.body = .move(body)
        case .remove(var body)?:
            self.walk(&body)
            operation.body = .remove(body)
        case .edit(var body)?:
            self.walk(&body)
            operation.body = .edit(body)
        case .style(var body)?:
            self.walk(&body)
            operation.body = .style(body)
        case .increase(var body)?:
            self.walk(&body)
            operation.body = .increase(body)
        case .treeEdit(var body)?:
            self.walk(&body)
            operation.body = .treeEdit(body)
        case .treeStyle(var body)?:
            self.walk(&body)
            operation.body = .treeStyle(body)
        case .arraySet(var body)?:
            self.walk(&body)
            operation.body = .arraySet(body)
        case nil:
            break
        }
    }

    private func walk(_ body: inout PbOperation.Set) {
        if body.hasParentCreatedAt { self.walk(&body.parentCreatedAt) }
        if body.hasValue { self.walk(&body.value) }
        if body.hasExecutedAt { self.walk(&body.executedAt) }
    }

    private func walk(_ body: inout PbOperation.Add) {
        if body.hasParentCreatedAt { self.walk(&body.parentCreatedAt) }
        if body.hasPrevCreatedAt { self.walk(&body.prevCreatedAt) }
        if body.hasValue { self.walk(&body.value) }
        if body.hasExecutedAt { self.walk(&body.executedAt) }
    }

    private func walk(_ body: inout PbOperation.Move) {
        if body.hasParentCreatedAt { self.walk(&body.parentCreatedAt) }
        if body.hasPrevCreatedAt { self.walk(&body.prevCreatedAt) }
        if body.hasCreatedAt { self.walk(&body.createdAt) }
        if body.hasExecutedAt { self.walk(&body.executedAt) }
    }

    private func walk(_ body: inout PbOperation.Remove) {
        if body.hasParentCreatedAt { self.walk(&body.parentCreatedAt) }
        if body.hasCreatedAt { self.walk(&body.createdAt) }
        if body.hasExecutedAt { self.walk(&body.executedAt) }
    }

    private func walk(_ body: inout PbOperation.Edit) {
        if body.hasParentCreatedAt { self.walk(&body.parentCreatedAt) }
        if body.hasFrom { self.walk(&body.from) }
        if body.hasTo { self.walk(&body.to) }
        // Map keys are left alone, only the values are walked: the one actor-keyed map, the
        // deprecated `created_at_map_by_actor`, is never written.
        body.createdAtMapByActor = body.createdAtMapByActor.mapValues(self.reissued)
        if body.hasExecutedAt { self.walk(&body.executedAt) }
        body.restoreSpans = body.restoreSpans.map(self.reissued)
        body.retombstoneSpans = body.retombstoneSpans.map(self.reissued)
    }

    private func walk(_ body: inout PbOperation.Style) {
        if body.hasParentCreatedAt { self.walk(&body.parentCreatedAt) }
        if body.hasFrom { self.walk(&body.from) }
        if body.hasTo { self.walk(&body.to) }
        if body.hasExecutedAt { self.walk(&body.executedAt) }
        body.createdAtMapByActor = body.createdAtMapByActor.mapValues(self.reissued)
    }

    private func walk(_ body: inout PbOperation.Increase) {
        if body.hasParentCreatedAt { self.walk(&body.parentCreatedAt) }
        if body.hasValue { self.walk(&body.value) }
        if body.hasExecutedAt { self.walk(&body.executedAt) }
    }

    private func walk(_ body: inout PbOperation.TreeEdit) {
        if body.hasParentCreatedAt { self.walk(&body.parentCreatedAt) }
        if body.hasFrom { self.walk(&body.from) }
        if body.hasTo { self.walk(&body.to) }
        body.createdAtMapByActor = body.createdAtMapByActor.mapValues(self.reissued)
        body.contents = body.contents.map(self.reissued)
        if body.hasExecutedAt { self.walk(&body.executedAt) }
        body.restoreSpans = body.restoreSpans.map(self.reissued)
        body.retombstoneSpans = body.retombstoneSpans.map(self.reissued)
        body.splitTickets = body.splitTickets.map(self.reissued)
    }

    private func walk(_ body: inout PbOperation.TreeStyle) {
        if body.hasParentCreatedAt { self.walk(&body.parentCreatedAt) }
        if body.hasFrom { self.walk(&body.from) }
        if body.hasTo { self.walk(&body.to) }
        if body.hasExecutedAt { self.walk(&body.executedAt) }
        body.createdAtMapByActor = body.createdAtMapByActor.mapValues(self.reissued)
    }

    private func walk(_ body: inout PbOperation.ArraySet) {
        if body.hasParentCreatedAt { self.walk(&body.parentCreatedAt) }
        if body.hasCreatedAt { self.walk(&body.createdAt) }
        if body.hasValue { self.walk(&body.value) }
        if body.hasExecutedAt { self.walk(&body.executedAt) }
    }

    // MARK: Positions, ids and spans

    private func walk(_ pos: inout PbTextNodePos) {
        if pos.hasCreatedAt { self.walk(&pos.createdAt) }
    }

    private func walk(_ id: inout PbTextNodeID) {
        if id.hasCreatedAt { self.walk(&id.createdAt) }
    }

    private func walk(_ id: inout PbTreeNodeID) {
        if id.hasCreatedAt { self.walk(&id.createdAt) }
    }

    private func walk(_ pos: inout PbTreePos) {
        if pos.hasParentID { self.walk(&pos.parentID) }
        if pos.hasLeftSiblingID { self.walk(&pos.leftSiblingID) }
    }

    private func walk(_ span: inout PbRestoreSpan) {
        if span.hasCreatedAt { self.walk(&span.createdAt) }
    }

    private func walk(_ span: inout PbTreeRestoreSpan) {
        if span.hasID { self.walk(&span.id) }
        span.attributes = span.attributes.mapValues(self.reissued)
        if span.hasParentID { self.walk(&span.parentID) }
        if span.hasLeftSiblingID { self.walk(&span.leftSiblingID) }
        if span.hasRightSiblingID { self.walk(&span.rightSiblingID) }
    }

    private func walk(_ attr: inout PbNodeAttr) {
        if attr.hasUpdatedAt { self.walk(&attr.updatedAt) }
    }

    private func walk(_ nodes: inout PbTreeNodes) {
        nodes.content = nodes.content.map(self.reissued)
    }

    // MARK: Elements

    private func walk(_ element: inout PbJSONElementSimple) {
        if element.hasCreatedAt { self.walk(&element.createdAt) }
        if element.hasMovedAt { self.walk(&element.movedAt) }
        if element.hasRemovedAt { self.walk(&element.removedAt) }

        // An Object, Array or Tree travels as the bytes of a JSONElement, out of reach of the
        // field walk: decode, rewrite and re-encode them.
        switch element.type {
        case .jsonObject, .jsonArray, .tree:
            break
        default:
            return
        }
        guard element.value.isEmpty == false else {
            return
        }
        do {
            var nested = try PbJSONElement(serializedBytes: element.value)
            self.walk(&nested)
            element.value = try nested.serializedData()
        } catch {
            self.failure = self.failure ?? error
        }
    }

    func walk(_ element: inout PbJSONElement) {
        switch element.body {
        case .jsonObject(var body)?:
            body.nodes = body.nodes.map(self.reissued)
            self.walkTickets(&body)
            element.body = .jsonObject(body)
        case .jsonArray(var body)?:
            body.nodes = body.nodes.map(self.reissued)
            self.walkTickets(&body)
            element.body = .jsonArray(body)
        case .primitive(var body)?:
            self.walkTickets(&body)
            element.body = .primitive(body)
        case .text(var body)?:
            body.nodes = body.nodes.map(self.reissued)
            self.walkTickets(&body)
            element.body = .text(body)
        case .counter(var body)?:
            self.walkTickets(&body)
            element.body = .counter(body)
        case .tree(var body)?:
            body.nodes = body.nodes.map(self.reissued)
            self.walkTickets(&body)
            element.body = .tree(body)
        case nil:
            break
        }
    }

    /// Walks the four liveness tickets every element body carries, skipping an absent one so its
    /// presence is not set.
    private func walkTickets(_ element: inout some ElementTickets) {
        if element.hasCreatedAt { self.walk(&element.createdAt) }
        if element.hasMovedAt { self.walk(&element.movedAt) }
        if element.hasRemovedAt { self.walk(&element.removedAt) }
        if element.hasRevivedAt { self.walk(&element.revivedAt) }
    }

    private func walk(_ node: inout PbRHTNode) {
        if node.hasElement { self.walk(&node.element) }
    }

    private func walk(_ node: inout PbRGANode) {
        if node.hasNext { self.walk(&node.next) }
        if node.hasElement { self.walk(&node.element) }
        if node.hasPositionCreatedAt { self.walk(&node.positionCreatedAt) }
        if node.hasPositionMovedAt { self.walk(&node.positionMovedAt) }
        if node.hasPositionRemovedAt { self.walk(&node.positionRemovedAt) }
    }

    private func walk(_ node: inout PbTextNode) {
        if node.hasID { self.walk(&node.id) }
        if node.hasRemovedAt { self.walk(&node.removedAt) }
        if node.hasInsPrevID { self.walk(&node.insPrevID) }
        node.attributes = node.attributes.mapValues(self.reissued)
    }

    private func walk(_ node: inout PbTreeNode) {
        if node.hasID { self.walk(&node.id) }
        if node.hasRemovedAt { self.walk(&node.removedAt) }
        if node.hasInsPrevID { self.walk(&node.insPrevID) }
        if node.hasInsNextID { self.walk(&node.insNextID) }
        node.attributes = node.attributes.mapValues(self.reissued)
        if node.hasMergedFrom { self.walk(&node.mergedFrom) }
        if node.hasMergedAt { self.walk(&node.mergedAt) }
    }

    // MARK: Copy helpers

    private func reissued(_ ticket: PbTimeTicket) -> PbTimeTicket {
        var copy = ticket
        self.walk(&copy)
        return copy
    }

    private func reissued(_ span: PbRestoreSpan) -> PbRestoreSpan {
        var copy = span
        self.walk(&copy)
        return copy
    }

    private func reissued(_ span: PbTreeRestoreSpan) -> PbTreeRestoreSpan {
        var copy = span
        self.walk(&copy)
        return copy
    }

    private func reissued(_ attr: PbNodeAttr) -> PbNodeAttr {
        var copy = attr
        self.walk(&copy)
        return copy
    }

    private func reissued(_ nodes: PbTreeNodes) -> PbTreeNodes {
        var copy = nodes
        self.walk(&copy)
        return copy
    }

    private func reissued(_ node: PbTreeNode) -> PbTreeNode {
        var copy = node
        self.walk(&copy)
        return copy
    }

    private func reissued(_ node: PbTextNode) -> PbTextNode {
        var copy = node
        self.walk(&copy)
        return copy
    }

    private func reissued(_ node: PbRHTNode) -> PbRHTNode {
        var copy = node
        self.walk(&copy)
        return copy
    }

    private func reissued(_ node: PbRGANode) -> PbRGANode {
        var copy = node
        self.walk(&copy)
        return copy
    }
}

/// The tickets shared by every `JSONElement` body, so one walk covers all six.
private protocol ElementTickets {
    var createdAt: PbTimeTicket { get set }
    var hasCreatedAt: Bool { get }
    var movedAt: PbTimeTicket { get set }
    var hasMovedAt: Bool { get }
    var removedAt: PbTimeTicket { get set }
    var hasRemovedAt: Bool { get }
    var revivedAt: PbTimeTicket { get set }
    var hasRevivedAt: Bool { get }
}

extension Yorkie_V1_JSONElement.JSONObject: ElementTickets {}
extension Yorkie_V1_JSONElement.JSONArray: ElementTickets {}
extension Yorkie_V1_JSONElement.Primitive: ElementTickets {}
extension Yorkie_V1_JSONElement.Text: ElementTickets {}
extension Yorkie_V1_JSONElement.Counter: ElementTickets {}
extension Yorkie_V1_JSONElement.Tree: ElementTickets {}
