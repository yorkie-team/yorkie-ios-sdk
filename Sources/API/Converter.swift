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
            let result = Int32(littleEndian: data.withUnsafeBytes { $0.load(as: Int32.self) })
            return .integer(result)
        case .double:
            let result = Double(bitPattern: UInt64(littleEndian: data.withUnsafeBytes { $0.load(as: UInt64.self) }))
            return .double(result)
        case .string:
            return .string(String(decoding: data, as: UTF8.self))
        case .long:
            let result = Int64(littleEndian: data.withUnsafeBytes { $0.load(as: Int64.self) })
            return .long(result)
        case .bytes:
            return .bytes(data)
        case .date:
            let milliseconds = Int64(littleEndian: data.withUnsafeBytes { $0.load(as: Int64.self) })
            return .date(Date(timeIntervalSince1970: TimeInterval(Double(milliseconds) / 1000)))
        default:
            throw YorkieError.unimplemented(message: String(describing: valueType))
        }
    }

    static func countValueFrom(_ valueType: PbValueType, data: Data) throws -> any YorkieCountable {
        switch valueType {
        case .integerCnt:
            return Int32(littleEndian: data.withUnsafeBytes { $0.load(as: Int32.self) })
        case .longCnt:
            return Int64(littleEndian: data.withUnsafeBytes { $0.load(as: Int64.self) })
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
                // emulate JSON.stringify() in JavaScript.
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
        pbTimeTicket.lamport = ticket.lamport
        pbTimeTicket.delimiter = ticket.delimiter
        pbTimeTicket.actorID = ticket.actorID?.toData ?? Data()
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
    static func toCounterType(_ valueType: any YorkieCountable) -> PbValueType {
        if valueType is Int32 {
            return .integerCnt
        } else {
            return .longCnt
        }
    }
}

// MARK: ElementSimple
extension Converter {
    /**
     * `toElementSimple` converts the given model to Protobuf format.
     */
    static func toElementSimple(_ element: CRDTElement) -> PbJSONElementSimple {
        var pbElementSimple = PbJSONElementSimple()

        if element is CRDTObject {
            pbElementSimple.type = .jsonObject
        } else if element is CRDTArray {
            pbElementSimple.type = .jsonArray
        } else if element is CRDTText {
            pbElementSimple.type = .text
        } else if let element = element as? Primitive {
            let primitive = element.value
            pbElementSimple.type = toValueType(primitive)
            pbElementSimple.value = element.toBytes()
        } else if let counter = element as? CRDTCounter<Int32> {
            pbElementSimple.type = .integerCnt
            pbElementSimple.value = counter.toBytes()
        } else if let counter = element as? CRDTCounter<Int64> {
            pbElementSimple.type = .longCnt
            pbElementSimple.value = counter.toBytes()
        } else if let tree = element as? CRDTTree {
            pbElementSimple.type = .tree
            do {
                pbElementSimple.value = try treeToBytes(tree)
            } catch {
                fatalError("Can't convert CRDTTree to bytes.")
            }
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
            return CRDTText(rgaTreeSplit: RGATreeSplit(), createdAt: fromTimeTicket(pbElementSimple.createdAt))
        case .null, .boolean, .integer, .long, .double, .string, .bytes, .date:
            return Primitive(value: try valueFrom(pbElementSimple.type, data: pbElementSimple.value), createdAt: fromTimeTicket(pbElementSimple.createdAt))
        case .integerCnt:
            guard let value = try countValueFrom(pbElementSimple.type, data: pbElementSimple.value) as? Int32 else {
                throw YorkieError.unexpected(message: "unexpected counter value type")
            }

            return CRDTCounter<Int32>(value: value, createdAt: fromTimeTicket(pbElementSimple.createdAt))
        case .longCnt:
            guard let value = try countValueFrom(pbElementSimple.type, data: pbElementSimple.value) as? Int64 else {
                throw YorkieError.unexpected(message: "unexpected counter value type")
            }

            return CRDTCounter<Int64>(value: value, createdAt: fromTimeTicket(pbElementSimple.createdAt))
        case .tree:
            return try bytesToTree(bytes: pbElementSimple.value)
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
    static func toTextNodeID(id: RGATreeSplitNodeID) -> PbTextNodeID {
        var pbTextNodeID = PbTextNodeID()
        pbTextNodeID.createdAt = toTimeTicket(id.createdAt)
        pbTextNodeID.offset = id.offset
        return pbTextNodeID
    }

    /**
     * `fromTextNodeID` converts the given Protobuf format to model format.
     */
    static func fromTextNodeID(_ pbTextNodeID: PbTextNodeID) -> RGATreeSplitNodeID {
        RGATreeSplitNodeID(Self.fromTimeTicket(pbTextNodeID.createdAt), pbTextNodeID.offset)
    }
}

// MARK: TextNodePos
extension Converter {
    /**
     * `toTextNodePos` converts the given model to Protobuf format.
     */
    static func toTextNodePos(pos: RGATreeSplitNodePos) -> PbTextNodePos {
        var pbTextNodePos = PbTextNodePos()
        pbTextNodePos.createdAt = toTimeTicket(pos.id.createdAt)
        pbTextNodePos.offset = pos.id.offset
        pbTextNodePos.relativeOffset = pos.relativeOffset
        return pbTextNodePos
    }

    /**
     * `fromTextNodePos` converts the given Protobuf format to model format.
     */
    static func fromTextNodePos(_ pbTextNodePos: PbTextNodePos) -> RGATreeSplitNodePos {
        RGATreeSplitNodePos(RGATreeSplitNodeID(Self.fromTimeTicket(pbTextNodePos.createdAt), pbTextNodePos.offset), pbTextNodePos.relativeOffset)
    }
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
            pbSetOperation.value = toElementSimple(setOperation.value)
            pbSetOperation.executedAt = toTimeTicket(setOperation.executedAt)
            pbOperation.set = pbSetOperation
        } else if let addOperation = operation as? AddOperation {
            var pbAddOperation = PbOperation.Add()
            pbAddOperation.parentCreatedAt = toTimeTicket(addOperation.parentCreatedAt)
            pbAddOperation.prevCreatedAt = toTimeTicket(addOperation.previousCreatedAt)
            pbAddOperation.value = toElementSimple(addOperation.value)
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
        } else if let editOperation = operation as? EditOperation {
            var pbEditOperation = PbOperation.Edit()
            pbEditOperation.parentCreatedAt = toTimeTicket(editOperation.parentCreatedAt)
            pbEditOperation.from = toTextNodePos(pos: editOperation.fromPos)
            pbEditOperation.to = toTextNodePos(pos: editOperation.toPos)
            editOperation.maxCreatedAtMapByActor.forEach {
                pbEditOperation.createdAtMapByActor[$0.key] = toTimeTicket($0.value)
            }
            pbEditOperation.content = editOperation.content
            editOperation.attributes?.forEach {
                pbEditOperation.attributes[$0.key] = $0.value
            }
            pbEditOperation.executedAt = toTimeTicket(editOperation.executedAt)
            pbOperation.edit = pbEditOperation
        } else if let selectOperaion = operation as? SelectOperation {
            var pbSelectOperation = PbOperation.Select()
            pbSelectOperation.parentCreatedAt = toTimeTicket(selectOperaion.parentCreatedAt)
            pbSelectOperation.from = toTextNodePos(pos: selectOperaion.fromPos)
            pbSelectOperation.to = toTextNodePos(pos: selectOperaion.toPos)
            pbSelectOperation.executedAt = toTimeTicket(selectOperaion.executedAt)
            pbOperation.select = pbSelectOperation
        } else if let styleOperation = operation as? StyleOperation {
            var pbStyleOperation = PbOperation.Style()
            pbStyleOperation.parentCreatedAt = toTimeTicket(styleOperation.parentCreatedAt)
            pbStyleOperation.from = toTextNodePos(pos: styleOperation.fromPos)
            pbStyleOperation.to = toTextNodePos(pos: styleOperation.toPos)
            styleOperation.attributes.forEach {
                pbStyleOperation.attributes[$0.key] = $0.value
            }
            pbStyleOperation.executedAt = toTimeTicket(styleOperation.executedAt)
            pbOperation.style = pbStyleOperation
        } else if let increaseOperation = operation as? IncreaseOperation {
            var pbIncreaseOperation = PbOperation.Increase()
            pbIncreaseOperation.parentCreatedAt = toTimeTicket(increaseOperation.parentCreatedAt)
            pbIncreaseOperation.value = toElementSimple(increaseOperation.value)
            pbIncreaseOperation.executedAt = toTimeTicket(increaseOperation.executedAt)
            pbOperation.increase = pbIncreaseOperation
        } else if let treeEditOperation = operation as? TreeEditOperation {
            var pbTreeEditOperation = PbOperation.TreeEdit()
            pbTreeEditOperation.parentCreatedAt = toTimeTicket(treeEditOperation.parentCreatedAt)
            pbTreeEditOperation.from = toTreePos(treeEditOperation.fromPos)
            pbTreeEditOperation.to = toTreePos(treeEditOperation.toPos)
            pbTreeEditOperation.contents = toTreeNodesWhenEdit(treeEditOperation.contents)
            pbTreeEditOperation.executedAt = toTimeTicket(treeEditOperation.executedAt)
            pbOperation.treeEdit = pbTreeEditOperation
        } else if let treeStyleOperation = operation as? TreeStyleOperation {
            var pbTreeStyleOperation = PbOperation.TreeStyle()
            pbTreeStyleOperation.parentCreatedAt = toTimeTicket(treeStyleOperation.parentCreatedAt)
            pbTreeStyleOperation.from = toTreePos(treeStyleOperation.fromPos)
            pbTreeStyleOperation.to = toTreePos(treeStyleOperation.toPos)
            
            treeStyleOperation.attributes.forEach { key, value in
                pbTreeStyleOperation.attributes[key] = value
            }
            pbTreeStyleOperation.executedAt = toTimeTicket(treeStyleOperation.executedAt)
            pbOperation.treeStyle = pbTreeStyleOperation
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
                let createdAtMapByActor = pbEditOperation.createdAtMapByActor.mapValues { fromTimeTicket($0) }
                                
                return EditOperation(parentCreatedAt: fromTimeTicket(pbEditOperation.parentCreatedAt),
                                     fromPos: fromTextNodePos(pbEditOperation.from),
                                     toPos: fromTextNodePos(pbEditOperation.to),
                                     maxCreatedAtMapByActor: createdAtMapByActor,
                                     content: pbEditOperation.content,
                                     attributes: pbEditOperation.attributes,
                                     executedAt: fromTimeTicket(pbEditOperation.executedAt))
            } else if case let .select(pbSelectOperation) = pbOperation.body {
                return SelectOperation(parentCreatedAt: fromTimeTicket(pbSelectOperation.parentCreatedAt),
                                       fromPos: fromTextNodePos(pbSelectOperation.from),
                                       toPos: fromTextNodePos(pbSelectOperation.to),
                                       executedAt: fromTimeTicket(pbSelectOperation.executedAt))
            } else if case let .style(pbStyleOperation) = pbOperation.body {
                return StyleOperation(parentCreatedAt: fromTimeTicket(pbStyleOperation.parentCreatedAt),
                                      fromPos: fromTextNodePos(pbStyleOperation.from),
                                      toPos: fromTextNodePos(pbStyleOperation.to),
                                      attributes: pbStyleOperation.attributes,
                                      executedAt: fromTimeTicket(pbStyleOperation.executedAt))
            } else if case let .increase(pbIncreaseOperation) = pbOperation.body {
                return IncreaseOperation(parentCreatedAt: fromTimeTicket(pbIncreaseOperation.parentCreatedAt),
                                         value: try fromElementSimple(pbElementSimple: pbIncreaseOperation.value),
                                         executedAt: fromTimeTicket(pbIncreaseOperation.executedAt))
            } else if case let .treeEdit(pbTreeEditOperation) = pbOperation.body {
                return TreeEditOperation(parentCreatedAt: fromTimeTicket(pbTreeEditOperation.parentCreatedAt),
                                         fromPos: fromTreePos(pbTreeEditOperation.from),
                                         toPos: fromTreePos(pbTreeEditOperation.to),
                                         contents: fromTreeNodesWhenEdit(pbTreeEditOperation.contents),
                                         executedAt: fromTimeTicket(pbTreeEditOperation.executedAt))
            } else if case let .treeStyle(pbTreeStyleOperation) = pbOperation.body {
                return TreeStyleOperation(parentCreatedAt: fromTimeTicket(pbTreeStyleOperation.parentCreatedAt),
                                          fromPos: fromTreePos(pbTreeStyleOperation.from),
                                          toPos: fromTreePos(pbTreeStyleOperation.to),
                                          attributes: pbTreeStyleOperation.attributes,
                                          executedAt: fromTimeTicket(pbTreeStyleOperation.executedAt))
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
    static func toRHTNodes(rht: ElementRHT) -> [PbRHTNode] {
        rht.compactMap {
            guard let element = try? toElement($0.value) else {
                return nil
            }

            var pbRHTNode = PbRHTNode()
            pbRHTNode.key = $0.key
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
        let rht = ElementRHT()
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
    static func toText(_ text: CRDTText) -> PbJSONElement {
        var pbText = PbJSONElement.Text()
        pbText.nodes = toTextNodes(text.rgaTreeSplit)
        pbText.createdAt = toTimeTicket(text.createdAt)
        if let ticket = text.movedAt {
            pbText.movedAt = toTimeTicket(ticket)
        }
        if let ticket = text.removedAt {
            pbText.removedAt = toTimeTicket(ticket)
        }

        var pbElement = PbJSONElement()
        pbElement.text = pbText
        return pbElement;
    }

    /**
     * `fromText` converts the given Protobuf format to model format.
     */
    static func fromText(_ pbText: PbJSONElement.Text) -> CRDTText {
        let rgaTreeSplit = RGATreeSplit<TextValue>()

        var prev = rgaTreeSplit.head
        pbText.nodes.forEach { pbNode in
            let current = rgaTreeSplit.insertAfter(prev, fromTextNode(pbNode))
            if pbNode.hasInsPrevID {
                current.setInsPrev(rgaTreeSplit.findNode(fromTextNodeID(pbNode.insPrevID)))
            }
            prev = current
        }

        let text = CRDTText(rgaTreeSplit: rgaTreeSplit, createdAt: fromTimeTicket(pbText.createdAt))
        text.movedAt = fromTimeTicket(pbText.movedAt)
        text.removedAt = pbText.hasRemovedAt ? fromTimeTicket(pbText.removedAt) : nil
        return text
    }

    /**
     * `toCounter` converts the given model to Protobuf format.
     */
    static func toCounter<T: YorkieCountable>(_ counter: CRDTCounter<T>) -> PbJSONElement {
        var pbCounter = PbJSONElement.Counter()
        pbCounter.type = toCounterType(counter.value)
        pbCounter.value = counter.toBytes()
        pbCounter.createdAt = toTimeTicket(counter.createdAt)
        if let ticket = counter.movedAt {
            pbCounter.movedAt = toTimeTicket(ticket)
        } else {
            pbCounter.clearMovedAt()
        }
        if let ticket = counter.removedAt {
            pbCounter.removedAt = toTimeTicket(ticket)
        } else {
            pbCounter.clearRemovedAt()
        }

        var pbElement = PbJSONElement()
        pbElement.counter = pbCounter
        return pbElement
    }

    /**
     * `fromCounter` converts the given Protobuf format to model format.
     */
    static func fromCounter(_ pbCounter: PbJSONElement.Counter) throws -> CRDTElement {
        let value = try countValueFrom(pbCounter.type, data: pbCounter.value)

        switch pbCounter.type {
        case .integerCnt:
            guard let value = value as? Int32 else {
                throw YorkieError.unexpected(message: "[\(pbCounter.type)] value is not Int32.")
            }
            let counter = CRDTCounter<Int32>(value: value, createdAt: fromTimeTicket(pbCounter.createdAt))
            counter.movedAt = pbCounter.hasMovedAt ? fromTimeTicket(pbCounter.movedAt) : nil
            counter.removedAt = pbCounter.hasRemovedAt ? fromTimeTicket(pbCounter.removedAt) : nil

            return counter
        case .longCnt:
            guard let value = value as? Int64 else {
                throw YorkieError.unexpected(message: "[\(pbCounter.type)] value is not Int64.")
            }
            let counter = CRDTCounter<Int64>(value: value, createdAt: fromTimeTicket(pbCounter.createdAt))
            counter.movedAt = pbCounter.hasMovedAt ? fromTimeTicket(pbCounter.movedAt) : nil
            counter.removedAt = pbCounter.hasRemovedAt ? fromTimeTicket(pbCounter.removedAt) : nil

            return counter
        default:
            throw YorkieError.unimplemented(message: "\(pbCounter.type) is not implemented.")
        }
    }

    /**
     * `fromTree` converts the given Protobuf format to model format.
     */
    static func fromTree(_ pbTree: PbJSONElement.Tree) throws -> CRDTTree {
        guard let root = try fromTreeNodes(pbTree.nodes) else {
            throw YorkieError.unexpected(message: "Can't get root from PbJSONElement.Tree")
        }
        return CRDTTree(root: root, createdAt: fromTimeTicket(pbTree.createdAt))
    }

    /**
     * `toTree` converts the given model to Protobuf format.
     */
    static func toTree(_ tree: CRDTTree) -> PbJSONElement {
        var pbTree = PbJSONElement.Tree()
        pbTree.nodes = toTreeNodes(tree.root)
        pbTree.createdAt = toTimeTicket(tree.createdAt)
        if let ticket = tree.movedAt {
            pbTree.movedAt = toTimeTicket(ticket)
        } else {
            pbTree.clearMovedAt()
        }
        if let ticket = tree.removedAt {
            pbTree.removedAt = toTimeTicket(ticket)
        } else {
            pbTree.clearRemovedAt()
        }

        var pbElement = PbJSONElement()
        pbElement.tree = pbTree
        return pbElement
    }

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
        } else if let element = element as? CRDTText {
            return toText(element);
        } else if let element = element as? CRDTCounter<Int32> {
            return toCounter(element)
        } else if let element = element as? CRDTCounter<Int64> {
            return toCounter(element)
        } else if let element = element as? CRDTTree {
            return toTree(element)
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
            return fromText(element)
        } else if case let .counter(element) = pbElement.body {
            return try fromCounter(element)
        } else {
            throw YorkieError.unimplemented(message: "unimplemented element: \(pbElement)")
        }
    }
}

// MARK: Tree
extension Converter {
    /**
     * `toTreePos` converts the given model to Protobuf format.
     */
    static func toTreePos(_ pos: CRDTTreePos) -> PbTreePos {
        var pbTreePos = PbTreePos()
        pbTreePos.createdAt = toTimeTicket(pos.createdAt)
        pbTreePos.offset = pos.offset
        
        return pbTreePos
    }

    /**
     * `toTreeNodesWhenEdit` converts the given model to Protobuf format.
     */
    static func toTreeNodesWhenEdit(_ nodes: [CRDTTreeNode]?) -> [PbTreeNodes] {
        guard let nodes else {
            return []
        }
        
        return nodes.compactMap {
            var pbTreeNodes = PbTreeNodes()
            pbTreeNodes.content = toTreeNodes($0)
            
            return pbTreeNodes
        }
    }

    /**
     * `toTreeNodes` converts the given model to Protobuf format.
     */
    static func toTreeNodes(_ node: CRDTTreeNode) -> [PbTreeNode] {
        var pbTreeNodes = [PbTreeNode]()
        
        traverse(node: node) { node, depth in
            var pbTreeNode = PbTreeNode()
            pbTreeNode.pos = toTreePos(node.pos)
            pbTreeNode.type = node.type
            if node.isText {
                pbTreeNode.value = node.value
            }
            if let ticket = node.removedAt {
                pbTreeNode.removedAt = toTimeTicket(ticket)
            } else {
                pbTreeNode.clearRemovedAt()
            }
            pbTreeNode.depth = depth
            
            node.attrs?.forEach { rhtNode in
                var pbNodeAttr = PbNodeAttr()
                pbNodeAttr.value = rhtNode.value
                pbNodeAttr.updatedAt = toTimeTicket(rhtNode.updatedAt)
                pbTreeNode.attributes[rhtNode.key] = pbNodeAttr
            }

            pbTreeNodes.append(pbTreeNode)
        }

        return pbTreeNodes
    }

    /**
     * `fromTreePos` converts the given Protobuf format to model format.
     */
    static func fromTreePos(_ pbTreePos: PbTreePos) -> CRDTTreePos {
        CRDTTreePos(createdAt: fromTimeTicket(pbTreePos.createdAt), offset: pbTreePos.offset)
    }

    /**
     * `fromTreeNodesWhenEdit` converts the given Protobuf format to model format.
     */
    static func fromTreeNodesWhenEdit(_ pbTreeNodes: [PbTreeNodes]) -> [CRDTTreeNode]? {
        guard pbTreeNodes.isEmpty == false else {
            return nil
        }
        
        return pbTreeNodes.compactMap { try? fromTreeNodes($0.content) }
    }

    /**
     * `fromTreeNodes` converts the given Protobuf format to model format.
     */
    static func fromTreeNodes(_ pbTreeNodes: [PbTreeNode]) throws -> CRDTTreeNode? {
        guard pbTreeNodes.isEmpty == false else {
            return nil
        }
        
        let nodes = pbTreeNodes.compactMap { fromTreeNode($0) }
        
        let root = nodes[nodes.count - 1]
        
        for index in stride(from: nodes.count - 2, to: -1, by: -1) {
            var parent: CRDTTreeNode?
            for index2 in index + 1 ..< nodes.count {
                if pbTreeNodes[index].depth - 1 == pbTreeNodes[index2].depth {
                    parent = nodes[index2]
                    break
                }
            }
            
            try parent?.prepend(contentsOf: [nodes[index]])
        }
        
        // build CRDTTree from the root to construct the links between nodes.
        return CRDTTree(root: root, createdAt: TimeTicket.initial).root
    }

    /**
     * `fromTreeNode` converts the given Protobuf format to model format.
     */
    static func fromTreeNode(_ pbTreeNode: PbTreeNode) -> CRDTTreeNode {
        let pos = fromTreePos(pbTreeNode.pos)
        let node = CRDTTreeNode(pos: pos, type: pbTreeNode.type)

        if node.isText {
            node.value = pbTreeNode.value
        } else {
            node.attrs = RHT()
            
            pbTreeNode.attributes.forEach { key, value in
                node.attrs?.set(key: key, value: value.value, executedAt: fromTimeTicket(value.updatedAt))
            }
        }
        
        return node
    }
}

// MARK: TextNode
extension Converter {
    /**
     * `toTextNodes` converts the given model to Protobuf format.
     */
    static func toTextNodes(_ rgaTreeSplit: RGATreeSplit<TextValue>) -> [PbTextNode] {
        var pbTextNodes = [PbTextNode]()
        for textNode in rgaTreeSplit {
            var pbTextNode = PbTextNode()
            pbTextNode.id = toTextNodeID(id: textNode.id)
            pbTextNode.value = String(describing: textNode.value.content)
            textNode.value.getAttributes().forEach { key, value in
                var attr = PbNodeAttr()
                attr.value = value.value
                attr.updatedAt = toTimeTicket(value.updatedAt)
                pbTextNode.attributes[key] = attr
            }
            if let removedAt = textNode.removedAt {
                pbTextNode.removedAt = toTimeTicket(removedAt)
            }
            pbTextNodes.append(pbTextNode)
        }

        return pbTextNodes
    }

    /**
     * `fromTextNode` converts the given Protobuf format to model format.
     */
    static func fromTextNode(_ pbTextNode: PbTextNode) -> RGATreeSplitNode<TextValue> {
        let textValue = TextValue(pbTextNode.value)
        pbTextNode.attributes.forEach {
            textValue.setAttr(key: $0.key, value: $0.value.value, updatedAt: fromTimeTicket($0.value.updatedAt))
        }
        let textNode = RGATreeSplitNode(fromTextNodeID(pbTextNode.id), textValue)
        if  pbTextNode.hasRemovedAt {
            textNode.remove(fromTimeTicket(pbTextNode.removedAt))
        }
        return textNode
    }
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
        pbChangePack.isRemoved = pack.isRemoved
        return pbChangePack
    }

    /**
     * `fromChangePack` converts the given Protobuf format to model format.
     */
    static func fromChangePack(_ pbPack: PbChangePack) throws -> ChangePack {
        ChangePack(key: pbPack.documentKey,
                   checkpoint: fromCheckpoint(pbPack.checkpoint),
                   isRemoved: pbPack.isRemoved, changes: try fromChanges(pbPack.changes),
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
     * `bytesToTree` creates an CRDTTree from the given bytes.
     */
    static func bytesToTree(bytes: Data) throws -> CRDTTree {
        guard bytes.isEmpty == false else {
            return CRDTTree(root: CRDTTreeNode(pos: CRDTTreePos.initial, type: DefaultTreeNodeType.root.rawValue), createdAt: TimeTicket.initial)
        }
        
        let pbElement = try PbJSONElement(serializedData: bytes)
        return try fromTree(pbElement.tree)
    }

    /**
     * `treeToBytes` converts the given tree to bytes.
     */
    static func treeToBytes(_ tree: CRDTTree) throws -> Data {
        try toTree(tree).serializedData()
    }

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
