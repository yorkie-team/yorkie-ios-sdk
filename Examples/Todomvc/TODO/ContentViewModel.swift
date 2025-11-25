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

import Combine
import Foundation
import Network
import Yorkie

enum ContentState {
    case loading
    case error(TDError)
    case success
}

extension ContentView {
    class ContentViewModel: ObservableObject {
        var appVersion: String {
            var version = ""
            if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                version.append(appVersion)
            } else {
                print("Could not retrieve app version.")
            }

            // Get the build number (CFBundleVersion)
            if let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                version.append(" build ")
                version.append(buildNumber)
            } else {
                print("Could not retrieve build number.")
            }
            return version
        }

        private let monitor = NWPathMonitor()
        private let queue = DispatchQueue.global(qos: .background)

        var documentKey = Constant.documentKey
        private let jsonDecoder = JSONDecoder()
        private(set) var models = [TodoModel]() {
            didSet {
                self.itemsLeft = self.models.count(where: { $0.completed == false })
            }
        }

        @Published private(set) var itemsLeft = 0
        @Published private(set) var state = ContentState.loading
        private var client: Client
        private var document: Document
        @Published var networkConnected = false

        init() {
            self.client = Client(
                "https://yorkie-api-qa.navercorp.com",
                .init(apiKey: Constant.apiKey)
            )
            // use Local server
            // self.client = .init(Constant.serverAddress)
            self.document = Document(key: Constant.documentKey)

            Log.log("Document key: \(Constant.documentKey)", level: .info)
            Log.log("API key: \(Constant.apiKey)", level: .info)

            self.monitor.pathUpdateHandler = { [weak self] path in
                if path.status == .satisfied {
                    DispatchQueue.main.async {
                        self?.syncAfterReconnect()
                    }
                }
            }
            self.monitor.start(queue: self.queue)
        }
    }
}

extension ContentView.ContentViewModel {
    func initializeClient() async {
        Log.log("initializeClient", level: .debug)
        state = .loading
        do {
            try await client.activate()

            let doc = try await client.attach(self.document)

            try self.document.update { root, _ in
                var text = root.todos as? JSONArray
                if text == nil {
                    root.todos = JSONArray()
                    text = root.todos as? JSONArray
                } else {}
            }
            self.updateDoc(doc)

            state = .success

            await self.watch()
        } catch {
            state = .error(.cannotInitClient("\(error.localizedDescription)"))
            Log.log("initializeClient error :\(error.localizedDescription)", level: .error)
        }
    }

    func watch() async {
        self.document.subscribe { [weak self] event, document in
            Log.log("receive event: \(event.type)", level: .debug)
            if case .syncStatusChanged = event.type {
                self?.updateDoc(document)
            } else if case .localChange = event.type {
                self?.updateDoc(document)
            }
        }
    }

    func updateKeys(_ key: String) {
        // let key = Constant.yesterDaydocumentKey
        guard self.documentKey != key else { return }
        self.documentKey = key
        Task {
            try await self.client.detach(self.document)
            self.document = Document(key: key)
            await self.initializeClient()
        }
    }

    func syncAfterReconnect() {
        Task {
            try await self.client.sync()

            try? self.document.update { root, _ in
                guard let lists = root.todos as? JSONArray else {
                    Log.log("Can not cast todos to JSONArray", level: .error)
                    return
                }
                var _models = [TodoModel]()
                for i in lists {
                    guard let i = i as? JSONObject else { continue }
                    let completed = i.get(key: "completed") as? Bool
                    let id = i.get(key: "id") as? String
                    let text = i.get(key: "text") as? String

                    guard let completed, let id, let text else { return }
                    let model = TodoModel(completed: completed, id: id, text: text)
                    _models.append(model)
                }
                self.models = _models
            }
        }
    }

    func refreshDocument() {
        self.updateDoc(self.document)
    }

    func updateDoc(_ document: Document) {
        Log.log("update document", level: .debug)
        if let root = document.getRoot().todos as? JSONArray {
            var _models = [TodoModel]()
            let iterator = root.makeIterator()
            while let i = iterator.next() as? JSONObject {
                let completed = i.get(key: "completed") as? Bool
                let id = i.get(key: "id") as? String
                let text = i.get(key: "text") as? String

                guard let completed, let id, let text else { return }
                let model = TodoModel(completed: completed, id: id, text: text)
                _models.append(model)
            }
            self.models = _models
            Log.log("All models: \(_models)", level: .debug)
        } else {
            Log.log("No todos key found!", level: .warning)
        }
    }

    func markAllAsComplete(_ value: Bool) {
        Log.log("markAllAsComplete: \(value)", level: .debug)
        try? self.document.update { root, _ in
            guard let lists = root.todos as? JSONArray else { return }
            let iterator = lists.makeIterator()
            while let next = iterator.next() as? JSONObject {
                next.set(key: "completed", value: value)
            }
        }
    }

    func deleteItem(_ id: String) {
        Log.log("deleteItem: \(id)", level: .debug)
        try? self.document.update { root, _ in
            guard let lists = root.todos as? JSONArray else {
                Log.log("can not convert todos to JSONArray: \(String(describing: root.todos))", level: .error)
                return
            }
            let iterator = lists.makeIterator()
            while let next = iterator.next() as? JSONObject {
                guard let data = String(reflecting: next).data(using: .utf8) else { return }
                if let model = try? self.jsonDecoder.decode(TodoModel.self, from: data), model.id == id {
                    lists.remove(byID: next.getID())
                    Log.log("can not decode TodoModel to from data: \(String(data: data, encoding: .utf8) ?? "NIL")", level: .error)
                } else {
                    Log.log("can not decode TodoModel to from data: \(String(data: data, encoding: .utf8) ?? "NIL")", level: .error)
                }
            }
        }
    }

    func addNewTask(_ name: String) {
        Log.log("addNewTask: \(name)", level: .debug)
        try? self.document.update { root, _ in
            let lists = root.todos as? JSONArray
            if lists == nil {
                Log.log("Init new task when this is the initial", level: .debug)
                root.todos = JSONArray()
            }
            guard let lists = root.todos as? JSONArray else {
                Log.log("Can not cast todos to JSONArray", level: .error)
                return
            }
            let model = TodoModel.makeTodo(with: name)

            lists.append(model)
        }
    }

    func updateTask(_ task: String, _ withNewName: String) {
        Log.log("updateTask: \(task) -> \(withNewName)", level: .debug)
        try? self.document.update { root, _ in
            guard let lists = root.todos as? JSONArray else {
                Log.log("Can not cast todos to JSONArray", level: .error)
                return
            }
            let iterator = lists.makeIterator()
            while let next = iterator.next() as? JSONObject {
                if (next.get(key: "id") as? String) == task {
                    next.set(key: "text", value: withNewName)

                    Log.log("Found task id: \(task) -> \(withNewName)", level: .debug)
                    break
                }
            }
        }
    }

    func updateTask(_ task: String, complete: Bool) {
        Log.log("updateTask: \(task) -> complete: \(complete)", level: .debug)
        try? self.document.update { root, _ in
            guard let lists = root.todos as? JSONArray else {
                Log.log("Can not cast todos to JSONArray", level: .error)
                return
            }
            for i in lists {
                if let object = i as? JSONObject, object.get(key: "id") as! String == task {
                    object.set(key: "completed", value: complete)
                    break
                }
            }
        }
    }

    func removeAllCompleted() {
        Log.log("removeAllCompleted", level: .debug)
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
