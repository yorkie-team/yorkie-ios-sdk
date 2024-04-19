/*
 * Copyright 2024 The Yorkie Authors. All rights reserved.
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

final class URLTests: XCTestCase {
    func test_url_to_rpc_address() {
        var rpc = URL(string: "http://yorkie.dev")?.toRPCAddress
        XCTAssertEqual(rpc, RPCAddress(host: "yorkie.dev", port: 80))

        rpc = URL(string: "https://yorkie.dev")?.toRPCAddress
        XCTAssertEqual(rpc, RPCAddress(host: "yorkie.dev", port: 443))

        rpc = URL(string: "https://yorkie.dev:8080")?.toRPCAddress
        XCTAssertEqual(rpc, RPCAddress(host: "yorkie.dev", port: 8080))

        rpc = URL(string: "yorkie.dev")?.toRPCAddress
        XCTAssertEqual(rpc, nil)
    }
}
