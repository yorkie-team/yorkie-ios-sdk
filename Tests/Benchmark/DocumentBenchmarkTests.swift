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

import XCTest
@testable import Yorkie

final class DocumentBenchmarkTests: XCTestCase {
    func benchmarkTree(_ size: Int) async {
        let doc = Document(key: "test-doc")

        do {
            try await doc.update { root, _ in
                root.tree = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p")])
                )

                for index in 1 ..< size {
                    try (root.tree as? JSONTree)?.edit(index, index, [JSONTreeTextNode(value: "a")])
                }
            }
        } catch {
            XCTAssert(false, "\(error)")
        }
    }

    func benchmarkTreeDeleteAll(_ size: Int) async {
        let doc = Document(key: "test-doc")

        do {
            try await doc.update { root, _ in
                root.tree = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p")])
                )

                for index in 1 ..< size {
                    try (root.tree as? JSONTree)?.edit(index, index, [JSONTreeTextNode(value: "a")])
                }
            }

            try await doc.update { root, _ in
                try (root.tree as? JSONTree)?.edit(1, size + 1)
            }

            let xml = await(doc.getRoot().tree as? JSONTree)?.toXML()

            XCTAssertEqual(xml, "<doc><p></p></doc>")
        } catch {
            XCTAssert(false, "\(error)")
        }
    }

    func benchmarkTreeSplitGC(_ size: Int) async {
        let doc = Document(key: "test-doc")

        do {
            try await doc.update { root, _ in
                root.tree = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p")])
                )

                for index in 1 ... size {
                    try (root.tree as? JSONTree)?.edit(index, index, [JSONTreeTextNode(value: "a".repeatString(size))])
                }
            }

            try await doc.update { root, _ in
                for index in 1 ... size {
                    try (root.tree as? JSONTree)?.edit(index, index + 1, [JSONTreeTextNode(value: "b")])
                }
            }

            var garbageLen = await doc.getGarbageLength()
            XCTAssertEqual(size, garbageLen)
            let garbageCollect = await doc.garbageCollect(lessThanOrEqualTo: TimeTicket.max)
            XCTAssertEqual(size, garbageCollect)

            garbageLen = await doc.getGarbageLength()
            XCTAssertEqual(0, garbageLen)
        } catch {
            XCTAssert(false, "\(error)")
        }
    }

    func benchmarkTreeEditGC(_ size: Int) async {
        let doc = Document(key: "test-doc")

        do {
            try await doc.update { root, _ in
                root.tree = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(type: "p")])
                )

                for index in 1 ... size {
                    try (root.tree as? JSONTree)?.edit(index, index, [JSONTreeTextNode(value: "a")])
                }
            }

            try await doc.update { root, _ in
                for index in 1 ... size {
                    try (root.tree as? JSONTree)?.edit(index, index + 1, [JSONTreeTextNode(value: "b")])
                }
            }

            var garbageLen = await doc.getGarbageLength()
            XCTAssertEqual(size, garbageLen)
            let garbageCollect = await doc.garbageCollect(lessThanOrEqualTo: TimeTicket.max)
            XCTAssertEqual(size, garbageCollect)

            garbageLen = await doc.getGarbageLength()
            XCTAssertEqual(0, garbageLen)
        } catch {
            XCTAssert(false, "\(error)")
        }
    }

    func testDocumentTree100() throws {
        self.measure {
            let exp = expectation(description: "measure")

            // Put the code you want to measure the time of here.
            Task { @MainActor in
                await self.benchmarkTree(100)
                exp.fulfill()
            }

            wait(for: [exp], timeout: 1)
        }
    }

    func testDocumentTree1000() throws {
        self.measure {
            let exp = expectation(description: "measure")

            // Put the code you want to measure the time of here.
            Task { @MainActor in
                await self.benchmarkTree(1000)
                exp.fulfill()
            }

            wait(for: [exp], timeout: 10)
        }
    }

    func testDocumentTreeDeleteAll1000() throws {
        self.measure {
            let exp = expectation(description: "measure")

            // Put the code you want to measure the time of here.
            Task { @MainActor in
                await self.benchmarkTreeDeleteAll(1000)
                exp.fulfill()
            }

            wait(for: [exp], timeout: 10)
        }
    }

    func testDocumentTreeSplitGC100() throws {
        self.measure {
            let exp = expectation(description: "measure")

            // Put the code you want to measure the time of here.
            Task { @MainActor in
                await self.benchmarkTreeSplitGC(100)
                exp.fulfill()
            }

            wait(for: [exp], timeout: 1)
        }
    }

    func testDocumentTreeSplitGC1000() throws {
        self.measure {
            let exp = expectation(description: "measure")

            // Put the code you want to measure the time of here.
            Task { @MainActor in
                await self.benchmarkTreeSplitGC(1000)
                exp.fulfill()
            }

            wait(for: [exp], timeout: 30)
        }
    }

    func testDocumentTreeEditGC100() throws {
        self.measure {
            let exp = expectation(description: "measure")

            // Put the code you want to measure the time of here.
            Task { @MainActor in
                await self.benchmarkTreeEditGC(100)
                exp.fulfill()
            }

            wait(for: [exp], timeout: 1)
        }
    }

    func testDocumentTreeEditGC1000() throws {
        self.measure {
            let exp = expectation(description: "measure")

            // Put the code you want to measure the time of here.
            Task { @MainActor in
                await self.benchmarkTreeEditGC(1000)
                exp.fulfill()
            }

            wait(for: [exp], timeout: 20)
        }
    }
}

extension String {
    func repeatString(_ count: Int) -> String {
        var repeatedString = ""

        for _ in 0 ..< count {
            repeatedString += self
        }

        return repeatedString
    }
}
