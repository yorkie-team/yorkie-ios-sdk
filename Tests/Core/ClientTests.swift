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

class ClientTests: XCTestCase {
    func test_activate_and_deactivate_client_with_key() async throws {
        let clientId = UUID().uuidString
        let rpcAddress = RPCAddress(host: "localhost", port: 8080)

        let options = ClientOptions(key: clientId)
        let target: Client
        do {
            target = try Client(rpcAddress: rpcAddress, options: options)
        } catch {
            XCTFail(error.localizedDescription)
            return
        }

        do {
            try await target.activate()
        } catch {
            XCTFail(error.localizedDescription)
        }

        XCTAssertTrue(target.isActive)
        XCTAssertEqual(target.key, clientId)

        do {
            try await target.deactivate()
        } catch {
            XCTFail(error.localizedDescription)
        }
        XCTAssertFalse(target.isActive)
    }

    func test_activate_and_deactivate_client_without_key() async throws {
        let rpcAddress = RPCAddress(host: "localhost", port: 8080)

        let options = ClientOptions()
        let target: Client
        do {
            target = try Client(rpcAddress: rpcAddress, options: options)
        } catch {
            XCTFail(error.localizedDescription)
            return
        }

        try await target.activate()

        XCTAssertTrue(target.isActive)
        XCTAssertFalse(target.key.isEmpty)

        try await target.deactivate()
        XCTAssertFalse(target.isActive)
    }
}
