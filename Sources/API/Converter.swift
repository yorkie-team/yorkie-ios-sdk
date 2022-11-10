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

enum Converter {

    /**
     * parses the given bytes into value.
     */
    static func valueFrom(_ valueType: PbValueType, data: Data) throws -> PrimitiveValue {
        switch valueType {
        case .null:
            return .null
        case .boolean:
            return .boolean(data[0] == 1)
        case .integer:
            let result = Int32(bigEndian: data.withUnsafeBytes { $0.load(as: Int32.self) })
            return .integer(result)
        case .double:
            let result = Double(bitPattern: UInt64(bigEndian: data.withUnsafeBytes { $0.load(as: UInt64.self) }))
            return .double(result)
        case .string:
            return .string(String(decoding: data, as: UTF8.self))
        case .long:
            let result = Int64(bigEndian: data.withUnsafeBytes { $0.load(as: Int64.self) })
            return .long(result)
        case .bytes:
            return .bytes(data)
        case .date:
            let milliseconds = Int(bigEndian: data.withUnsafeBytes { $0.load(as: Int.self) })
            return .date(Date(timeIntervalSince1970: TimeInterval(Double(milliseconds) / 1000)))
        default:
            throw YorkieError.unimplemented(message: String(describing: valueType))
        }
    }

    /**
     * `toValueType` converts the given model to Protobuf format.
     */
    static func toValueType(_ valueType: PrimitiveValue) -> PbValueType {
        switch valueType {
        case .null:
            return .null
        case .boolean:
            return .boolean
        case .integer:
            return .integer
        case .long:
            return .long
        case .double:
            return .double
        case .string:
            return .string
        case .bytes:
            return .bytes
        case .date:
            return .date
        }
    }

    /**
     * `fromValueType` converts the given Protobuf format to model format.
     */
    // TODO: Unused code?
    /*
    static func fromValueType(pbValueType: PbValueType) ->PrimitiveValue {
        switch (pbValueType) {
        case .null:
            return .null
        case .boolean:
            return .boolean
        case PbValueType.VALUE_TYPE_INTEGER:
            return PrimitiveType.Integer;
        case PbValueType.VALUE_TYPE_LONG:
            return PrimitiveType.Long;
        case PbValueType.VALUE_TYPE_DOUBLE:
            return PrimitiveType.Double;
        case PbValueType.VALUE_TYPE_STRING:
            return PrimitiveType.String;
        case PbValueType.VALUE_TYPE_BYTES:
            return PrimitiveType.Bytes;
        case PbValueType.VALUE_TYPE_DATE:
            return PrimitiveType.Date;
        }
        throw new YorkieError(
            Code.Unimplemented,
            `unimplemented value type: ${pbValueType}`,
        );
    }
     */
}

// MARK: Presence
extension Converter {
    /**
     * `fromPresence` converts the given Protobuf format to model format.
     */
    static func fromPresence(pbPresence: PbPresence) -> PresenceInfo {
        var data = [String: Any]()

        pbPresence.data.forEach { (key, value) in
            if let dataValue = value.data(using: .utf8), let jsonValue = try? JSONSerialization.jsonObject(with: dataValue) {
                data[key] = jsonValue
            } else {
                if value.first == "\"" && value.last == "\"" {
                    data[key] = value.substring(from: 1, to: value.count - 2)
                } else {
                    if let intValue = Int(value) {
                        data[key] = intValue
                    } else if let doubleValue = Double(value) {
                        data[key] = doubleValue
                    } else if "\(true)" == value.lowercased() {
                        data[key] = true
                    } else if "\(false)" == value.lowercased() {
                        data[key] = false
                    } else {
                        assertionFailure("Invalid Presence Value [\(key)]:[\(value)")
                    }
                }
            }
        }

        return PresenceInfo(clock: pbPresence.clock, data: data)
    }

    /**
     * `toClient` converts the given model to Protobuf format.
     */
    static func toClient(id: String, presence: PresenceInfo) -> PbClient {
        var pbPresence = PbPresence()
        pbPresence.clock = presence.clock

       presence.data.forEach { (key, value) in
            if JSONSerialization.isValidJSONObject(value), let jsonData = try? JSONSerialization.data(withJSONObject: value) {
                pbPresence.data[key] = String(bytes: jsonData, encoding: .utf8)
            } else {
                // emulate JSON.stringfy() in JavaScript.
                pbPresence.data[key] = value is String ? "\"\(value)\"" : "\(value)"
            }
        }

        var pbClient = PbClient()
        pbClient.id = id.toData ?? Data()
        pbClient.presence = pbPresence
        return pbClient
    }
}

// MARK: Checkpoint
extension Converter {
    /**
     * `toCheckpoint` converts the given model to Protobuf format.
     */
    static func toCheckpoint(_ checkpoint: Checkpoint) -> PbCheckpoint {
        var pbCheckpoint = PbCheckpoint()
        pbCheckpoint.serverSeq = checkpoint.getServerSeq()
        pbCheckpoint.clientSeq = checkpoint.getClientSeq()
        return pbCheckpoint
    }

    /**
     * `fromCheckpoint` converts the given Protobuf format to model format.
     */
    static func fromCheckpoint(_ pbCheckpoint: PbCheckpoint) -> Checkpoint {
        Checkpoint(serverSeq: pbCheckpoint.serverSeq, clientSeq: pbCheckpoint.clientSeq)
    }
}

