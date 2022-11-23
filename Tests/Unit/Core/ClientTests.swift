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

import Combine
import XCTest
@testable import Yorkie

class ClientTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    func skip_test_activate_and_deactivate_client_with_key() async throws {
        let clientKey = "\(self.description)-\(Date().description)"
        let rpcAddress = RPCAddress(host: "localhost", port: 8080)

        let options = ClientOptions(key: clientKey)
        let target: Client
        var status = ClientStatus.deactivated

        do {
            target = try Client(rpcAddress: rpcAddress, options: options)
        } catch {
            XCTFail(error.localizedDescription)
            return
        }

        target.eventStream.sink { _ in
        } receiveValue: { event in
            switch event {
            case let event as StatusChangedEvent:
                status = event.value
            default:
                break
            }
        }.store(in: &self.cancellables)

        do {
            try await target.activate()
        } catch {
            XCTFail(error.localizedDescription)
        }

        var isActive = await target.isActive

        XCTAssertTrue(isActive)
        XCTAssertEqual(target.key, clientKey)
        XCTAssert(status == .activated)

        do {
            try await target.deactivate()
        } catch {
            XCTFail(error.localizedDescription)
        }

        isActive = await target.isActive

        XCTAssertFalse(isActive)
        XCTAssert(status == .deactivated)
    }

    func skip_test_activate_and_deactivate_client_without_key() async throws {
        let rpcAddress = RPCAddress(host: "localhost", port: 8080)

        let options = ClientOptions()
        let target: Client
        var status = ClientStatus.deactivated

        do {
            target = try Client(rpcAddress: rpcAddress, options: options)
        } catch {
            XCTFail(error.localizedDescription)
            return
        }

        target.eventStream.sink { _ in
        } receiveValue: { event in
            switch event {
            case let event as StatusChangedEvent:
                status = event.value
            default:
                break
            }
        }.store(in: &self.cancellables)

        try await target.activate()

        var isActive = await target.isActive

        XCTAssertTrue(isActive)
        XCTAssertFalse(target.key.isEmpty)
        XCTAssert(status == .activated)

        try await target.deactivate()

        isActive = await target.isActive

        XCTAssertFalse(isActive)
        XCTAssert(status == .deactivated)
    }

    func skip_test_attach_detach_document_with_key() async throws {
        let clientId = UUID().uuidString
        let rpcAddress = RPCAddress(host: "localhost", port: 8080)

        let options = ClientOptions(key: clientId)
        let target: Client
        var status = ClientStatus.deactivated

        do {
            target = try Client(rpcAddress: rpcAddress, options: options)
        } catch {
            XCTFail(error.localizedDescription)
            return
        }

        target.eventStream.sink { _ in
        } receiveValue: { event in
            print("#### \(event)")
            switch event {
            case let event as StatusChangedEvent:
                status = event.value
            default:
                break
            }
        }.store(in: &self.cancellables)

        do {
            try await target.activate()
        } catch {
            XCTFail(error.localizedDescription)
        }

        var isActive = await target.isActive

        XCTAssertTrue(isActive)
        XCTAssertEqual(target.key, clientId)
        XCTAssert(status == .activated)

        let doc = Document(key: "doc1")

        do {
            try await target.attach(doc)
        } catch {
            XCTFail(error.localizedDescription)
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        do {
            try await target.detach(doc)
        } catch {
            XCTFail(error.localizedDescription)
        }

        do {
            try await target.deactivate()
        } catch {
            XCTFail(error.localizedDescription)
        }

        isActive = await target.isActive

        XCTAssertFalse(isActive)
        XCTAssert(status == .deactivated)
    }
}
