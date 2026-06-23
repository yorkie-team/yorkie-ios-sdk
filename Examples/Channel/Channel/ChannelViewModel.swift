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
import Yorkie

struct ChannelCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let categoryDescription: String
}

struct ChannelModel: Identifiable, Hashable {
    let id: String
    let name: String
    let roomDescription: String
    let categoryId: String
}

@MainActor
final class ChannelViewModel: ObservableObject {
    @Published var categories: [ChannelCategory] = ChannelViewModel.defaultCategories
    @Published var channels: [ChannelModel] = ChannelViewModel.generateRooms()
    /// Live member count per room id, populated via `peekChannel` without joining.
    @Published var memberCounts: [String: Int] = [:]

    private let client = Client(Constant.serverAddress)
    private var didActivate = false

    /// Returns the rooms that belong to the given category.
    func channels(in category: ChannelCategory) -> [ChannelModel] {
        self.channels.filter { $0.categoryId == category.id }
    }

    /// The channel key for a room — must match the key the room view attaches with.
    func channelKey(for channel: ChannelModel) -> String {
        "room-\(channel.id)"
    }

    /// Refreshes every room's member count using `peekChannel`, which reads a
    /// channel's session count without creating a session, heartbeating, or
    /// subscribing. The caller (this list) polls on its own cadence.
    func refreshMemberCounts() async {
        do {
            if !self.didActivate {
                try await self.client.activate()
                self.didActivate = true
            }
        } catch {
            return
        }

        for channel in self.channels {
            // `peekChannel` requires a yorkie >= 0.7.9 server; older servers return
            // `unimplemented`. Ignore failures and leave the count unset.
            if let count = try? await self.client.peekChannel(self.channelKey(for: channel)) {
                self.memberCounts[channel.id] = count
            }
        }
    }

    /// Deactivates the peek client when the list goes away.
    func stop() async {
        guard self.didActivate else { return }
        try? await self.client.deactivate()
        self.didActivate = false
    }

    private static let defaultCategories: [ChannelCategory] = [
        ChannelCategory(id: "general", name: "General", emoji: "💬", categoryDescription: "General discussion"),
        ChannelCategory(id: "development", name: "Development", emoji: "💻", categoryDescription: "Tech talk and coding"),
        ChannelCategory(id: "random", name: "Random", emoji: "🎲", categoryDescription: "Off-topic chat"),
        ChannelCategory(id: "music", name: "Music", emoji: "🎵", categoryDescription: "Share your favorite tunes")
    ]

    /// Generates rooms with a hierarchical structure: each category yields a fixed number of rooms.
    private static func generateRooms() -> [ChannelModel] {
        let roomsPerCategory = 4
        return self.defaultCategories.flatMap { category in
            (1 ... roomsPerCategory).map { index in
                ChannelModel(
                    id: "\(category.id).\(index)",
                    name: "\(category.emoji) \(category.name) #\(index)",
                    roomDescription: category.categoryDescription,
                    categoryId: category.id
                )
            }
        }
    }
}