// MARK: ChangeID
extension Converter {
    /**
     * `toChangeID` converts the given model to Protobuf format.
     */
    static func toChangeID(_ changeID: ChangeID) -> PbChangeID {
        var pbChangeID = PbChangeID()
        pbChangeID.clientSeq = changeID.getClientSeq()
        pbChangeID.lamport = changeID.getLamport()
        pbChangeID.actorID = changeID.getActorID()?.toData ?? Data()
        return pbChangeID
    }

    /**
     * `fromChangeID` converts the given Protobuf format to model format.
     */
    static func fromChangeID(_ pbChangeID: PbChangeID) -> ChangeID {
        ChangeID(clientSeq: pbChangeID.clientSeq,
                 lamport: pbChangeID.lamport,
                 actor: pbChangeID.actorID.toHexString)
    }
}

// MARK: TimeTicket
extension Converter {
    /**
     * `toTimeTicket` converts the given model to Protobuf format.
     */
    static func toTimeTicket(_ ticket: TimeTicket) -> PbTimeTicket {
        var pbTimeTicket = PbTimeTicket()
        pbTimeTicket.lamport = ticket.getLamport()
        pbTimeTicket.delimiter = ticket.getDelimiter()
        pbTimeTicket.actorID = ticket.getActorID()?.toData ?? Data()
        return pbTimeTicket
    }

    /**
     * `fromTimeTicket` converts the given Protobuf format to model format.
     */
    static func fromTimeTicket(_ pbTimeTicket: PbTimeTicket) -> TimeTicket {
        TimeTicket(lamport: pbTimeTicket.lamport,
                   delimiter: pbTimeTicket.delimiter,
                   actorID: pbTimeTicket.actorID.isEmpty ? nil : pbTimeTicket.actorID.toHexString)
    }
}

// MARK: CounterType
extension Converter {
    /**
     * `toCounterType` converts the given model to Protobuf format.
     */
    // TODO: CounterType is not implemented.
//    static func toCounterType(valueType: CounterType) -> PbValueType {
//        switch (valueType) {
//        case CounterType.IntegerCnt:
//            return .integerCnt
//        case CounterType.LongCnt:
//            return .longCnt
//        case CounterType.DoubleCnt:
//            return .doubleCnt
//        default:
//            throw new YorkieError(Code.Unsupported, `unsupported type: ${valueType}`);
//        }
//    }
}

// MARK: ElementSimple
extension Converter {
    /**
     * `toElementSimple` converts the given model to Protobuf format.
     */
    static func toElementSimple(_ element: CRDTElement) throws -> PbJSONElementSimple {
        var pbElementSimple = PbJSONElementSimple()

        if element is CRDTObject {
            pbElementSimple.type = .jsonObject
        } else if element is CRDTArray {
            pbElementSimple.type = .jsonArray
//        } else if let element = element as? CRDTText {
//            pbElementSimple.setType(PbValueType.VALUE_TYPE_TEXT);
//            pbElementSimple.setCreatedAt(toTimeTicket(element.createdAt));
//        } else if let element = element as? CRDTRichText {
//            pbElementSimple.setType(PbValueType.VALUE_TYPE_RICH_TEXT);
//            pbElementSimple.setCreatedAt(toTimeTicket(element.createdAt));
        } else if let element = element as? Primitive {
            let primitive = element.value
            pbElementSimple.type = toValueType(primitive)
            pbElementSimple.value = element.toBytes()
//        } else if let element = element as CRDTCounter {
//            const counter = element as CRDTCounter;
//            pbElementSimple.setType(toCounterType(counter.getType()));
//            pbElementSimple.setCreatedAt(toTimeTicket(element.createdAt));
//            pbElementSimple.setValue(element.toBytes());
        } else {
            throw YorkieError.unimplemented(message: "unimplemented element: \(element)")
        }

        pbElementSimple.createdAt = toTimeTicket(element.createdAt)

        return pbElementSimple
    }

    /**
     * `fromElementSimple` converts the given Protobuf format to model format.
     */
    static func fromElementSimple(pbElementSimple: PbJSONElementSimple) throws -> CRDTElement {
        switch pbElementSimple.type {
        case .jsonObject:
            return CRDTObject(createdAt: fromTimeTicket(pbElementSimple.createdAt))
        case .jsonArray:
            return CRDTArray(createdAt: fromTimeTicket(pbElementSimple.createdAt))
        case .text:
            // TODO: CRDTText is not implemented!
            throw YorkieError.unimplemented(message: "unimplemented element: \(pbElementSimple)")
//            return CRDTText.create(
//                RGATreeSplit.create(),
//                fromTimeTicket(pbElementSimple.createdAt)!,
//            );
        case .richText:
            // TODO: CRDTRichText is not implemented!
            throw YorkieError.unimplemented(message: "unimplemented element: \(pbElementSimple)")
//            return new CRDTRichText(
//                RGATreeSplit.create(),
//                fromTimeTicket(pbElementSimple.createdAt)!,
//            );
        case .null, .boolean, .integer, .long, .double, .string, .bytes, .date:
            return Primitive(value: try valueFrom(pbElementSimple.type, data: pbElementSimple.value), createdAt: fromTimeTicket(pbElementSimple.createdAt))
        case .integerCnt, .doubleCnt, .longCnt:
            // TODO: CRDTCounter is not implemented!
            throw YorkieError.unimplemented(message: "unimplemented element: \(pbElementSimple)")
//            return CRDTCounter.of(
//                CRDTCounter.valueFromBytes(
//                    fromCounterType(pbElementSimple.getType()),
//                    pbElementSimple.getValue_asU8(),
//                ),
//                fromTimeTicket(pbElementSimple.createdAt)!,
//            );
        default:
            throw YorkieError.unimplemented(message: "unimplemented element: \(pbElementSimple)")
        }
    }
}
// MARK: TextNodeID
extension Converter {
    /**
     * `toTextNodeID` converts the given model to Protobuf format.
     */
    // TODO: RGATreeSplitNodeID is not implemented!
//    static func toTextNodeID(id: RGATreeSplitNodeID) -> PbTextNodeID {
//        const pbTextNodeID = new PbTextNodeID();
//        pbTextNodeID.setCreatedAt(toTimeTicket(id.createdAt));
//        pbTextNodeID.setOffset(id.getOffset());
//        return pbTextNodeID;
//    }

