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

import Connect
import XCTest
@testable import Yorkie

class GRPCTests: XCTestCase {
    func test_connect_yorkie() async {
        let testClientKey = UUID().uuidString

        let protocolClient = ProtocolClient(httpClient: URLSessionHTTPClient(),
                                            config: ProtocolClientConfig(host: "http://localhost:8080",
                                                                         networkProtocol: .connect,
                                                                         codec: ProtoCodec()))

        let client = YorkieServiceClient(client: protocolClient)

        let activateRequest = ActivateClientRequest.with { $0.clientKey = testClientKey }
        let activateResponse = await client.activateClient(request: activateRequest)
        guard let message = activateResponse.message else {
            XCTFail("The response of activate is nil.")
            return
        }

        let deactivateRequest = DeactivateClientRequest.with { $0.clientID = message.clientID }
        guard (await client.deactivateClient(request: deactivateRequest)).message != nil else {
            XCTFail("The response of deactivate is nil.")
            return
        }
    }
}
