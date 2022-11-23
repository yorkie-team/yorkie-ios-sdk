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
    let rpcAddress = RPCAddress(host: "localhost", port: 8080)

    var c1: Client!
    var c2: Client!
    var d1: Document!
    var d2: Document!

    func test_can_be_increased_by_Counter_type() async throws {
        let doc = Document(key: "test-doc")

        await doc.update { root in
            root.age = JSONCounter(value: Int32(1))
            root.length = JSONCounter(value: Int64(10))
            do {
                try (root.age as! JSONCounter<Int32>).increase(value: Int32(5))
                try (root.length as! JSONCounter<Int64>).increase(value: Int64(3))
            } catch {}
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        let age = await doc.getRoot().age as? JSONCounter<Int32>

        XCTAssert(age!.value == 6)

        var result = await doc.toSortedJSON()
        XCTAssert(result == "{\"age\":6,\"length\":13}")

        await doc.update { root in
            do {
                try (root.age as! JSONCounter<Int32>).increase(value: Int32(1)).increase(value: Int32(1))
                try (root.length as! JSONCounter<Int64>).increase(value: Int64(3)).increase(value: Int64(1))
            } catch {}
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        result = await doc.toSortedJSON()
        XCTAssert(result == "{\"age\":8,\"length\":17}")

        let expectation = XCTestExpectation(description: "failed Test")
        var failedTestResult = false

        await doc.update { root in
            do {
                try (root.age as! JSONCounter<Int32>).increase(value: Int64(1))
            } catch {
                failedTestResult = true
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 1)

        XCTAssert(failedTestResult)
    }

    func test_can_sync_counter() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)"

        do {
            self.c1 = try Client(rpcAddress: self.rpcAddress, options: options)
            self.c2 = try Client(rpcAddress: self.rpcAddress, options: options)
        } catch {
            XCTFail(error.localizedDescription)
            return
        }

        self.d1 = Document(key: docKey)
        self.d2 = Document(key: docKey)

        try await self.c1.activate()
        try await self.c2.activate()

        try await self.c1.attach(self.d1, false)
        try await self.c2.attach(self.d2, false)

        try await Task.sleep(nanoseconds: 1_000_000_000)

        await self.d1.update { root in
            root.age = JSONCounter(value: Int32(1))
        }

        await self.d2.update { root in
            root.length = JSONCounter(value: Int64(10))
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        var result1 = await self.d1.toSortedJSON()
        var result2 = await self.d2.toSortedJSON()

        XCTAssert(result1 == result2)

        await self.d1.update { root in
            do {
                try (root.age as! JSONCounter<Int32>).increase(value: Int32(5))
                try (root.length as! JSONCounter<Int64>).increase(value: Int64(3))
            } catch {}
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        result1 = await self.d1.toSortedJSON()
        result2 = await self.d2.toSortedJSON()

        XCTAssert(result1 == result2)

        try await self.c1.detach(self.d1)
        try await self.c2.detach(self.d2)

        try await self.c1.deactivate()
        try await self.c2.deactivate()
    }

    func test_can_sync_counter_with_array() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)"

        do {
            self.c1 = try Client(rpcAddress: self.rpcAddress, options: options)
            self.c2 = try Client(rpcAddress: self.rpcAddress, options: options)
        } catch {
            XCTFail(error.localizedDescription)
            return
        }

        self.d1 = Document(key: docKey)
        self.d2 = Document(key: docKey)

        try await self.c1.activate()
        try await self.c2.activate()

        try await self.c1.attach(self.d1, false)
        try await self.c2.attach(self.d2, false)

        try await Task.sleep(nanoseconds: 1_000_000_000)

        await self.d1.update { root in
            root.counts = [JSONCounter(value: Int32(1))]
        }

        await self.d1.update { root in
            (root.counts as! JSONArray).append(JSONCounter(value: Int32(10)))
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        var result1 = await self.d1.toSortedJSON()
        var result2 = await self.d2.toSortedJSON()

        XCTAssert(result1 == result2)
        XCTAssert(result1 == "{\"counts\":[1,10]}")

        await self.d1.update { root in
            do {
                try ((root.counts as! JSONArray)[0] as! JSONCounter<Int32>).increase(value: Int32(5))
                try ((root.counts as! JSONArray)[1] as! JSONCounter<Int32>).increase(value: Int32(3))
            } catch {}
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

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