    /**
     * `fromTextNodeID` converts the given Protobuf format to model format.
     */
//    function fromTextNodeID(pbTextNodeID: PbTextNodeID): RGATreeSplitNodeID {
//      return RGATreeSplitNodeID.of(
//        fromTimeTicket(pbTextNodeID.createdAt)!,
//        pbTextNodeID.getOffset(),
//      );
//    }
}

// MARK: TextNodePos
extension Converter {
    /**
     * `toTextNodePos` converts the given model to Protobuf format.
     */
    // TODO: RGATreeSplitNodePos is not implemented!
//    static func toTextNodePos(pos: RGATreeSplitNodePos) -> PbTextNodePos {
//        const pbTextNodePos = new PbTextNodePos();
//        pbTextNodePos.setCreatedAt(toTimeTicket(pos.id.createdAt));
//        pbTextNodePos.setOffset(pos.id.getOffset());
//        pbTextNodePos.setRelativeOffset(pos.getRelativeOffset());
//        return pbTextNodePos;
//    }

    /**
     * `fromTextNodePos` converts the given Protobuf format to model format.
     */
//    function fromTextNodePos(pbTextNodePos: PbTextNodePos): RGATreeSplitNodePos {
//      return RGATreeSplitNodePos.of(
//        RGATreeSplitNodeID.of(
//          fromTimeTicket(pbTextNodePos.createdAt)!,
//          pbTextNodePos.getOffset(),
//        ),
//        pbTextNodePos.getRelativeOffset(),
//      );
//    }
}

