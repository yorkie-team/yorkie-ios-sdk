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

import XCTest
@testable import Yorkie

final class JONSTreeTests: XCTestCase {
    func test_json_string() throws {
        let textNode = JSONTreeTextNode(value: "X")

        XCTAssertEqual(textNode.toJSONString, "{\"type\":\"text\",\"value\":\"X\"}")

        let elementNode = JSONTreeElementNode(type: "doc",
                                              children: [
                                                  JSONTreeElementNode(type: "p"),
                                                  JSONTreeTextNode(value: "Y")
                                              ], attributes: [
                                                  "intValue": 100,
                                                  "doubleValue": 10.5,
                                                  "boolean": true,
                                                  "string": "testString",
                                                  "point": ["x": 100, "y": 200]
                                              ])

        XCTAssertEqual(elementNode.toJSONString, "{\"attributes\":{\"boolean\":true,\"doubleValue\":10.5,\"intValue\":100,\"point\":{\"x\":100,\"y\":200},\"string\":\"testString\"},\"children\":[{\"children\":[],\"type\":\"p\"},{\"type\":\"text\",\"value\":\"Y\"}],\"type\":\"doc\"}")
    }

    func test_json_newline_string() throws {
        let textNode = JSONTreeTextNode(value: "\n")

        XCTAssertEqual(textNode.toJSONString, "{\"type\":\"text\",\"value\":\"\\n\"}")
    }

    func test_json_jsonSerialiaztion() throws {
        let attr = RHT()

        attr.set(key: "list", value: "{\"@ctype\":\"paragraphListStyle\",\"level\":0,\"type\":\"bullet\"}", executedAt: TimeTicket.initial)

        let crdtTreeNode = CRDTTreeNode(id: .initial, type: "listNode", children: nil, attributes: attr)
        let jsonTreeNode = crdtTreeNode.toJSONTreeNode

        XCTAssertEqual(crdtTreeNode.toJSONString, jsonTreeNode.toJSONString)
    }
}
