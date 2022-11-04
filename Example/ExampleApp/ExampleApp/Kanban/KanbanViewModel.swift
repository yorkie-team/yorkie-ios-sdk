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

import Foundation

class KanbanViewModel: ObservableObject {
    @Published
    private(set) var items: [KanbanColumn] = []

    func addColumn(title: String) {
        let column = KanbanColumn(title: title, cards: [])
        self.items.append(column)
    }

    func deleteColumn(_ column: KanbanColumn) {
        self.items.removeAll {
            $0.id == column.id
        }
    }

    func addCard(title: String, columnId: String) {
        guard let index = self.items.firstIndex(where: { $0.id == columnId }) else { return }

        let card = KanbanCard(columnId: columnId, title: title)
        var cards = self.items[index].cards
        cards.append(card)
        self.items[index].cards = cards
    }

    func deleteCard(_ card: KanbanCard) {
        guard let columnIndex = self.items.firstIndex(where: { $0.id == card.columnId }) else { return }

        var cards = self.items[columnIndex].cards
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards.remove(at: index)
        self.items[columnIndex].cards = cards
    }
}
