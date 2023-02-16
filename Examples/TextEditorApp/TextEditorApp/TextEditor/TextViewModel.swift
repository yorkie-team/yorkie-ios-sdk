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

class TextViewModel {
    private var cancellables = Set<AnyCancellable>()

    private var client: Client

    private let document: Document
    private weak var storage: NSTextStorage?
    private let defaultFont: UIFont

    private var textEvent = PassthroughSubject<[TextChange], Never>()

    init(_ storage: NSTextStorage, _ defaultFont: UIFont) {
        self.storage = storage
        self.defaultFont = defaultFont

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
            textEvent.sink { [weak self] events in
                events.filter { $0.actor != clientID }.forEach {
                    switch $0.type {
                    case .content:
                        let range = NSRange(location: $0.from, length: $0.to - $0.from)
                        let content = $0.content ?? ""
                        Task { [weak self] in
                            print("#### text event range: \(range), context: \(content)")

                            await self?.updateText(range, content)
                        }
                    case .style:
                        break
                    case .selection:
                        break
                    }
                }
            }.store(in: &self.cancellables)

            await(self.document.getRoot().content as? JSONText)?.setEventStream(eventStream: textEvent)

            await self.syncText()
        }
    }

    @MainActor
    func syncText() async {
        let range = NSRange(location: 0, length: self.storage?.length ?? 0)
        let context = (await self.document.getRoot().content as? JSONText)?.plainText ?? ""

        self.updateText(range, context)
    }

    @MainActor
    func updateText(_ range: NSRange, _ context: String) {
        print("#### updateText: \(range), \(context)")

        self.storage?.beginEditing()

        self.storage?.replaceCharacters(in: range, with: context)
        if context.isEmpty == false {
            let attrRange = NSRange(location: range.location, length: context.count)

            self.storage?.addAttributes([.font: self.defaultFont], range: attrRange)
            self.storage?.fixAttributes(in: attrRange)
        }

        self.storage?.endEditing()
    }

    func cleanup() async {
        try! await self.client.detach(self.document)
        try! await self.client.deactivate()
    }

    func edit(_ operaitions: [(range: NSRange, content: String)]) {
        Task {
            await self.document.update { root in
                for oper in operaitions {
                    let toIdx = oper.range.location + oper.range.length

                    print("#### edit : from: \(oper.range.location), to: \(toIdx) context: \(oper.content)")

                    if let content = root.content as? JSONText {
                        content.edit(oper.range.location, toIdx, oper.content)
                    }
                }
            }
        }
    }
}