// MARK: Operation
extension Converter {
    /**
     * `toOperation` converts the given model to Protobuf format.
     */
    static func toOperation(_ operation: Operation) throws -> PbOperation {
        var pbOperation = PbOperation()

        if let setOperation = operation as? SetOperation {
            var pbSetOperation = PbOperation.Set()
            pbSetOperation.parentCreatedAt = toTimeTicket(setOperation.parentCreatedAt)
            pbSetOperation.key = setOperation.key
            // TODO: Remove try!
            pbSetOperation.value = try! toElementSimple(setOperation.value)
            pbSetOperation.executedAt = toTimeTicket(setOperation.executedAt)
            pbOperation.set = pbSetOperation
        } else if let addOperation = operation as? AddOperation {
            var pbAddOperation = PbOperation.Add()
            pbAddOperation.parentCreatedAt = toTimeTicket(addOperation.parentCreatedAt)
            pbAddOperation.prevCreatedAt = toTimeTicket(addOperation.previousCreatedAt)
            // TODO: Remove try!
            pbAddOperation.value = try! toElementSimple(addOperation.value)
            pbAddOperation.executedAt = toTimeTicket(addOperation.executedAt)
            pbOperation.add = pbAddOperation
        } else if let moveOperation = operation as? MoveOperation {
            var pbMoveOperation = PbOperation.Move()
            pbMoveOperation.parentCreatedAt = toTimeTicket(moveOperation.parentCreatedAt)
            pbMoveOperation.prevCreatedAt = toTimeTicket(moveOperation.previousCreatedAt)
            pbMoveOperation.createdAt = toTimeTicket(moveOperation.createdAt)
            pbMoveOperation.executedAt = toTimeTicket(moveOperation.executedAt)
            pbOperation.move = pbMoveOperation
        } else if let removeOperation = operation as? RemoveOperation {
            var pbRemoveOperation = PbOperation.Remove()
            pbRemoveOperation.parentCreatedAt = toTimeTicket(removeOperation.parentCreatedAt)
            pbRemoveOperation.createdAt = toTimeTicket(removeOperation.createdAt)
            pbRemoveOperation.executedAt =  toTimeTicket(removeOperation.executedAt)
            pbOperation.remove = pbRemoveOperation
            // TODO: EditOperaion is not implemented!
//        } else if let editOperation = operation as? EditOperation {
//            const pbEditOperation = new PbOperation.Edit();
//            pbEditOperation.setParentCreatedAt(
//                toTimeTicket(editOperation.parentCreatedAt),
//            );
//            pbEditOperation.setFrom(toTextNodePos(editOperation.getFromPos()));
//            pbEditOperation.setTo(toTextNodePos(editOperation.getToPos()));
//            const pbCreatedAtMapByActor = pbEditOperation.getCreatedAtMapByActorMap();
//            for (const [key, value] of editOperation.getMaxCreatedAtMapByActor()) {
//                pbCreatedAtMapByActor.set(key, toTimeTicket(value)!);
//            }
//            pbEditOperation.setContent(editOperation.getContent());
//            pbEditOperation.setExecutedAt(toTimeTicket(editOperation.executedAt));
//            pbOperation.setEdit(pbEditOperation);
            // TODO: SelectOperation is not implemented!
//        } else if let selectOperaion = operation as? SelectOperation {
//            const pbSelectOperation = new PbOperation.Select();
//            pbSelectOperation.setParentCreatedAt(
//                toTimeTicket(selectOperation.parentCreatedAt),
//            );
//            pbSelectOperation.setFrom(toTextNodePos(selectOperation.getFromPos()));
//            pbSelectOperation.setTo(toTextNodePos(selectOperation.getToPos()));
//            pbSelectOperation.setExecutedAt(
//                toTimeTicket(selectOperation.executedAt),
//            );
//            pbOperation.setSelect(pbSelectOperation);
            // TODO: RichEditOperation is not implemented!
//        } else if let richEditOperation = operation as? RichEditOperation {
//            const pbRichEditOperation = new PbOperation.RichEdit();
//            pbRichEditOperation.setParentCreatedAt(
//                toTimeTicket(richEditOperation.parentCreatedAt),
//            );
//            pbRichEditOperation.setFrom(toTextNodePos(richEditOperation.getFromPos()));
//            pbRichEditOperation.setTo(toTextNodePos(richEditOperation.getToPos()));
//            const pbCreatedAtMapByActor =
//            pbRichEditOperation.getCreatedAtMapByActorMap();
//            for (const [key, value] of richEditOperation.getMaxCreatedAtMapByActor()) {
//                pbCreatedAtMapByActor.set(key, toTimeTicket(value)!);
//            }
//            pbRichEditOperation.setContent(richEditOperation.getContent());
//            const pbAttributes = pbRichEditOperation.getAttributesMap();
//            for (const [key, value] of richEditOperation.getAttributes()) {
//                pbAttributes.set(key, value);
//            }
//            pbRichEditOperation.setExecutedAt(
//                toTimeTicket(richEditOperation.executedAt),
//            );
//            pbOperation.setRichEdit(pbRichEditOperation);
            // TODO: StyleOperation is not implemented!
//        } else if let styleOperation = operation as? StyleOperation {
//            const pbStyleOperation = new PbOperation.Style();
//            pbStyleOperation.setParentCreatedAt(
//                toTimeTicket(styleOperation.parentCreatedAt),
//            );
//            pbStyleOperation.setFrom(toTextNodePos(styleOperation.getFromPos()));
//            pbStyleOperation.setTo(toTextNodePos(styleOperation.getToPos()));
//            const pbAttributes = pbStyleOperation.getAttributesMap();
//            for (const [key, value] of styleOperation.getAttributes()) {
//                pbAttributes.set(key, value);
//            }
//            pbStyleOperation.setExecutedAt(
//                toTimeTicket(styleOperation.executedAt),
//            );
//            pbOperation.setStyle(pbStyleOperation);
            // TODO: IncreaseOperation is not implemented!
//        } else if let increaseOperation = operation as? IncreaseOperation {
//            const pbIncreaseOperation = new PbOperation.Increase();
//            pbIncreaseOperation.setParentCreatedAt(
//                toTimeTicket(increaseOperation.parentCreatedAt),
//            );
//            pbIncreaseOperation.setValue(toElementSimple(increaseOperation.value));
//            pbIncreaseOperation.setExecutedAt(
//                toTimeTicket(increaseOperation.executedAt),
//            );
//            pbOperation.setIncrease(pbIncreaseOperation);
        } else {
            throw YorkieError.unimplemented(message: "unimplemented operation \(operation)")
        }

        return pbOperation
    }

    /**
     * `toOperations` converts the given model to Protobuf format.
     */
    static func toOperations(_ operations: [Operation]) -> [PbOperation] {
        operations.compactMap { try? toOperation($0) }
    }

