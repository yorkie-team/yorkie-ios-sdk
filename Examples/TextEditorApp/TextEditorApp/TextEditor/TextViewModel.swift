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

import Combine
import Foundation
import UIKit
import Yorkie

enum TextOperation {
    case edit(range: NSRange?, content: String)
    case select(range: NSRange, actorID: String)
}

class TextViewModel {
    private var client: Client
    private let document: Document

    private weak var operationSubject: PassthroughSubject<[TextOperation], Never>?

    init(_ operationSubject: PassthroughSubject<[TextOperation], Never>) {
        self.operationSubject = operationSubject

        // create client with RPCAddress.
        self.client = Client("http://localhost:8080")

        // create a document
        self.document = Document(key: "codemirror")

        Task {
            // activate client.
            try! await self.client.activate()

            // attach the document into the client.
            try! await self.client.attach(self.document)

            try await self.document.update { root, _ in
                var text = root.content as? JSONText
                if text == nil {
                    root.content = JSONText()
                    text = root.content as? JSONText
                }
            }

            // subscribe document event.
            await self.document.subscribe { [weak self] event, _ in
                switch event.type {
                case .snapshot, .remoteChange:
                    Task { [weak self] in
                        await self?.syncText()
                    }
                default:
                    break
                }
            }

            await self.document.subscribePresence(.others) { [weak self] event, _ in
                if let event = event as? PresenceChangedEvent {
                    if let fromPos: TextPosStruct = self?.decodePresence(event.value.presence["from"]),
                       let toPos: TextPosStruct = self?.decodePresence(event.value.presence["to"])
                    {
                        Task { [weak self] in
                            if let (fromIdx, toIdx) = try? await(self?.document.getRoot().content as? JSONText)?.posRangeToIndexRange((fromPos, toPos)) {
                                let range: NSRange

                                if fromIdx <= toIdx {
                                    range = NSRange(location: fromIdx, length: toIdx - fromIdx)
                                } else {
                                    range = NSRange(location: toIdx, length: fromIdx - toIdx)
                                }

                                self?.operationSubject?.send([.select(range: range, actorID: event.value.clientID)])
                            }
                        }
                    }
                }
            }

            await self.syncText()
        }
    }

    func syncText() async {
        let context = (await self.document.getRoot().content as? JSONText)?.toString ?? ""

        self.operationSubject?.send([.edit(range: nil, content: context)])
    }

    func cleanup() async {
        do {
            try await self.client.detach(self.document)
            try await self.client.deactivate()
        } catch {
            // handle error
//            print(error.localizedDescription)
        }
    }

    func edit(_ operaitions: [TextOperation]) async {
        try? await self.document.update { root, presence in
            guard let content = root.content as? JSONText else {
                return
            }

            for operation in operaitions {
                switch operation {
                case .edit(let range, let contentString):
                    guard let range = range else {
                        return
                    }

                    let toIdx = range.location + range.length

                    content.edit(range.location, toIdx, contentString)
                case .select(let range, _):
                    let fromIdx = range.location
                    let toIdx = range.location + range.length

                    guard ((root.content as? JSONText)?.length ?? 0) >= fromIdx else {
                        return
                    }

                    if let range = try? (root.content as? JSONText)?.indexRangeToPosRange((fromIdx, toIdx)) {
                        presence.set(["from": range.0, "to": range.1])
                    }
                }
            }
        }
    }

    func pause() async throws {
        try await self.client.changeSyncMode(self.document, .realtimePushOnly)
    }

    func resume() async throws {
        try await self.client.changeSyncMode(self.document, .realtime)
    }

    private func decodePresence<T: Decodable>(_ dictionary: Any?) -> T? {
        guard let dictionary = dictionary as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [])
        else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }
}
