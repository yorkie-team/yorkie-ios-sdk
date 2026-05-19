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

struct ChannelModel: Identifiable, Hashable {
    let id: String
    let name: String
    let roomDescription: String
}

final class ChannelViewModel: ObservableObject {
    @Published var channels: [ChannelModel] = [
        ChannelModel(id: "general", name: "💬 General", roomDescription: "General Discussion"),
        ChannelModel(id: "dev", name: "💻 Development", roomDescription: "Tech talk and coding"),
        ChannelModel(id: "random", name: "🎲 Random", roomDescription: "Off-topic chat"),
        ChannelModel(id: "music", name: "🎵 Music", roomDescription: "Share your favorite tunes")
    ]
}
