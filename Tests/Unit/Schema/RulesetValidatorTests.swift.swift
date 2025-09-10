/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif
@testable import Yorkie

class RulesetValidatorTests: XCTestCase {
    var doc: Document!

    override func setUp() async throws {
        try await super.setUp()

        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        self.doc = Document(key: docKey)
    }

    override func tearDown() async throws {
        self.doc = nil
        try await super.tearDown()
    }
}

extension RulesetValidatorTests {
    // should validate primitive type correctly
    func testPrimitiveTypeValidation() async throws {
        try await self.doc.update({ root, _ in
            root["field1"] = nil
            root["field2"] = true
            root["field3"] = Int32(123)
            root["field4"] = 123.456
            root["field5"] = Int64.max
            root["field6"] = "test"
            root["field7"] = Date()
            root["field8"] = Data([1, 2, 3])
        }, "init")
        var root = await doc.getRootObject()

        let ruleset: [Rule] = [
            .object(ObjectRule(path: "$", properties: [
                "field1", "field2", "field3", "field4", "field5", "field6", "field7", "field8"
            ], optional: nil)),
            .primitive(PrimitiveRule(path: "$.field1", type: .primitive(.null))),
            .primitive(PrimitiveRule(path: "$.field2", type: .primitive(.boolean))),
            .primitive(PrimitiveRule(path: "$.field3", type: .primitive(.integer))),
            .primitive(PrimitiveRule(path: "$.field4", type: .primitive(.double))),
            .primitive(PrimitiveRule(path: "$.field5", type: .primitive(.long))),
            .primitive(PrimitiveRule(path: "$.field6", type: .primitive(.string))),
            .primitive(PrimitiveRule(path: "$.field7", type: .primitive(.date))),
            .primitive(PrimitiveRule(path: "$.field8", type: .primitive(.bytes)))
        ]

        var result = RulesetValidator.validateYorkieRuleset(data: root, ruleset: ruleset)
        XCTAssertTrue(result.valid)
        try await self.doc.update({ root, _ in
            root["field1"] = false
            root["field2"] = Int32(123)
            root["field3"] = 123.456
            root["field4"] = Int64.max
            root["field5"] = "test"
            root["field6"] = Date()
            root["field7"] = Data([1, 2, 3])
            root["field8"] = nil
        }, "init")
        root = await self.doc.getRootObject()
        result = RulesetValidator.validateYorkieRuleset(data: root, ruleset: ruleset)
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.errors.count, 8)
    }

    // should validate object type correctly
    func testObjectTypeValidation() async throws {
        let ruleset: [Rule] = [
            .object(ObjectRule(path: "$.user", properties: ["name"], optional: nil))
        ]
        try await doc.update({ root, _ in
            root["user"] = ["name": "test"]
        }, "check")

        var root = await doc.getRootObject()

        var result = RulesetValidator.validateYorkieRuleset(data: root, ruleset: ruleset)
        XCTAssertTrue(result.valid)

        try await self.doc.update({ root, _ in
            root["user"] = "not an object"
        }, "")
        root = await self.doc.getRootObject()

        result = RulesetValidator.validateYorkieRuleset(data: root, ruleset: ruleset)
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.errors.first?.message, "Expected object at path $.user")
    }

    // should validate array type correctly
    func testArrayTypeValidation() async throws {
        let ruleset: [Rule] = [
            .array(ArrayRule(path: "$.items"))
        ]

        try await self.doc.update { root, _ in
            root["items"] = JSONArray()
            (root["items"] as? JSONArray)?.append(1)
            (root["items"] as? JSONArray)?.append(2)
            (root["items"] as? JSONArray)?.append(3)
        }

        var root = await doc.getRootObject()
        var result = RulesetValidator.validateYorkieRuleset(data: root, ruleset: ruleset)
        XCTAssertTrue(result.valid)

        try await self.doc.update({ root, _ in
            root["items"] = "not an array"
        }, "check")

        root = await self.doc.getRootObject()
        result = RulesetValidator.validateYorkieRuleset(data: root, ruleset: ruleset)
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.errors.first?.message, "Expected array at path $.items")
    }

    // should validate nested paths correctly
    func testNestedPathsValidation() async throws {
        let ruleset: [Rule] = [
            .object(ObjectRule(path: "$", properties: ["user"], optional: nil)),
            .object(ObjectRule(path: "$.user", properties: ["name", "age"], optional: nil)),
            .primitive(PrimitiveRule(path: "$.user.name", type: .primitive(.string))),
            .primitive(PrimitiveRule(path: "$.user.age", type: .primitive(.integer)))
        ]

        try await self.doc.update { root, _ in
            root["user"] = JSONObject()
            (root["user"] as? JSONObject)?.set(key: "name", value: "test")
            (root["user"] as? JSONObject)?.set(key: "age", value: Int32(25))
        }

        var root = await doc.getRootObject()
        var result = RulesetValidator.validateYorkieRuleset(data: root, ruleset: ruleset)
        XCTAssertTrue(result.valid)

        try await self.doc.update { root, _ in
            root["user"] = JSONObject()
            (root["user"] as? JSONObject)?.set(key: "name", value: Int32(123))
            (root["user"] as? JSONObject)?.set(key: "age", value: Int32(25))
        }

        root = await self.doc.getRootObject()
        result = RulesetValidator.validateYorkieRuleset(data: root, ruleset: ruleset)
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.errors.first?.message, "Expected primitive(Yorkie.PrimitiveType.string) at path $.user.name")
    }

    // should handle missing or unexpected values correctly
    func ignore_testMissingOrUnexpectedValues() {
        let ruleset: [Rule] = [
            .object(ObjectRule(
                path: "$.user",
                properties: ["name", "age", "address"],
                optional: ["address"]
            )),
            .primitive(PrimitiveRule(path: "$.user.name", type: .primitive(.string))),
            .primitive(PrimitiveRule(path: "$.user.age", type: .primitive(.integer))),
            .primitive(PrimitiveRule(path: "$.user.address", type: .primitive(.string)))
        ]

        // 1. All properties are present
        var doc: [String: Any?] = [
            "user": ["name": "test", "age": 25, "address": "123 Main St"]
        ]
        var result = RulesetValidator.validateYorkieRuleset(data: doc, ruleset: ruleset)
        XCTAssertTrue(result.valid)

        // 2. Optional property is missing
        doc = [
            "user": ["name": "test", "age": 26]
        ]
        result = RulesetValidator.validateYorkieRuleset(data: doc, ruleset: ruleset)
        XCTAssertTrue(result.valid)

        // 3. Required property is missing
        doc = [
            "user": ["name": "test"]
        ]
        result = RulesetValidator.validateYorkieRuleset(data: doc, ruleset: ruleset)
        XCTAssertFalse(result.valid)
        // 4. Unexpected property is present
        doc = [
            "user": ["name": "test", "age": 27, "unknown": "hello"]
        ]
        result = RulesetValidator.validateYorkieRuleset(data: doc, ruleset: ruleset)
        XCTAssertFalse(result.valid)
    }

    func testYorkieTypesValidation() async throws {
        let ruleset: [Rule] = [
            .object(ObjectRule(path: "$", properties: ["text", "tree", "counter"], optional: nil)),
            .yorkie(YorkieTypeRule(path: "$.text", type: .yorkie(.text))),
            .yorkie(YorkieTypeRule(path: "$.tree", type: .yorkie(.tree))),
            .yorkie(YorkieTypeRule(path: "$.counter", type: .yorkie(.counter)))
        ]

        try await self.doc.update { root, _ in
            root["root"] = JSONObject()
            (root["text"] as? JSONObject)?.set(key: "text", value: CRDTTextValue(""))
            (root["tree"] as? JSONObject)?.set(key: "tree", value: CRDTTreeNode(id: .initial, type: "r", children: []))
            (root["counter"] as? JSONObject)?.set(key: "counter", value: CRDTCounter(value: Int32(1), createdAt: .initial))
        }
        let root = await doc.getRootObject()
        let result = RulesetValidator.validateYorkieRuleset(data: root, ruleset: ruleset)

        XCTAssertFalse(result.valid)

        XCTAssertEqual(result.errors.map { $0.message }.sorted(), [
            "Expected yorkie.Counter at path $.counter",
            "Expected yorkie.Text at path $.text",
            "Expected yorkie.Tree at path $.tree"
        ])
    }
}
