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
import SwiftUI
import Yorkie

@Observable
class ContentViewModel {
    let width = UIScreen.current!.bounds.size.width
    let height = UIScreen.current!.bounds.size.height

    @ObservationIgnored private var client: Client
    @ObservationIgnored private let document: Document
    @ObservationIgnored var presenecs = [Presence]()

    var uiPresenecs = [Model]()
    var currentCursor: CursorShape = .heart {
        didSet {
            self.updateCursor()
        }
    }

    private(set) var state = ContentState.loading

    init() {
        self.client = Client(Constant.serverAddress)
        self.document = Document(key: Constant.documentKey)
    }

    func initializeClient(with name: String) async {
        self.state = .loading
        do {
            try await self.client.activate()

            let doc = try await client.attach(self.document, [
                "name": name,
                "cursorShape": "heart",
                "cursor": ["xPos": 0.5, "yPos": 0.5],
                "pointerDown": "false"
            ])
            try self.document.update { root, _ in
                var text = root.content as? JSONText
                if text == nil {
                    root.content = JSONText()
                    text = root.content as? JSONText
                }
            }
            let pres = doc.getPresences()
            self.mapFromPrecenscToUI(pres)
            self.state = .success

            await self.watch()
        } catch {
            self.state = .error(.cannotInitClient("\(error.localizedDescription)"))
        }
    }

    func deactivate() async {
        do {
            try await self.client.deactivate()
        } catch {}
    }

    func watch() async {
        self.document.subscribe { [weak self] event, document in
            if case .syncStatusChanged = event.type {
                let presences = document.getPresences()
                self?.mapFromPrecenscToUI(presences)
            } else if case .presenceChanged = event.type {
                let presences = document.getPresences()
                self?.mapFromPrecenscToUI(presences)
            }
        }
    }

    @MainActor
    private func mapFromPrecenscToUI(_ peers: [PeerElement]) {
        var _uiPresenecs = [Model]()

        for peer in peers {
            let id = peer.clientID
            let presentModel = peer.presence
            let name = presentModel["name"] as? String
            let pointerDown = presentModel["pointerDown"] as? Int
            let cursor = presentModel["cursor"] as? [String: Double]
            let cursorShape = presentModel["cursorShape"] as? String

            guard let name, let pointerDown, let cursor, let cursorShape, let cursorShape = CursorShape(rawValue: cursorShape) else {
                continue
            }

            guard let xPos = cursor["xPos"], let yPos = cursor["yPos"] else { fatalError() }
            let realxPos = xPos * self.width
            let realyPos = yPos * self.height

            let model = Model(
                clientID: id,
                presence: .init(
                    name: name,
                    pointerDown: pointerDown,
                    cursorShape: cursorShape,
                    cursor: .init(xPos: realxPos, yPos: realyPos)
                )
            )

            _uiPresenecs.append(model)
        }

        self.uiPresenecs.removeAll()
        self.uiPresenecs = _uiPresenecs

        print(self.uiPresenecs)
    }

    func updatePosition(_ position: CGPoint) {
        do {
            try self.document.update { _, presence in
                presence.set(["cursor": ["xPos": position.x / self.width, "yPos": position.y / self.height]])
            }
        } catch {
            self.state = .error(.cannotInitClient("\(error.localizedDescription)"))
        }
    }

    func updateCursor() {
        do {
            try self.document.update { _, presence in
                presence.set(["cursorShape": self.currentCursor])
            }
        } catch {
            self.state = .error(.cannotInitClient("\(error.localizedDescription)"))
        }
    }
}
