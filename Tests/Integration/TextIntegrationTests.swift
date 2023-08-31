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

final class TextIntegrationTests: XCTestCase {
    let rpcAddress = RPCAddress(host: "localhost", port: 8080)

    var c1: Client!
    var c2: Client!
    var d1: Document!
    var d2: Document!

    func test_can_be_edit_plain_text() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(rpcAddress: self.rpcAddress, options: options)
        self.c2 = Client(rpcAddress: self.rpcAddress, options: options)

        self.d1 = Document(key: docKey)
        self.d2 = Document(key: docKey)

        try await self.c1.activate()
        try await self.c2.activate()

        try await self.c1.attach(self.d1, [:], false)
        try await self.c2.attach(self.d2, [:], false)

        try await self.d1.update { root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "Hello")
            (root.text as? JSONText)?.edit(1, 3, "12")
        }

        try await self.c1.sync()
        try await self.c2.sync()

        let result = (await d2.getRoot().text as? JSONText)?.plainText

        XCTAssertEqual("H12lo", result!)
    }

    func test_can_be_edit_attributed_text() async throws {
        let options = ClientOptions()
        let docKey = "\(self.description)-\(Date().description)".toDocKey

        self.c1 = Client(rpcAddress: self.rpcAddress, options: options)
        self.c2 = Client(rpcAddress: self.rpcAddress, options: options)

        self.d1 = Document(key: docKey)
        self.d2 = Document(key: docKey)

        try await self.c1.activate()
        try await self.c2.activate()

        try await self.c1.attach(self.d1, [:], false)
        try await self.c2.attach(self.d2, [:], false)

        try await self.d1.update { root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "Hello", ["bold": true])
            (root.text as? JSONText)?.edit(1, 3, "12")
            (root.text as? JSONText)?.setStyle(1, 3, ["italic": true])
        }

        try await self.c1.sync()
        try await self.c2.sync()

        try await self.d2.update { root, _ in
            (root.text as? JSONText)?.setStyle(1, 3, ["italic": true])
        }

        try await self.c2.sync()
        try await self.c1.sync()

        let resultD1 = (await d1.getRoot().text as? JSONText)?.values?.compactMap {
            $0.toJSON
        }.joined(separator: ",")
        let resultD2 = (await d2.getRoot().text as? JSONText)?.values?.compactMap {
            $0.toJSON
        }.joined(separator: ",")

        XCTAssertEqual(resultD1, resultD2)
    }
}