    /**
     * `fromOperations` converts the given Protobuf format to model format.
     */
    static func fromOperations(_ pbOperations: [PbOperation]) throws -> [Operation] {
        try pbOperations.compactMap { pbOperation in
            if case let .set(pbSetOperation) = pbOperation.body {
                return SetOperation(key: pbSetOperation.key,
                                    value: try fromElementSimple(pbElementSimple: pbSetOperation.value),
                                    parentCreatedAt: fromTimeTicket(pbSetOperation.parentCreatedAt),
                                    executedAt: fromTimeTicket(pbSetOperation.executedAt))
            } else if case let .add(pbAddOperation) = pbOperation.body {
                return AddOperation(parentCreatedAt: fromTimeTicket(pbAddOperation.parentCreatedAt),
                                    previousCreatedAt: fromTimeTicket(pbAddOperation.prevCreatedAt),
                                    value: try fromElementSimple(pbElementSimple: pbAddOperation.value),
                                    executedAt: fromTimeTicket(pbAddOperation.executedAt))
            } else if case let .move(pbMoveOperation) = pbOperation.body {
                return MoveOperation(parentCreatedAt: fromTimeTicket(pbMoveOperation.parentCreatedAt),
                                     previousCreatedAt: fromTimeTicket(pbMoveOperation.prevCreatedAt),
                                     createdAt: fromTimeTicket(pbMoveOperation.createdAt),
                                     executedAt: fromTimeTicket(pbMoveOperation.executedAt))
            } else if case let .remove(pbRemoveOperation) = pbOperation.body {
                return RemoveOperation(parentCreatedAt: fromTimeTicket(pbRemoveOperation.parentCreatedAt),
                                       createdAt: fromTimeTicket(pbRemoveOperation.createdAt),
                                       executedAt: fromTimeTicket(pbRemoveOperation.executedAt))
            } else if case let .edit(pbEditOperation) = pbOperation.body {
                // TODO: EditOperation is not implemented!
                throw YorkieError.unimplemented(message: "unimplemented operation \(pbOperation)")
                //                let createdAtMapByActor = pbEditOperation.createdAtMapByActor.map { (key, value) in
                //                    fromTimeTicket(value)
                //                }
                //                operation = EditOperation.create(
                //                    fromTimeTicket(pbEditOperation!.parentCreatedAt)!,
                //                    fromTextNodePos(pbEditOperation!.getFrom()!),
                //                    fromTextNodePos(pbEditOperation!.getTo()!),
                //                    createdAtMapByActor,
                //                    pbEditOperation!.getContent(),
                //                    fromTimeTicket(pbEditOperation!.executedAt)!,
                //                );
            } else if case let .select(pbSelectOperation) = pbOperation.body {
                // TODO: SelectOperation is not implemented!
                throw YorkieError.unimplemented(message: "unimplemented operation \(pbOperation)")
                //                operation = SelectOperation.create(
                //                    fromTimeTicket(pbSelectOperation!.parentCreatedAt)!,
                //                    fromTextNodePos(pbSelectOperation!.getFrom()!),
                //                    fromTextNodePos(pbSelectOperation!.getTo()!),
                //                    fromTimeTicket(pbSelectOperation!.executedAt)!,
                //                );
            } else if case let .richEdit(pbEditOperation) = pbOperation.body {
                // TODO: RichEditOperation is not implemented!
                throw YorkieError.unimplemented(message: "unimplemented operation \(pbOperation)")
                //                const createdAtMapByActor = new Map();
                //                pbEditOperation!.getCreatedAtMapByActorMap().forEach((value, key) => {
                //                    createdAtMapByActor.set(key, fromTimeTicket(value));
                //                });
                //                const attributes = new Map();
                //                pbEditOperation!.getAttributesMap().forEach((value, key) => {
                //                    attributes.set(key, value);
                //                });
                //                operation = RichEditOperation.create(
                //                    fromTimeTicket(pbEditOperation!.parentCreatedAt)!,
                //                    fromTextNodePos(pbEditOperation!.getFrom()!),
                //                    fromTextNodePos(pbEditOperation!.getTo()!),
                //                    createdAtMapByActor,
                //                    pbEditOperation!.getContent(),
                //                    attributes,
                //                    fromTimeTicket(pbEditOperation!.executedAt)!,
                //                );
            } else if case let .style(pbStyleOperation) = pbOperation.body {
                // TODO: StyleOperation is not implemented!
                throw YorkieError.unimplemented(message: "unimplemented operation \(pbOperation)")
                //                const attributes = new Map();
                //                pbStyleOperation!.getAttributesMap().forEach((value, key) => {
                //                    attributes.set(key, value);
                //                });
                //                operation = StyleOperation.create(
                //                    fromTimeTicket(pbStyleOperation!.parentCreatedAt)!,
                //                    fromTextNodePos(pbStyleOperation!.getFrom()!),
                //                    fromTextNodePos(pbStyleOperation!.getTo()!),
                //                    attributes,
                //                    fromTimeTicket(pbStyleOperation!.executedAt)!,
                //                );
            } else if case let .increase(pbIncreaseOperation) = pbOperation.body {
                // TODO: IncreaseOperation is not implemented!
                throw YorkieError.unimplemented(message: "unimplemented operation \(pbOperation)")
                //                operation = IncreaseOperation.create(
                //                    fromTimeTicket(pbIncreaseOperation!.parentCreatedAt)!,
                //                    fromElementSimple(pbIncreaseOperation!.value!),
                //                    fromTimeTicket(pbIncreaseOperation!.executedAt)!,
                //                );
            } else {
                throw YorkieError.unimplemented(message: "unimplemented operation \(pbOperation)")
            }
        }
    }
}

// MARK: RHTNode
extension Converter {
    /**
     * `toRHTNodes` converts the given model to Protobuf format.
     */
    static func toRHTNodes(rht: RHTPQMap) -> [PbRHTNode] {
        rht.compactMap {
            guard let element = try? toElement($0.rhtValue) else {
                return nil
            }

            var pbRHTNode = PbRHTNode()
            pbRHTNode.key = $0.rhtKey
            pbRHTNode.element = element

            return pbRHTNode
        }
    }
}

// MARK: RGNNodes
extension Converter {
    /**
     * `toRGANodes` converts the given model to Protobuf format.
     */
    static func toRGANodes(_ rgaTreeList: RGATreeList) -> [PbRGANode] {
        rgaTreeList.compactMap {
            guard let element = try? toElement($0.value) else {
                return nil
            }

            var pbRGANode = PbRGANode()
            pbRGANode.element = element

            return pbRGANode
        }
    }
}

