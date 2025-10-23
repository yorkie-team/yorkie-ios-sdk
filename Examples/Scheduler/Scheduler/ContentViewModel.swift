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

@Observable
class ViewModel {
    @ObservationIgnored private var client: Client
    @ObservationIgnored private let document: Document
    private(set) var state = ContentState.loading
    var schedulers = [Date: [Event]]()
    var dateFormater: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = Constant.Format.dateFormat
        dateFormatter.locale = Constant.Format.local
        return dateFormatter
    }()

    var scheduledDates = [Date]()

    init() {
        self.client = Client(Constant.serverAddress)
        self.document = Document(key: Constant.documentKey)
    }

    func initializeClient() async {
        self.state = .loading
        do {
            try await self.client.activate()

            let doc = try await client.attach(self.document)
            self.updateScheduler(from: doc)
            self.state = .success

            await self.watch()
        } catch {
            self.state = .error(.cannotInitClient("\(error.localizedDescription)"))
        }
    }

    func watch() async {
        self.document.subscribe { [weak self] event, document in
            guard let self else { return }
            if case .syncStatusChanged = event.type {
                self.updateScheduler(from: document)
            }
        }
    }

    func updateScheduler(from document: Document) {
        guard let array = document.getRoot().content as? JSONArray else { return }
        let iterator = array.makeIterator()
        var dates = [Date: [Event]]()
        while let object = iterator.next() as? JSONObject {
            let date = object.get(key: "date") as? String
            let text = object.get(key: "text") as? String
            guard let date, let text else { fatalError() }
            guard let d = dateFormater.date(from: date) else { return }

            if dates[d] == nil {
                dates[d] = [.init(id: object.getID(), text: text)]
            } else {
                dates[d]?.append(.init(id: object.getID(), text: text))
            }
        }

        self.schedulers = dates
        self.updateScheduledDates()
    }

    func deleteEvent(_ event: Event, date: Date) {
        try? self.document.update { root, _ in
            guard let lists = root.content as? JSONArray else { return }
            lists.remove(byID: event.id)
        }
    }

    func addEvent(
        _ name: String,
        at date: Date
    ) {
        try? self.document.update { root, _ in
            guard let lists = root.content as? JSONArray else { return }
            let formattedDate = self.dateFormater.string(from: date)
            let model = ScheduleModel(date: formattedDate, text: name)

            lists.append(model)
        }
    }

    func updateScheduledDates() {
        self.scheduledDates = [Date](self.schedulers.keys)
    }

    func updateEvent(
        _ event: Event,
        at date: Date,
        withNewText text: String
    ) {
        try? self.document.update { root, _ in
            guard let lists = root.content as? JSONArray else { return }
            let iterator = lists.makeIterator()
            let formattedDate = self.dateFormater.string(from: date)

            while let next = iterator.next() as? JSONObject {
                if next.getID() == event.id, (next.get(key: "date") as? String ?? "") == formattedDate {
                    next.set(key: "text", value: text)
                    return
                }
            }
        }
    }
}
