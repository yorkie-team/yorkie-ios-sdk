/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
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

import Connect
import XCTest
@testable import Yorkie

/// Covers the mocking-only request observer / response hook seam on `YorkieService`. No server is
/// needed: the RPC is made against an address nothing listens on, so the call fails, and the seam
/// is checked on the parts that do not depend on the answer.
final class YorkieServiceTestSeamTests: XCTestCase {
    private let method = YorkieServiceClient.Metadata.Methods.pushPullChanges

    private func makeService(mocking: Bool) -> YorkieService {
        let protocolClient = ProtocolClient(
            httpClient: URLSessionHTTPClient(),
            config: ProtocolClientConfig(host: "http://127.0.0.1:1", networkProtocol: .connect, codec: ProtoCodec())
        )
        return YorkieService(rpcClient: YorkieServiceClient(client: protocolClient), isMockingEnabled: mocking)
    }

    func test_should_observe_the_request_when_mocking_is_enabled() async {
        let service = self.makeService(mocking: true)
        var observed: [String] = []
        service.observeRequests(for: self.method) { request in
            if let request = request as? Yorkie_V1_PushPullChangesRequest {
                observed.append(request.documentID)
            }
        }

        var request = Yorkie_V1_PushPullChangesRequest()
        request.documentID = "doc-1"
        _ = await service.pushPullChanges(request: request)

        XCTAssertEqual(observed, ["doc-1"])
    }

    func test_should_not_observe_the_request_when_mocking_is_disabled() async {
        let service = self.makeService(mocking: false)
        var observed = 0
        service.observeRequests(for: self.method) { _ in observed += 1 }

        _ = await service.pushPullChanges(request: Yorkie_V1_PushPullChangesRequest())

        XCTAssertEqual(observed, 0)
    }

    func test_should_skip_the_response_hook_when_the_rpc_fails() async {
        let service = self.makeService(mocking: true)
        var hooked = 0
        service.setResponseHook(for: self.method) { _ in hooked += 1 }

        let response = await service.pushPullChanges(request: Yorkie_V1_PushPullChangesRequest())

        XCTAssertNotNil(response.error)
        XCTAssertEqual(hooked, 0)
    }

    func test_should_not_observe_when_a_mock_error_short_circuits_the_call() async {
        let service = self.makeService(mocking: true)
        var observed = 0
        service.observeRequests(for: self.method) { _ in observed += 1 }
        service.setMockError(for: self.method, error: ConnectError(code: .unavailable, message: "mock", exception: nil, details: [], metadata: [:]))

        let response = await service.pushPullChanges(request: Yorkie_V1_PushPullChangesRequest())

        XCTAssertEqual(response.error?.code, .unavailable)
        XCTAssertEqual(observed, 0)
    }

    // The seams are armed from a test's actor and read from whichever task makes the call. The
    // assertion is the absence of a data race, which the thread sanitizer reports
    // (`swift test --sanitize=thread --filter YorkieServiceTestSeamTests`).
    func test_should_survive_arming_the_seams_while_calls_are_in_flight() async {
        let service = self.makeService(mocking: true)
        let method = self.method
        let error = ConnectError(code: .unavailable, message: "mock", exception: nil, details: [], metadata: [:])

        let answered = await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 4 {
                group.addTask {
                    for _ in 0 ..< 100 {
                        service.setMockError(for: method, error: error, count: 2)
                        service.observeRequests(for: method) { _ in }
                        service.setResponseHook(for: method) { _ in }
                        service.observeRequests(for: method, nil)
                    }
                    return 0
                }
            }
            for _ in 0 ..< 4 {
                group.addTask {
                    var count = 0
                    for _ in 0 ..< 25 {
                        let response = await service.pushPullChanges(request: Yorkie_V1_PushPullChangesRequest())
                        if response.error != nil { count += 1 }
                    }
                    return count
                }
            }
            return await group.reduce(0, +)
        }

        XCTAssertEqual(answered, 100, "every call is answered, by the mock or by the failed RPC")
    }
}
