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

struct ChannelJoinedStatus: Hashable {
    var joined: Bool
    var count: Int
    var message: String
}

class ChannelRoomViewModel: ObservableObject {
    @Published var room: ChannelModel
    @Published var isLoading: Bool = false
    @Published var errorMsg: String?
    @Published var numberOfMembers: Int = 0
    @Published var joinedStatus: ChannelJoinedStatus = .init(joined: false, count: 0, message: "")
    @Published var isAnimating: Bool = false

    private let client: Client = .init(Constant.serverAddress)
    private var channel: Channel?

    init(channel: ChannelModel) {
        self.room = channel
    }

    func joinChannel() async {
        guard self.channel == nil else { return }
        self.isLoading = true
        defer {
            isLoading = false
        }

        do {
            let roomKey = "room-\(room.id)"
            let channel = try Channel(key: roomKey, isRealtime: true)
            channel.subscribePresenceChange { [weak self] event in
                guard let self else { return }

                if event.count < self.numberOfMembers {
                    self.joinedStatus = ChannelJoinedStatus(joined: false, count: event.count, message: "👋 Someone Left!")
                    self.isAnimating = true
                    self.revertAnimating()
                } else if event.count > self.numberOfMembers {
                    self.joinedStatus = ChannelJoinedStatus(joined: true, count: event.count, message: "👋 Someone Joined!")
                    self.isAnimating = true
                    self.revertAnimating()
                }

                self.numberOfMembers = event.count
            }

            try await self.client.activate()
            try await self.client.attachChannel(channel)

            self.channel = channel
        } catch (let err) {
            errorMsg = err.localizedDescription
        }
    }

    func leaveChannel() async {
        guard let channel = channel else { return }
        self.isLoading = true
        defer {
            isLoading = false
        }
        do {
            channel.unsubscribePresenceChange()
            try await self.client.detachChannel(channel)
            try await self.client.deactivate()
            self.channel = nil
            self.numberOfMembers = 0
            self.joinedStatus = ChannelJoinedStatus(joined: false, count: 0, message: "")
        } catch (let err) {
            errorMsg = err.localizedDescription
        }
    }

    private func revertAnimating() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.isAnimating = false
        }
    }
}