// MARK: JSONElement
extension Converter {
    /**
     * `toObject` converts the given model to Protobuf format.
     */
    static func toObject(_ obj: CRDTObject) -> PbJSONElement {
        var pbObject = PbJSONElement.JSONObject()
        pbObject.nodes = toRHTNodes(rht: obj.rht)
        pbObject.createdAt = toTimeTicket(obj.createdAt)
        if let ticket = obj.movedAt {
            pbObject.movedAt = toTimeTicket(ticket)
        } else {
            pbObject.clearMovedAt()
        }
        if let ticket = obj.removedAt {
            pbObject.removedAt = toTimeTicket(ticket)
        } else {
            pbObject.clearRemovedAt()
        }

        var pbElement = PbJSONElement()
        pbElement.jsonObject = pbObject
        return pbElement
    }

    /**
     * `fromObject` converts the given Protobuf format to model format.
     */
    static func fromObject(_ pbObject: PbJSONElement.JSONObject) throws -> CRDTObject {
        let rht = RHTPQMap()
        try pbObject.nodes.forEach { pbRHTNode in
            rht.set(key: pbRHTNode.key, value: try fromElement(pbElement: pbRHTNode.element))
        }

        let obj = CRDTObject(createdAt: fromTimeTicket(pbObject.createdAt), memberNodes: rht)
        obj.movedAt = pbObject.hasMovedAt ? fromTimeTicket(pbObject.movedAt) : nil
        obj.removedAt = pbObject.hasRemovedAt ? fromTimeTicket(pbObject.removedAt) : nil
        return obj
    }

    /**
     * `toArray` converts the given model to Protobuf format.
     */
    static func toArray(_ arr: CRDTArray) -> PbJSONElement {
        var pbArray = PbJSONElement.JSONArray()
        pbArray.nodes = toRGANodes(arr.getElements())
        pbArray.createdAt = toTimeTicket(arr.createdAt)
        if let ticket = arr.movedAt {
            pbArray.movedAt = toTimeTicket(ticket)
        } else {
            pbArray.clearMovedAt()
        }
        if let ticket = arr.removedAt {
            pbArray.removedAt = toTimeTicket(ticket)
        } else {
            pbArray.clearRemovedAt()
        }

        var pbElement = PbJSONElement()
        pbElement.jsonArray = pbArray
        return pbElement
    }

    /**
     * `fromArray` converts the given Protobuf format to model format.
     */
    static func fromArray(_ pbArray: PbJSONElement.JSONArray) throws -> CRDTArray {
        let rgaTreeList = RGATreeList()
        try pbArray.nodes.forEach { pbRGANode in
            try rgaTreeList.insert(fromElement(pbElement: pbRGANode.element))
        }

        let arr = CRDTArray(createdAt: fromTimeTicket(pbArray.createdAt), elements: rgaTreeList)
        arr.movedAt = pbArray.hasMovedAt ? fromTimeTicket(pbArray.movedAt) : nil
        arr.removedAt = pbArray.hasRemovedAt ? fromTimeTicket(pbArray.removedAt) : nil
        return arr
    }

    /**
     * `toPrimitive` converts the given model to Protobuf format.
     */
    static func toPrimitive(_ primitive: Primitive) -> PbJSONElement {
        var pbPrimitive = PbJSONElement.Primitive()
        pbPrimitive.type = toValueType(primitive.value)
        pbPrimitive.value = primitive.toBytes()
        pbPrimitive.createdAt = toTimeTicket(primitive.createdAt)
        if let ticket = primitive.movedAt {
            pbPrimitive.movedAt = toTimeTicket(ticket)
        } else {
            pbPrimitive.clearMovedAt()
        }
        if let ticket = primitive.removedAt {
            pbPrimitive.removedAt = toTimeTicket(ticket)
        } else {
            pbPrimitive.clearRemovedAt()
        }

        var pbElement = PbJSONElement()
        pbElement.primitive = pbPrimitive
        return pbElement
    }

    /**
     * `fromPrimitive` converts the given Protobuf format to model format.
     */
    static func fromPrimitive(_ pbPrimitive: PbJSONElement.Primitive) throws -> Primitive {
        let primitive = Primitive(value: try valueFrom(pbPrimitive.type, data: pbPrimitive.value), createdAt: fromTimeTicket(pbPrimitive.createdAt))
        primitive.movedAt = pbPrimitive.hasMovedAt ? fromTimeTicket(pbPrimitive.movedAt) : nil
        primitive.removedAt = pbPrimitive.hasRemovedAt ? fromTimeTicket(pbPrimitive.removedAt) : nil
        return primitive
    }

    /**
     * `toText` converts the given model to Protobuf format.
     */
    // TODO: CRDTText is not implemented!
//    static func toText(text: CRDTText) -> PbJSONElement {
//        var pbText = PbJSONElement.Text()
//        pbText.nodes = toTextNodes(text.getRGATreeSplit())
//        pbText.createdAt = toTimeTicket(text.createdAt)
//        pbText.movedAt = toTimeTicket(text.getMovedAt())
//        pbText.removedAt = toTimeTicket(text.removedAt)
//
//        var pbElement = PbJSONElement();
//        pbElement.text = pbText
//        return pbElement;
//    }

