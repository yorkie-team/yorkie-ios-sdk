/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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
import Yorkie

enum ContentState {
    case loading
    case error(TDError)
    case success
}

extension ContentView {
    @Observable
    class ContentViewModel {
        private let jsonDecoder = JSONDecoder()
        private(set) var models = [TodoModel]() {
            didSet {
                self.itemsLeft = self.models.count(where: { $0.completed == false })
            }
        }

        private(set) var itemsLeft = 0
        private(set) var state = ContentState.loading
        @ObservationIgnored private var client: Client
        @ObservationIgnored private let document: Document

        init() {
            self.client = Client(Constant.serverAddress)
            self.document = Document(key: Constant.documentKey)
        }
    }
}

extension ContentView.ContentViewModel {
    func initializeClient() async {
        state = .loading
        do {
            try await client.activate()

            let doc = try await client.attach(self.document)
            self.updateDoc(doc)

            state = .success

            await self.watch()
        } catch {
            state = .error(.cannotInitClient("\(error.localizedDescription)"))
        }
    }

    func watch() async {
        document.subscribe { [weak self]
            event,
                document in
            if case .syncStatusChanged = event.type {
                self?.updateDoc(document)
            }
        }
    }

    func updateDoc(_: Document) {
        if let root = document.getRoot().get(key: "todos") as? JSONArray {
            var _models = [TodoModel]()
            let iterator = root.makeIterator()
            while let i = iterator.next() {
                guard let data = String(reflecting: i).data(using: .utf8) else { return }
                if let model = try? self.jsonDecoder.decode(TodoModel.self, from: data) {
                    _models.append(model)
                }
            }
            self.models = _models
        } else {
            //
        }
    }

    func markAllAsComplete(_ value: Bool) {
        try? self.document.update { root, _ in
            guard let lists = root.todos as? JSONArray else { return }
            let iterator = lists.makeIterator()
            while let next = iterator.next() as? JSONObject {
                next.set(key: "completed", value: value)
            }
        }
    }

    func deleteItem(_ id: String) {
        try? self.document.update { root, _ in
            guard let lists = root.todos as? JSONArray else { return }
            let iterator = lists.makeIterator()
            while let next = iterator.next() as? JSONObject {
                guard let data = String(reflecting: next).data(using: .utf8) else { return }
                if let model = try? self.jsonDecoder.decode(TodoModel.self, from: data), model.id == id {
                    lists.remove(byID: next.getID())
                }
            }
        }
    }

    func addNewTask(_ name: String) {
        try? self.document.update { root, _ in
            let lists = root.todos as? JSONArray
            if lists == nil {
                root.todos = JSONArray()
            }
            guard let lists = root.todos as? JSONArray else { return }
            let model = TodoModel.makeTodo(with: name)

            lists.append(model)
        }
    }

    func updateTask(_ task: String, _ withNewName: String) {
        try? self.document.update { root, _ in
            guard let lists = root.todos as? JSONArray else { return }
            let iterator = lists.makeIterator()
            while let next = iterator.next() as? JSONObject {
                if (next.get(key: "id") as? String) == task {
                    next.set(key: "text", value: withNewName)
                    break
                }
            }
        }
    }

    func updateTask(_ task: String, complete: Bool) {
        try? self.document.update { root, _ in
            guard let lists = root.todos as? JSONArray else { return }
            let iterator = lists.makeIterator()
            while let next = iterator.next() as? JSONObject {
                if (next.get(key: "id") as? String) == task {
                    next.set(key: "completed", value: complete)
                    break
                }
            }
        }
    }

    func removeAllCompleted() {
        try? self.document.update { root, _ in
            guard let lists = root.todos as? JSONArray else { return }
            let iterator = lists.makeIterator()
            while let next = iterator.next() as? JSONObject {
                if (next.get(key: "completed") as? Bool) == true {
                    lists.remove(byID: next.getID())
                }
            }
        }
    }
}
