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
import Foundation
import Yorkie

class KanbanViewModel: ObservableObject {
    private(set) var defaultColumns: [KanbanColumn] = [
        KanbanColumn(title: "todo", cards: [
            KanbanCard(title: "walking"),
            KanbanCard(title: "running")
        ]),
        KanbanColumn(title: "mart", cards: [
            KanbanCard(title: "snaks")
        ])
    ]

    private var client: Client

    @Published
    private(set) var columns: [KanbanColumn] = []

    private let document: Document

    init() {
        self.client = Client(rpcAddress: RPCAddress(host: "localhost", port: 8080),
                             options: ClientOptions())

        let docKey = "KanbanViewModel-8"
        self.document = Document(key: docKey)

        Task { [weak self] in
            guard let self else { return }

            await self.document.subscribe { _ in
                Task { @MainActor [weak self] in
                    guard let self, let lists = await self.document.getRoot().lists as? JSONArray else { return }

                    self.columns = lists.compactMap { each -> KanbanColumn? in
                        guard let column = each as? JSONObject,
                              let cardArray = column.cards as? JSONArray
                        else {
                            return nil
                        }

                        let cards = cardArray.compactMap { each -> KanbanCard? in
                            guard let card = each as? JSONObject else { return nil }
                            return KanbanCard(id: card.getID(), columnId: column.getID(), title: card.title as! String)
                        }
                        return KanbanColumn(id: column.getID(), title: column.title as! String, cards: cards)
                    }
                }
            }

            Task {
                try! await self.client.activate()
                try! await self.client.attach(self.document)
            }
        }
    }

    func addColumn(title: String) {
        Task {
            try? await self.document.update { root, _ in
                var lists = root.lists as? JSONArray
                if lists == nil {
                    root.lists = JSONArray()
                    lists = root.lists as? JSONArray
                }

                let column = KanbanColumn(title: title)
                lists!.append(column)
            }
        }
    }

    func deleteColumn(_ column: KanbanColumn) {
        Task {
            try? await self.document.update { root, _ in
                guard let lists = root.lists as? JSONArray else { return }
                lists.remove(byID: column.id)
            }
        }
    }

    func addCard(title: String, columnId: TimeTicket) {
        Task {
            try? await self.document.update { root, _ in
                guard let lists = root.lists as? JSONArray,
                      let column = lists.getElement(byID: columnId) as? JSONObject,
                      let cards = column.cards as? JSONArray
                else {
                    return
                }

                let card = KanbanCard(columnId: columnId, title: title)
                cards.append(card)
            }
        }
    }

    func deleteCard(_ card: KanbanCard) {
        Task {
            try? await self.document.update { root, _ in
                guard let lists = root.lists as? JSONArray,
                      let column = lists.getElement(byID: card.columnId) as? JSONObject,
                      let cards = column.cards as? JSONArray
                else {
                    return
                }

                cards.remove(byID: card.id)
            }
        }
    }
}
