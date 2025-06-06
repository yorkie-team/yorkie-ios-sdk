/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

import XCTest
@testable import Yorkie

class ConverterTests: XCTestCase {
    func test_data_to_hexString() {
        let array: [UInt8] = [0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        let data = Data(bytes: array, count: array.count)

        XCTAssertEqual(data.toHexString, "000102030405aabbccddeeff")

        let data2 = Data("Hello world".utf8)

        XCTAssertEqual(data2.toHexString, "48656c6c6f20776f726c64")
    }

    func test_hexString_to_Data() {
        let array: [UInt8] = [0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        let data = Data(bytes: array, count: array.count)

        let str = "000102030405aabbccddeeff"

        XCTAssertEqual(str.toData, data)

        // Odd length string.
        let strOddLength = "00010"

        XCTAssertTrue(strOddLength.toData == nil)

        // Invalid string.
        let strInvalid = "Hello!"

        XCTAssertTrue(strInvalid.toData == nil)
    }

    func test_hexString() {
        let array: [UInt8] = [0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        let data = Data(bytes: array, count: array.count)

        XCTAssertEqual(data, data.toHexString.toData)

        let str = "000102030405aabbccddeeff"

        XCTAssertEqual(str.toData?.toHexString, str)
    }

    func test_checkpoint() {
        let checkpoint = Checkpoint.initial

        let converted = Converter.fromCheckpoint(Converter.toCheckpoint(checkpoint))
        XCTAssertEqual(checkpoint, converted)
    }

    func test_changeID() {
        let changeID = ChangeID.initial

        let converted = Converter.fromChangeID(Converter.toChangeID(changeID))

        XCTAssertEqual(changeID.getClientSeq(), converted.getClientSeq())
        XCTAssertEqual(changeID.getLamport(), converted.getLamport())
        XCTAssertEqual(changeID.getActorID(), converted.getActorID())
        XCTAssertEqual(changeID.toTestString, converted.toTestString)
        XCTAssertEqual(changeID.getLamportAsString(), converted.getLamportAsString())
    }

    func test_timeTicket() {
        let timeTicket = TimeTicket.initial

        let converted = Converter.fromTimeTicket(Converter.toTimeTicket(timeTicket))

        XCTAssertEqual(timeTicket, converted)
    }

    func test_chage() {
        let addOperation = AddOperation(parentCreatedAt: TimeTicket.initial,
                                        previousCreatedAt: TimeTicket.initial,
                                        value: Primitive(value: .null, createdAt: TimeTicket.initial),
                                        executedAt: TimeTicket.initial)
        let change = Change(id: ChangeID.initial, operations: [addOperation], message: "AddOperation")
        do {
            let converted = try Converter.fromChanges([Converter.toChange(change)]).first
            XCTAssertEqual(change.toTestString, converted?.toTestString)
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_chages() {
        let setOperation = SetOperation(key: "key",
                                        value: Primitive(value: .null, createdAt: TimeTicket.initial),
                                        parentCreatedAt: TimeTicket.initial,
                                        executedAt: TimeTicket.initial)

        let addOperation = AddOperation(parentCreatedAt: TimeTicket.initial,
                                        previousCreatedAt: TimeTicket.initial,
                                        value: Primitive(value: .null, createdAt: TimeTicket.initial),
                                        executedAt: TimeTicket.initial)
        let setChange = Change(id: ChangeID.initial, operations: [setOperation], message: "SetOperation")
        let addChange = Change(id: setChange.id.next(), operations: [addOperation], message: "AddOperation")
        do {
            let convertedArray = try Converter.fromChanges(Converter.toChanges([setChange, addChange]))
            XCTAssertEqual(setChange.toTestString, convertedArray[0].toTestString)
            XCTAssertEqual(addChange.toTestString, convertedArray[1].toTestString)
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_chnagePack() {
        let addOperation = AddOperation(parentCreatedAt: TimeTicket.initial,
                                        previousCreatedAt: TimeTicket.initial,
                                        value: Primitive(value: .null, createdAt: TimeTicket.initial),
                                        executedAt: TimeTicket.initial)
        let change = Change(id: ChangeID.initial, operations: [addOperation], message: "AddOperation")
        let changePack = ChangePack(key: "sample",
                                    checkpoint: Checkpoint.initial,
                                    isRemoved: false,
                                    changes: [change],
                                    versionVector: ChangeID.initial.getVersionVector())

        do {
            let converted = try Converter.fromChangePack(Converter.toChangePack(pack: changePack))
            XCTAssertEqual(changePack.getChangeSize(), converted.getChangeSize())
            XCTAssertEqual(changePack.getChanges().first?.toTestString, converted.getChanges().first?.toTestString)
            XCTAssertEqual(changePack.getCheckpoint(), converted.getCheckpoint())
            XCTAssertEqual(changePack.getDocumentKey(), converted.getDocumentKey())
            XCTAssertEqual(changePack.getMinSyncedTicket(), converted.getMinSyncedTicket())
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_operations() {
        let setOperation = SetOperation(key: "key",
                                        value: Primitive(value: .null, createdAt: TimeTicket.initial),
                                        parentCreatedAt: TimeTicket.initial,
                                        executedAt: TimeTicket.initial)

        do {
            let converted = try Converter.fromOperations([Converter.toOperation(setOperation)]).first as? SetOperation
            XCTAssertEqual(setOperation.toTestString, converted?.toTestString)
            XCTAssertEqual(setOperation.value.toJSON(), converted?.value.toJSON())
            XCTAssertEqual(setOperation.key, converted?.key)
            XCTAssertEqual(setOperation.effectedCreatedAt, converted?.effectedCreatedAt)
            XCTAssertEqual(setOperation.executedAt, converted?.executedAt)
            XCTAssertEqual(setOperation.parentCreatedAt, converted?.parentCreatedAt)
        } catch {
            XCTFail("\(error)")
        }

        let addOperation = AddOperation(parentCreatedAt: TimeTicket.initial,
                                        previousCreatedAt: TimeTicket.initial,
                                        value: Primitive(value: .null, createdAt: TimeTicket.initial),
                                        executedAt: TimeTicket.initial)

        do {
            let converted = try Converter.fromOperations([Converter.toOperation(addOperation)]).first as? AddOperation
            XCTAssertEqual(addOperation.toTestString, converted?.toTestString)
            XCTAssertEqual(addOperation.value.toJSON(), converted?.value.toJSON())
            XCTAssertEqual(addOperation.previousCreatedAt, converted?.previousCreatedAt)
            XCTAssertEqual(addOperation.effectedCreatedAt, converted?.effectedCreatedAt)
            XCTAssertEqual(addOperation.executedAt, converted?.executedAt)
            XCTAssertEqual(addOperation.parentCreatedAt, converted?.parentCreatedAt)
        } catch {
            XCTFail("\(error)")
        }

        let moveOperation = MoveOperation(parentCreatedAt: TimeTicket.initial,
                                          previousCreatedAt: TimeTicket.initial,
                                          createdAt: TimeTicket.initial,
                                          executedAt: TimeTicket.initial)

        do {
            let converted = try Converter.fromOperations([Converter.toOperation(moveOperation)]).first as? MoveOperation
            XCTAssertEqual(moveOperation.toTestString, converted?.toTestString)
            XCTAssertEqual(moveOperation.previousCreatedAt, converted?.previousCreatedAt)
            XCTAssertEqual(moveOperation.effectedCreatedAt, converted?.effectedCreatedAt)
            XCTAssertEqual(moveOperation.createdAt, converted?.createdAt)
            XCTAssertEqual(moveOperation.executedAt, converted?.executedAt)
            XCTAssertEqual(moveOperation.parentCreatedAt, converted?.parentCreatedAt)
        } catch {
            XCTFail("\(error)")
        }

        let removeOperation = RemoveOperation(parentCreatedAt: TimeTicket.initial,
                                              createdAt: TimeTicket.initial,
                                              executedAt: TimeTicket.initial)

        do {
            let converted = try Converter.fromOperations([Converter.toOperation(removeOperation)]).first as? RemoveOperation
            XCTAssertEqual(removeOperation.toTestString, converted?.toTestString)
            XCTAssertEqual(removeOperation.effectedCreatedAt, converted?.effectedCreatedAt)
            XCTAssertEqual(removeOperation.createdAt, converted?.createdAt)
            XCTAssertEqual(removeOperation.executedAt, converted?.executedAt)
            XCTAssertEqual(removeOperation.parentCreatedAt, converted?.parentCreatedAt)
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_operations_array() {
        let setOperation = SetOperation(key: "key",
                                        value: Primitive(value: .null, createdAt: TimeTicket.initial),
                                        parentCreatedAt: TimeTicket.initial,
                                        executedAt: TimeTicket.initial)

        let addOperation = AddOperation(parentCreatedAt: TimeTicket.initial,
                                        previousCreatedAt: TimeTicket.initial,
                                        value: Primitive(value: .null, createdAt: TimeTicket.initial),
                                        executedAt: TimeTicket.initial)

        let moveOperation = MoveOperation(parentCreatedAt: TimeTicket.initial,
                                          previousCreatedAt: TimeTicket.initial,
                                          createdAt: TimeTicket.initial,
                                          executedAt: TimeTicket.initial)

        let removeOperation = RemoveOperation(parentCreatedAt: TimeTicket.initial,
                                              createdAt: TimeTicket.initial,
                                              executedAt: TimeTicket.initial)

        do {
            let convertedArray = try Converter.fromOperations(Converter.toOperations([setOperation, addOperation, moveOperation, removeOperation]))

            if let converted = convertedArray[0] as? SetOperation {
                XCTAssertEqual(setOperation.toTestString, converted.toTestString)
                XCTAssertEqual(setOperation.value.toJSON(), converted.value.toJSON())
                XCTAssertEqual(setOperation.key, converted.key)
                XCTAssertEqual(setOperation.effectedCreatedAt, converted.effectedCreatedAt)
                XCTAssertEqual(setOperation.executedAt, converted.executedAt)
                XCTAssertEqual(setOperation.parentCreatedAt, converted.parentCreatedAt)
            } else {
                XCTFail("Operation Type mismatch!")
            }

            if let converted = convertedArray[1] as? AddOperation {
                XCTAssertEqual(addOperation.toTestString, converted.toTestString)
                XCTAssertEqual(addOperation.value.toJSON(), converted.value.toJSON())
                XCTAssertEqual(addOperation.previousCreatedAt, converted.previousCreatedAt)
                XCTAssertEqual(addOperation.effectedCreatedAt, converted.effectedCreatedAt)
                XCTAssertEqual(addOperation.executedAt, converted.executedAt)
                XCTAssertEqual(addOperation.parentCreatedAt, converted.parentCreatedAt)
            } else {
                XCTFail("Operation Type mismatch!")
            }

            if let converted = convertedArray[2] as? MoveOperation {
                XCTAssertEqual(moveOperation.toTestString, converted.toTestString)
                XCTAssertEqual(moveOperation.previousCreatedAt, converted.previousCreatedAt)
                XCTAssertEqual(moveOperation.effectedCreatedAt, converted.effectedCreatedAt)
                XCTAssertEqual(moveOperation.createdAt, converted.createdAt)
                XCTAssertEqual(moveOperation.executedAt, converted.executedAt)
                XCTAssertEqual(moveOperation.parentCreatedAt, converted.parentCreatedAt)
            } else {
                XCTFail("Operation Type mismatch!")
            }

            if let converted = convertedArray[3] as? RemoveOperation {
                XCTAssertEqual(removeOperation.toTestString, converted.toTestString)
                XCTAssertEqual(removeOperation.effectedCreatedAt, converted.effectedCreatedAt)
                XCTAssertEqual(removeOperation.createdAt, converted.createdAt)
                XCTAssertEqual(removeOperation.executedAt, converted.executedAt)
                XCTAssertEqual(removeOperation.parentCreatedAt, converted.parentCreatedAt)
            } else {
                XCTFail("Operation Type mismatch!")
            }
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_element() {
        // Object Test
        let object = CRDTObject(createdAt: TimeTicket.initial)

        // Primitive test
        object.set(key: "Boolean", value: Primitive(value: PrimitiveValue.boolean(true), createdAt: TimeTicket.initial))
        object.set(key: "null", value: Primitive(value: PrimitiveValue.null, createdAt: TimeTicket.initial))
        object.set(key: "bytes", value: Primitive(value: PrimitiveValue.bytes(Data("Data String".utf8)), createdAt: TimeTicket.initial))
        object.set(key: "int", value: Primitive(value: PrimitiveValue.integer(Int32.max), createdAt: TimeTicket.initial))
        object.set(key: "long", value: Primitive(value: PrimitiveValue.long(Int64.max), createdAt: TimeTicket.initial))
        object.set(key: "double", value: Primitive(value: PrimitiveValue.double(Double.pi), createdAt: TimeTicket.initial))
        object.set(key: "string", value: Primitive(value: PrimitiveValue.string("Hello"), createdAt: TimeTicket.initial))
        object.set(key: "date", value: Primitive(value: PrimitiveValue.date(Date()), createdAt: TimeTicket.initial))

        // Array Test
        let array = CRDTArray(createdAt: TimeTicket.initial)

        do {
            try array.insert(value: object, afterCreatedAt: TimeTicket.initial)
            let converted = try Converter.fromElement(pbElement: Converter.toElement(array)) as? CRDTArray
            XCTAssertEqual(try array.get(index: 0).toSortedJSON(), try converted?.get(index: 0).toSortedJSON())
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_element_simple() {
        // Primitive test
        let boolean = Primitive(value: PrimitiveValue.boolean(true), createdAt: TimeTicket.initial)
        let null = Primitive(value: PrimitiveValue.null, createdAt: TimeTicket.initial)
        let bytes = Primitive(value: PrimitiveValue.bytes(Data("Data String".utf8)), createdAt: TimeTicket.initial)
        let intValue = Primitive(value: PrimitiveValue.integer(Int32.max), createdAt: TimeTicket.initial)
        let longValue = Primitive(value: PrimitiveValue.long(Int64.max), createdAt: TimeTicket.initial)
        let doubleValue = Primitive(value: PrimitiveValue.double(Double.pi), createdAt: TimeTicket.initial)
        let stringValue = Primitive(value: PrimitiveValue.string("Hello"), createdAt: TimeTicket.initial)
        let dateValue = Primitive(value: PrimitiveValue.date(Date()), createdAt: TimeTicket.initial)

        do {
            var converted = try Converter.fromElementSimple(pbElementSimple: Converter.toElementSimple(boolean))
            XCTAssertEqual(boolean.toJSON(), converted.toJSON())
            converted = try Converter.fromElementSimple(pbElementSimple: Converter.toElementSimple(null))
            XCTAssertEqual(null.toJSON(), converted.toJSON())
            converted = try Converter.fromElementSimple(pbElementSimple: Converter.toElementSimple(bytes))
            XCTAssertEqual(bytes.toJSON(), converted.toJSON())
            converted = try Converter.fromElementSimple(pbElementSimple: Converter.toElementSimple(intValue))
            XCTAssertEqual(intValue.toJSON(), converted.toJSON())
            converted = try Converter.fromElementSimple(pbElementSimple: Converter.toElementSimple(longValue))
            XCTAssertEqual(longValue.toJSON(), converted.toJSON())
            converted = try Converter.fromElementSimple(pbElementSimple: Converter.toElementSimple(doubleValue))
            XCTAssertEqual(doubleValue.toJSON(), converted.toJSON())
            converted = try Converter.fromElementSimple(pbElementSimple: Converter.toElementSimple(stringValue))
            XCTAssertEqual(stringValue.toJSON(), converted.toJSON())
            converted = try Converter.fromElementSimple(pbElementSimple: Converter.toElementSimple(dateValue))
            XCTAssertEqual(dateValue.toJSON(), converted.toJSON())

            // Object
            let object = CRDTObject(createdAt: TimeTicket.initial)

            converted = try Converter.fromElementSimple(pbElementSimple: Converter.toElementSimple(object))
            XCTAssertEqual(object.toJSON(), converted.toJSON())

            object.set(key: "boolean", value: boolean)

            converted = try Converter.fromElementSimple(pbElementSimple: Converter.toElementSimple(object))
            XCTAssertEqual(CRDTObject(createdAt: TimeTicket.initial).toJSON(), converted.toJSON())

            // Array
            let array = CRDTArray(createdAt: TimeTicket.initial)

            try array.insert(value: object, afterCreatedAt: TimeTicket.initial)
            converted = try Converter.fromElementSimple(pbElementSimple: Converter.toElementSimple(array))
            XCTAssertEqual(CRDTArray(createdAt: TimeTicket.initial).toJSON(), converted.toJSON())
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_presence() {
        let samplePresence: PresenceData = ["a": "str", "b": 10, "c": 0.5, "d": false, "e": ["a", "b", "c"], "f": ""]

        let stringPresence = samplePresence.mapValues { $0.toJSONString ?? "" }

        let converted = Converter.fromPresence(pbPresence: Converter.toPresence(presence: stringPresence))

        XCTAssert(!(samplePresence == converted))
    }

    func test_should_encode_and_decode_tree_properly() async throws {
        let doc = Document(key: "test-doc")

        try await doc.update { root, _ in
            root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "12")]),
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "34")])
            ]))

            try (root.tree as? JSONTree)?.editByPath([0, 1], [1, 1])

            try (root.tree as? JSONTree)?.style(0, 1, ["b": "t", "i": "t"])

            let xml = (root.tree as? JSONTree)?.toXML()

            XCTAssertEqual(xml, "<r><p b=\"t\" i=\"t\">14</p></r>")

            try (root.tree as? JSONTree)?.removeStyle(0, 1, ["i"])
        }

        let xml = await(doc.getRoot().tree as? JSONTree)?.toXML()
        let size = try await(doc.getRoot().tree as? JSONTree)?.getSize()

        XCTAssertEqual(xml, "<r><p b=\"t\">14</p></r>")
        XCTAssertEqual(size, 4)

        let bytes = try await Converter.objectToBytes(obj: doc.getRootObject())
        let obj = try Converter.bytesToObject(bytes: bytes)

        let nodeSize = try await(doc.getRoot().tree as? JSONTree)?.getNodeSize()
        let nodeSize2 = (obj.get(key: "tree") as? CRDTTree)?.nodeSize

        XCTAssertEqual(nodeSize, nodeSize2)

        let size1 = try await(doc.getRoot().tree as? JSONTree)?.getSize()
        let size2 = (obj.get(key: "tree") as? CRDTTree)?.size

        XCTAssertEqual(size1, size2)
    }
}
