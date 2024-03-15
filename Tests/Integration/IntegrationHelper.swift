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

func withTwoClientsAndDocuments(_ title: String, _ callback: (Client, Document, Client, Document) async throws -> Void) async throws {
    let rpcAddress = RPCAddress(host: "localhost", port: 8080)

    let options = ClientOptions()
    let docKey = "\(Date().description)-\(title)".toDocKey

    let c1 = Client(rpcAddress: rpcAddress, options: options)
    let c2 = Client(rpcAddress: rpcAddress, options: options)

    try await c1.activate()
    try await c2.activate()

    let d1 = Document(key: docKey)
    let d2 = Document(key: docKey)

    try await c1.attach(d1, [:], false)
    try await c2.attach(d2, [:], false)

    try await callback(c1, d1, c2, d2)

    try await c1.detach(d1)
    try await c2.detach(d2)

    try await c1.deactivate()
    try await c2.deactivate()
}

protocol OperationInfoForDebug {}

struct TreeEditOpInfoForDebug: OperationInfoForDebug {
    let from: Int?
    let to: Int?
    let value: [any JSONTreeNode]?
    let fromPath: [Int]?
    let toPath: [Int]?

    func compare(_ operation: TreeEditOpInfo) {
        if let value = from {
            XCTAssertEqual(value, operation.from)
        }
        if let value = to {
            XCTAssertEqual(value, operation.to)
        }
        if let value = value {
            XCTAssertEqual(value.count, operation.value.count)
            if operation.value.count - 1 >= 0 {
                for idx in 0 ... operation.value.count - 1 {
                    if let exp = value[idx] as? JSONTreeTextNode, let oper = operation.value[idx] as? JSONTreeTextNode {
                        XCTAssertEqual(exp, oper)
                    } else if let exp = value[idx] as? JSONTreeElementNode, let oper = operation.value[idx] as? JSONTreeElementNode {
                        XCTAssertEqual(exp, oper)
                    } else {
                        XCTAssertFalse(true)
                    }
                }
            }
        }
        if let value = fromPath {
            XCTAssertEqual(value, operation.fromPath)
        }
        if let value = toPath {
            XCTAssertEqual(value, operation.toPath)
        }
    }
}

struct TreeStyleOpInfoForDebug: OperationInfoForDebug {
    let from: Int?
    let to: Int?
    let value: [String: Codable]?
    let fromPath: [Int]?

    func compare(_ operation: TreeStyleOpInfo) {
        if let value = from {
            XCTAssertEqual(value, operation.from)
        }
        if let value = to {
            XCTAssertEqual(value, operation.to)
        }
        if let value = value {
            XCTAssertEqual(value.count, operation.value.count)
            if operation.value.count - 1 >= 0 {
                for key in operation.value.keys {
                    XCTAssertEqual(value[key]?.toJSONString, convertToJSONString(operation.value[key] ?? NSNull()))
                }
            }
        }
        if let value = fromPath {
            XCTAssertEqual(value, operation.fromPath)
        }
    }
}

func subscribeDocs(_ d1: Document, _ d2: Document, _ d1Expected: [any OperationInfoForDebug]?, _ d2Expected: [any OperationInfoForDebug]?) async {
    var d1Operations: [any OperationInfo] = []
    var d1Index = 0

    await d1.subscribe("$.t") { event in
        if let event = event as? LocalChangeEvent {
            d1Operations.append(contentsOf: event.value.operations)
        } else if let event = event as? RemoteChangeEvent {
            d1Operations.append(contentsOf: event.value.operations)
        }

        while d1Index <= d1Operations.count - 1 {
            if let d1Expected, let expected = d1Expected[safe: d1Index] as? TreeEditOpInfoForDebug, let operation = d1Operations[safe: d1Index] as? TreeEditOpInfo {
                expected.compare(operation)
            } else if let d1Expected, let expected = d1Expected[safe: d1Index] as? TreeStyleOpInfoForDebug, let operation = d1Operations[safe: d1Index] as? TreeStyleOpInfo {
                expected.compare(operation)
            }

            d1Index += 1
        }
    }

    var d2Operations: [any OperationInfo] = []
    var d2Index = 0

    await d2.subscribe("$.t") { event in
        if let event = event as? LocalChangeEvent {
            d2Operations.append(contentsOf: event.value.operations.compactMap { $0 as? TreeEditOpInfo })
        } else if let event = event as? RemoteChangeEvent {
            d2Operations.append(contentsOf: event.value.operations.compactMap { $0 as? TreeEditOpInfo })
        }

        while d2Index <= d2Operations.count - 1 {
            if let d2Expected, let expected = d2Expected[safe: d2Index] as? TreeEditOpInfoForDebug, let operation = d2Operations[safe: d2Index] as? TreeEditOpInfo {
                expected.compare(operation)
            } else if let d2Expected, let expected = d2Expected[safe: d1Index] as? TreeStyleOpInfoForDebug, let operation = d2Operations[safe: d1Index] as? TreeStyleOpInfo {
                expected.compare(operation)
            }

            d2Index += 1
        }
    }
}
