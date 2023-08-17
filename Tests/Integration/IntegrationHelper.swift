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

import Foundation
@testable import Yorkie

func withTwoClientsAndDocuments(_ title: String, _ callback: (Client, Document, Client, Document) async throws -> Void) async throws {
    let rpcAddress = RPCAddress(host: "localhost", port: 8080)

    let options = ClientOptions()
    let docKey = "\(title)-\(Date().description)".toDocKey

    let c1 = Client(rpcAddress: rpcAddress, options: options)
    let c2 = Client(rpcAddress: rpcAddress, options: options)

    try await c1.activate()
    try await c2.activate()

    let d1 = Document(key: docKey)
    let d2 = Document(key: docKey)

    try await c1.attach(d1)
    try await c2.attach(d2)

    try await callback(c1, d1, c2, d2)

    try await c1.detach(d1)
    try await c2.detach(d2)

    try await c1.deactivate()
    try await c2.deactivate()
}
