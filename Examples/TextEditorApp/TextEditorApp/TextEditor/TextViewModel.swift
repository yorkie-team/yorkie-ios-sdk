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

struct TextEditOperation {
    let range: NSRange?
    let content: String
}

class TextViewModel {
    private var cancellables = Set<AnyCancellable>()
    private var client: Client
    private let document: Document
    private var textEventStream = PassthroughSubject<[TextChange], Never>()

    private weak var operationSubject: PassthroughSubject<[TextEditOperation], Never>?

    init(_ operationSubject: PassthroughSubject<[TextEditOperation], Never>) {
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

            await self.document.update { root in
                var text = root.content as? JSONText
                if text == nil {
                    root.content = JSONText()
                    text = root.content as? JSONText
                }
            }

            // subscribe document event.
            let clientID = await self.client.id

            await self.document.eventStream.sink { [weak self] event in
                if event.type == .snapshot {
                    Task { [weak self] in
                        await self?.syncText()
                    }
                }
            }.store(in: &self.cancellables)

            // define event handler that apply remote changes to local
            textEventStream.sink { [weak self] events in
                var textChanges = [TextEditOperation]()

                events.filter { $0.actor != clientID }.forEach {
                    switch $0.type {
                    case .content:
                        let range = NSRange(location: $0.from, length: $0.to - $0.from)
                        let content = $0.content ?? ""

                        textChanges.append(TextEditOperation(range: range, content: content))
                    case .style:
                        break
                    case .selection:
                        break
                    }
                }

                self?.operationSubject?.send(textChanges)

            }.store(in: &self.cancellables)

            await(self.document.getRoot().content as? JSONText)?.setEventStream(eventStream: textEventStream)

            await self.syncText()
        }
    }

    func syncText() async {
        let context = (await self.document.getRoot().content as? JSONText)?.plainText ?? ""

        self.operationSubject?.send([TextEditOperation(range: nil, content: context)])
    }

    func cleanup() async {
        try! await self.client.detach(self.document)
        try! await self.client.deactivate()
    }

    func edit(_ operaitions: [TextEditOperation]) async {
        await self.document.update { root in
            for oper in operaitions {
                guard let range = oper.range else {
                    return
                }

                let toIdx = range.location + range.length

                if let content = root.content as? JSONText {
                    content.edit(range.location, toIdx, oper.content)
                }
            }
        }
    }
}