    /**
     * `fromText` converts the given Protobuf format to model format.
     */
//    function fromText(pbText: PbJSONElement.Text): CRDTText {
//        const rgaTreeSplit = new RGATreeSplit<string>();
//
//        let prev = rgaTreeSplit.getHead();
//        for (const pbNode of pbText.getNodesList()) {
//            const current = rgaTreeSplit.insertAfter(prev, fromTextNode(pbNode));
//            if (pbNode.hasInsPrevId()) {
//                current.setInsPrev(
//                    rgaTreeSplit.findNode(fromTextNodeID(pbNode.getInsPrevId()!)),
//                );
//            }
//            prev = current;
//        }
//
//        const text = CRDTText.create(
//            rgaTreeSplit,
//            fromTimeTicket(pbText.createdAt)!,
//        );
//        text.setMovedAt(fromTimeTicket(pbText.getMovedAt()));
//        text.removedAt = fromTimeTicket(pbText.removedAt));
//        return text;
//    }

    /**
     * `toCounter` converts the given model to Protobuf format.
     */
    // TODO: CRDTCounter is not implemented!
//    function toCounter(counter: CRDTCounter): PbJSONElement {
//        const pbCounter = new PbJSONElement.Counter();
//        pbCounter.setType(toCounterType(counter.getType()));
//        pbCounter.setValue(counter.toBytes());
//        pbCounter.setCreatedAt(toTimeTicket(counter.createdAt));
//        pbCounter.setMovedAt(toTimeTicket(counter.getMovedAt()));
//        pbCounter.removedAt = toTimeTicket(counter.removedAt));
//
//        const pbElement = new PbJSONElement();
//        pbElement.setCounter(pbCounter);
//        return pbElement;
//    }

    /**
     * `fromCounter` converts the given Protobuf format to model format.
     */
//    function fromCounter(pbCounter: PbJSONElement.Counter): CRDTCounter {
//        const counter = CRDTCounter.of(
//            CRDTCounter.valueFromBytes(
//                fromCounterType(pbCounter.getType()),
//                pbCounter.getValue_asU8(),
//            ),
//            fromTimeTicket(pbCounter.createdAt)!,
//        );
//        counter.setMovedAt(fromTimeTicket(pbCounter.getMovedAt()));
//        counter.removedAt = fromTimeTicket(pbCounter.removedAt));
//        return counter;
//    }

    /**
     * `toElement` converts the given model to Protobuf format.
     */
    static func toElement(_ element: CRDTElement) throws -> PbJSONElement {
        if let element = element as? CRDTObject {
            return toObject(element)
        } else if let element = element as? CRDTArray {
            return toArray(element)
        } else if let element = element as? Primitive {
            return toPrimitive(element)
            // TODO: CRDTText, CRDTCounter is not implemented!
//        } else if let element = element as? CRDTText {
//            return toText(element);
//        } else if let element = element as? CRDTCounter {
//            return toCounter(element);
        } else {
            throw YorkieError.unimplemented(message: "unimplemented element: \(element)")
        }
    }

    /**
     * `fromElement` converts the given Protobuf format to model format.
     */
    static func fromElement(pbElement: PbJSONElement) throws -> CRDTElement {
        if case let .jsonObject(element) = pbElement.body {
            return try fromObject(element)
        } else if case let .jsonArray(element) = pbElement.body {
            return try fromArray(element)
        } else if case let .primitive(element) = pbElement.body {
            return try fromPrimitive(element)
        } else if case let .text(element) = pbElement.body {
            throw YorkieError.unimplemented(message: "unimplemented element: \(pbElement)")
            // TODO: fromText is not implemented!
//            return fromText(element)
        } else if case let .richText(element) = pbElement.body {
            // TODO: fromRichText is not implemented!
            throw YorkieError.unimplemented(message: "unimplemented element: \(pbElement)")
//            return fromRichText(element)
        } else if case let .counter(element) = pbElement.body {
            // TODO: fromCounter is not implemented!
            throw YorkieError.unimplemented(message: "unimplemented element: \(pbElement)")
//            return fromCounter(element)
        } else {
            throw YorkieError.unimplemented(message: "unimplemented element: \(pbElement)")
        }
    }
}

// MARK: TextNode
extension Converter {
    /**
     * `toTextNodes` converts the given model to Protobuf format.
     */
    // TODO: RGATreeSplit is not implemented
//    static func toTextNodes(rgaTreeSplit: RGATreeSplit<string>) -> [PbTextNode] {
//        const pbTextNodes = [];
//        for (const textNode of rgaTreeSplit) {
//            const pbTextNode = new PbTextNode();
//            pbTextNode.setId(toTextNodeID(textNode.id));
//            pbTextNode.setValue(textNode.value);
//            pbTextNode.removedAt = toTimeTicket(textNode.removedAt));
//
//            pbTextNodes.push(pbTextNode);
//        }
//
//        return pbTextNodes;
//    }

    /**
     * `fromTextNode` converts the given Protobuf format to model format.
     */
//    function fromTextNode(pbTextNode: PbTextNode): RGATreeSplitNode<string> {
//        const textNode = RGATreeSplitNode.create(
//            fromTextNodeID(pbTextNode.getId()!),
//            pbTextNode.value,
//        );
//        textNode.remove(fromTimeTicket(pbTextNode.removedAt));
//        return textNode;
//    }
}

