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

class JSONObjectTests: XCTestCase {
    func test_can_set() async throws {
        let target = Document(key: "doc1")
        await target.update { root in
            root.set(key: "boolean", value: true)
            root.set(key: "integer", value: Int32(111))
            root.set(key: "long", value: Int64(9_999_999))
            root.set(key: "double", value: Double(1.2222222))
            root.set(key: "string", value: "abc")

            root.set(key: "compB", value: JSONObject())
            let compB = root.get(key: "compB") as? JSONObject
            compB?.set(key: "id", value: "b")
            compB?.set(key: "compC", value: JSONObject())

            let compC = compB?.get(key: "compC") as? JSONObject
            compC?.set(key: "id", value: "c")
            compC?.set(key: "compD", value: JSONObject())
            let compD = compC?.get(key: "compD") as? JSONObject
            compD?.set(key: "id", value: "d-1")

            XCTAssertEqual(root.debugDescription,
                           """
                           {"boolean":"true","compB":{"compC":{"compD":{"id":"d-1"},"id":"c"},"id":"b"},"double":1.2222222,"integer":111,"long":9999999,"string":"abc"}
                           """)

            compD?.set(key: "id", value: "d-2")

            XCTAssertEqual(root.debugDescription,
                           """
                           {"boolean":"true","compB":{"compC":{"compD":{"id":"d-2"},"id":"c"},"id":"b"},"double":1.2222222,"integer":111,"long":9999999,"string":"abc"}
                           """)
        }
    }

    func test_can_removes() async {
        let target = Document(key: "doc1")
        await target.update { root in
            root.boolean = true
            root.integer = Int32(111)
            root.long = Int64(9_999_999)
            root.double = Double(1.2222222)
            root.string = "abc"

            root.compB = JSONObject()
            let compB = root.compB as? JSONObject
            compB?.id = "b"
            compB?.compC = JSONObject()
            let compC = compB?.compC as? JSONObject
            compC?.id = "c"
            compC?.compD = JSONObject()
            let compD = compC?.compD as? JSONObject
            compD?.id = "d-1"

            XCTAssertEqual(root.debugDescription,
                           """
                           {"boolean":"true","compB":{"compC":{"compD":{"id":"d-1"},"id":"c"},"id":"b"},"double":1.2222222,"integer":111,"long":9999999,"string":"abc"}
                           """)

            root.remove(key: "string")
            root.remove(key: "integer")
            root.remove(key: "compB")

            XCTAssertEqual(root.debugDescription,
                           """
                           {"boolean":"true","double":1.2222222,"long":9999999}
                           """)
        }
    }

    func test_can_set_with_dictionary() async {
        let target = Document(key: "doc1")
        await target.update { root in
            root.set([
                "boolean": true,
                "integer": Int32(111),
                "long": Int64(9_999_999),
                "double": Double(1.2222222),
                "string": "abc",
                "compB": ["id": "b",
                          "compC": ["id": "c",
                                    "compD": ["id": "d-1"]]]
            ])

            XCTAssertEqual(root.debugDescription,
                           """
                           {"boolean":"true","compB":{"compC":{"compD":{"id":"d-1"},"id":"c"},"id":"b"},"double":1.2222222,"integer":111,"long":9999999,"string":"abc"}
                           """)

            let compB = root.compB as? JSONObject
            let compC = compB?.compC as? JSONObject
            let compD = compC?.compD as? JSONObject
            compD?.set(key: "id", value: "d-2")

            XCTAssertEqual(root.debugDescription,
                           """
                           {"boolean":"true","compB":{"compC":{"compD":{"id":"d-2"},"id":"c"},"id":"b"},"double":1.2222222,"integer":111,"long":9999999,"string":"abc"}
                           """)

            let idOfCompD = compD?.id as? String
            XCTAssertEqual(idOfCompD, "d-2")
        }
    }

    func test_can_set_with_key_and_dictionary() async {
        let target = Document(key: "doc1")
        await target.update { root in
            root.set(key: "top", value: [
                "boolean": true,
                "integer": Int32(111),
                "long": Int64(9_999_999),
                "double": Double(1.2222222),
                "string": "abc",
                "compB": ["id": "b",
                          "compC": ["id": "c",
                                    "compD": ["id": "d-1"]]]
            ])

            XCTAssertEqual(root.debugDescription,
                           """
                           {"top":{"boolean":"true","compB":{"compC":{"compD":{"id":"d-1"},"id":"c"},"id":"b"},"double":1.2222222,"integer":111,"long":9999999,"string":"abc"}}
                           """)

            let top = root.top as? JSONObject
            let compB = top?.compB as? JSONObject
            let compC = compB?.compC as? JSONObject
            let compD = compC?.compD as? JSONObject
            compD?.set(key: "id", value: "d-2")

            XCTAssertEqual(root.debugDescription,
                           """
                           {"top":{"boolean":"true","compB":{"compC":{"compD":{"id":"d-2"},"id":"c"},"id":"b"},"double":1.2222222,"integer":111,"long":9999999,"string":"abc"}}
                           """)

            let idOfCompD = compD?.id as? String
            XCTAssertEqual(idOfCompD, "d-2")
        }
    }

    private struct JsonObejctTestType: JSONObjectable {
        var id: Int64 = 100
        var type: String = "struct"
        var serial: Int32 = 1234
        var array: [JsonArrayTestType] = [JsonArrayTestType()]

        var excludedMembers: [String] {
            ["serial"]
        }
    }

    private struct JsonArrayTestType: JSONObjectable {
        var id: Int64 = 200
    }

    func test_can_insert_obejct() async {
        let target = Document(key: "doc1")
        await target.update { root in
            root.object = JsonObejctTestType()

            XCTAssertEqual(root.debugDescription,
                           """
                           {"object":{"array":[{"id":200}],"id":100,"type":"struct"}}
                           """)
        }
    }

    func test_can_get_by_keyPath() async {
        let target = Document(key: "doc1")
        await target.update { root in
            root.object = JsonObejctTestType()

            XCTAssertEqual(root.debugDescription,
                           """
                           {"object":{"array":[{"id":200}],"id":100,"type":"struct"}}
                           """)

            let array = root[keyPath: "object/.^/array"] as? JSONArray
            array!.append(JsonArrayTestType(id: 300))

            XCTAssertEqual(root.debugDescription,
                           """
                           {"object":{"array":[{"id":200},{"id":300}],"id":100,"type":"struct"}}
                           """)
        }
    }

    private struct JSONObject0: JSONObjectable {
        let first: JSONObject1
    }

    private struct JSONObject1: JSONObjectable {
        let second: JSONObject2
    }

    private struct JSONObject2: JSONObjectable {
        let third: JSONObject3
    }

    private struct JSONObject3: JSONObjectable {
        let value: String
    }

    func test_can_get_by_long_keyPath() async {
        let target = Document(key: "doc1")
        await target.update { root in
            root.object = JSONObject0(first: JSONObject1(second: JSONObject2(third: JSONObject3(value: "initial"))))

            XCTAssertEqual(root.debugDescription,
                           """
                           {"object":{"first":{"second":{"third":{"value":"initial"}}}}}
                           """)

            let third = root[keyPath: "object/.^/first/.^/second/.^/third"] as? JSONObject
            third!.value = "changed"

            XCTAssertEqual(root.debugDescription,
                           """
                           {"object":{"first":{"second":{"third":{"value":"changed"}}}}}
                           """)
        }
    }
}
