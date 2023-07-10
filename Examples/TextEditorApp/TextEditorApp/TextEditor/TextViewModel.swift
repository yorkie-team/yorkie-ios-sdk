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
    private var cancellables = Set<AnyCancellable>()
    private var client: Client
    private let document: Document
    private var textEventStream = PassthroughSubject<[TextChange], Never>()

    private weak var operationSubject: PassthroughSubject<[TextOperation], Never>?

    init(_ operationSubject: PassthroughSubject<[TextOperation], Never>) {
        self.operationSubject = operationSubject

        // create client with RPCAddress.
        self.client = Client(rpcAddress: RPCAddress(host: "localhost", port: 8080),
                             options: ClientOptions())

        // create a document
        self.document = Document(key: "codemirror")

        Task {
            // activate client.
            try! await self.client.activate()

            // attach the document into the client.
            try! await self.client.attach(self.document)

            try await self.document.update { root in
                var text = root.content as? JSONText
                if text == nil {
                    root.content = JSONText()
                    text = root.content as? JSONText
                }
            }

            // subscribe document event.
            let clientID = await self.client.id

            await self.document.eventStream.sink { [weak self] event in
                switch event.type {
                case .snapshot, .remoteChange:
                    Task { [weak self] in
                        await self?.syncText()
                    }
                default:
                    break
                }
            }.store(in: &self.cancellables)

            // define event handler that apply remote changes to local
            self.textEventStream.sink { [weak self] events in
                var textChanges = [TextOperation]()

                events.filter { $0.actor != clientID }.forEach {
                    switch $0.type {
                    case .content:
                        break
                    case .style:
                        break
                    case .selection:
                        let range: NSRange

                        if $0.from <= $0.to {
                            range = NSRange(location: $0.from, length: $0.to - $0.from)
                        } else {
                            range = NSRange(location: $0.to, length: $0.from - $0.to)
                        }

                        textChanges.append(.select(range: range, actorID: $0.actor))
                    }
                }

                if textChanges.isEmpty == false {
                    self?.operationSubject?.send(textChanges)
                }

            }.store(in: &self.cancellables)

            await(self.document.getRoot().content as? JSONText)?.setEventStream(eventStream: self.textEventStream)

            await self.syncText()
        }
    }

    func syncText() async {
        let context = (await self.document.getRoot().content as? JSONText)?.plainText ?? ""

        self.operationSubject?.send([.edit(range: nil, content: context)])
    }

    func cleanup() async {
        try! await self.client.detach(self.document)
        try! await self.client.deactivate()
    }

    func edit(_ operaitions: [TextOperation]) async {
        try? await self.document.update { root in
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

                    guard content.plainText.count > fromIdx, content.plainText.count > toIdx else {
                        return
                    }

                    content.select(fromIdx, toIdx)
                }
            }
        }
    }

    func pause() async {
        try? await self.client.pauseRemoteChanges(doc: self.document)
    }

    func resume() async {
        try? await self.client.resumeRemoteChanges(doc: self.document)
    }
}