// MARK: RichTextNode
extension Converter {
    /**
     * `fromRichTextNode` converts the given Protobuf format to model format.
     */
    // TODO: RGATreeSplitNode is not implemented
//    static func fromRichTextNode(_ pbTextNode: PbRichTextNode) -> RGATreeSplitNode<RichTextValue> {
//        const richTextValue = RichTextValue.create(pbTextNode.value);
//        pbTextNode.getAttributesMap().forEach((value) => {
//            richTextValue.setAttr(
//                value.key,
//                value.value,
//                fromTimeTicket(value.getUpdatedAt())!,
//            );
//        });
//
//        const textNode = RGATreeSplitNode.create(
//            fromTextNodeID(pbTextNode.getId()!),
//            richTextValue,
//        );
//        textNode.remove(fromTimeTicket(pbTextNode.removedAt));
//        return textNode;
//    }

    /**
     * `fromRichText` converts the given Protobuf format to model format.
     */
//    function fromRichText<A>(pbText: PbJSONElement.RichText): CRDTRichText<A> {
//        const rgaTreeSplit = new RGATreeSplit<RichTextValue>();
//
//        let prev = rgaTreeSplit.getHead();
//        for (const pbNode of pbText.getNodesList()) {
//            const current = rgaTreeSplit.insertAfter(prev, fromRichTextNode(pbNode));
//            if (pbNode.hasInsPrevId()) {
//                current.setInsPrev(
//                    rgaTreeSplit.findNode(fromTextNodeID(pbNode.getInsPrevId()!)),
//                );
//            }
//            prev = current;
//        }
//        const text = new CRDTRichText<A>(
//            rgaTreeSplit,
//            fromTimeTicket(pbText.createdAt)!,
//        );
//        text.setMovedAt(fromTimeTicket(pbText.getMovedAt()));
//        text.removedAt = fromTimeTicket(pbText.removedAt));
//        return text;
//    }
}

// MARK: ChangePack
extension Converter {
    /**
     * `toChangePack` converts the given model to Protobuf format.
     */
    static func toChangePack(pack: ChangePack) -> PbChangePack {
        var pbChangePack = PbChangePack()
        pbChangePack.documentKey = pack.getDocumentKey()
        pbChangePack.checkpoint = toCheckpoint(pack.getCheckpoint())
        pbChangePack.changes = toChanges(pack.getChanges())
        pbChangePack.snapshot = pack.getSnapshot() ?? Data()
        if let minSyncedTicket = pack.getMinSyncedTicket() {
            pbChangePack.minSyncedTicket = toTimeTicket(minSyncedTicket)
        } else {
            pbChangePack.clearMinSyncedTicket()
        }
        return pbChangePack
    }

    /**
     * `fromChangePack` converts the given Protobuf format to model format.
     */
    static func fromChangePack(_ pbPack: PbChangePack) throws -> ChangePack {
        ChangePack(key: pbPack.documentKey,
                   checkpoint: fromCheckpoint(pbPack.checkpoint),
                   changes: try fromChanges(pbPack.changes),
                   snapshot: pbPack.snapshot.isEmpty ? nil : pbPack.snapshot,
                   minSyncedTicket: pbPack.hasMinSyncedTicket ? fromTimeTicket(pbPack.minSyncedTicket) : nil)
    }

}

// MARK: Change
extension Converter {
    /**
     * `toChange` converts the given model to Protobuf format.
     */
    static func toChange(_ change: Change) -> PbChange {
        var pbChange = PbChange()
        pbChange.id = toChangeID(change.id)
        pbChange.message = change.message ?? ""
        pbChange.operations = toOperations(change.operations)
        return pbChange
    }

    /**
     * `toChanges` converts the given model to Protobuf format.
     */
    static func toChanges(_ changes: [Change]) -> [PbChange] {
        changes.map {
            toChange($0)
        }
    }

    /**
     * `fromChanges` converts the given Protobuf format to model format.
     */
    static func fromChanges(_ pbChanges: [PbChange]) throws -> [Change] {
        try pbChanges.compactMap {
            Change(id: fromChangeID($0.id),
                   operations: try fromOperations($0.operations),
                   message: $0.message.isEmpty ? nil : $0.message)
        }
    }
}

// MARK: Bytes.
extension Converter {
    /**
     * `bytesToObject` creates an JSONObject from the given byte array.
     */
    static func bytesToObject(bytes: Data) throws -> CRDTObject {
        guard bytes.isEmpty == false else {
            return CRDTObject(createdAt: TimeTicket.initial)
        }

        let pbElement = try PbJSONElement(serializedData: bytes)
        return try fromObject(pbElement.jsonObject)
    }

    /**
     * `objectToBytes` converts the given JSONObject to byte array.
     */
    static func objectToBytes(obj: CRDTObject) throws -> Data {
        try toElement(obj).serializedData()
    }
}

// MARK: Hex
extension Data {
    var toHexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}

extension String {
    // Same as toUint8Array in JS
    var toData: Data? {
        guard self.count % 2 == 0 else {
            return nil
        }

        var data = Data()
        for index in stride(from: 0, to: self.count, by: 2) {
            let pair = self.substring(from: index, to: index + 1)

            guard let value = UInt8(pair, radix: 16) else {
                return nil
            }

            data.append(value)
        }

        return data
    }
}
