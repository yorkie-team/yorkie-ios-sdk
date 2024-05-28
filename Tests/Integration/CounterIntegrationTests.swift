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

// swiftlint: disable force_cast
final class CounterIntegrationTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    var c1: Client!
    var c2: Client!
    var d1: Document!
    var d2: Document!

    func test_can_be_increased_by_Counter_type() async throws {
        let doc = Document(key: "test-doc")

        try await doc.update { root, _ in
            root.age = JSONCounter(value: Int32(1))
            root.length = JSONCounter(value: Int64(10))
            (root.age as! JSONCounter<Int32>).increase(value: Int32(5))
            (root.length as! JSONCounter<Int64>).increase(value: Int64(3))
        }

        let age = await doc.getRoot().age as? JSONCounter<Int32>

        XCTAssert(age!.value == 6)

        var result = await doc.toSortedJSON()
        XCTAssert(result == "{\"age\":6,\"length\":13}")

        try await doc.update { root, _ in
            (root.age as! JSONCounter<Int32>).increase(value: Int32(1)).increase(value: Int32(1))
            (root.length as! JSONCounter<Int64>).increase(value: Int64(3)).increase(value: Int64(1))
        }

        result = await doc.toSortedJSON()
        XCTAssert(result == "{\"age\":8,\"length\":17}")

        try await doc.update { root, _ in
            (root.age as! JSONCounter<Int32>).increase(value: Int64(1))
        }
        result = await doc.toSortedJSON()
        XCTAssertEqual(result, "{\"age\":9,\"length\":17}")
    }

    func test_can_sync_counter() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(self.rpcAddress)
        self.c2 = Client(self.rpcAddress)

        self.d1 = Document(key: docKey)
        self.d2 = Document(key: docKey)

        try await self.c1.activate()
        try await self.c2.activate()

        try await self.c1.attach(self.d1, [:], .manual)
        try await self.c2.attach(self.d2, [:], .manual)

        try await self.d1.update { root, _ in
            root.age = JSONCounter(value: Int32(1))
        }

        try await self.d2.update { root, _ in
            root.length = JSONCounter(value: Int64(10))
        }

        try await self.c1.sync()
        try await self.c2.sync()
        try await self.c1.sync()

        var result1 = await self.d1.toSortedJSON()
        var result2 = await self.d2.toSortedJSON()

        XCTAssert(result1 == result2)

        try await self.d1.update { root, _ in
            (root.age as! JSONCounter<Int32>).increase(value: Int32(5))
            (root.length as! JSONCounter<Int64>).increase(value: Int64(3))
        }

        try await self.c1.sync()
        try await self.c2.sync()

        result1 = await self.d1.toSortedJSON()
        result2 = await self.d2.toSortedJSON()

        XCTAssertEqual(result1, result2)

        try await self.c1.detach(self.d1)
        try await self.c2.detach(self.d2)

        try await self.c1.deactivate()
        try await self.c2.deactivate()
    }

    func test_can_sync_counter_with_array() async throws {
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(self.rpcAddress)
        self.c2 = Client(self.rpcAddress)

        self.d1 = Document(key: docKey)
        self.d2 = Document(key: docKey)

        try await self.c1.activate()
        try await self.c2.activate()

        try await self.c1.attach(self.d1, [:], .manual)
        try await self.c2.attach(self.d2, [:], .manual)

        try await self.d1.update { root, _ in
            root.counts = [JSONCounter(value: Int32(1))]
        }

        try await self.d1.update { root, _ in
            (root.counts as! JSONArray).append(JSONCounter(value: Int32(10)))
        }

        try await self.c1.sync()
        try await self.c2.sync()

        var result1 = await self.d1.toSortedJSON()
        var result2 = await self.d2.toSortedJSON()

        XCTAssert(result1 == result2)
        XCTAssert(result1 == "{\"counts\":[1,10]}")

        try await self.d1.update { root, _ in
            ((root.counts as! JSONArray)[0] as! JSONCounter<Int32>).increase(value: Int32(5))
            ((root.counts as! JSONArray)[1] as! JSONCounter<Int32>).increase(value: Int32(3))
        }

        try await self.c1.sync()
        try await self.c2.sync()

        result1 = await self.d1.toSortedJSON()
        result2 = await self.d2.toSortedJSON()

        XCTAssert(result1 == result2)
        XCTAssert(result1 == "{\"counts\":[6,13]}")

        try await self.c1.detach(self.d1)
        try await self.c2.detach(self.d2)

        try await self.c1.deactivate()
        try await self.c2.deactivate()
    }
}

// swiftlint: enable force_cast
