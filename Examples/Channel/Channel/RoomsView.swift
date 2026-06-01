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

import SwiftUI

struct RoomsView: View {
    @ObservedObject var viewModel: ChannelViewModel

    var body: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .center) {
                Text("Yorkie Channel Rooms")
                    .font(.title)
                    .foregroundStyle(.white)

                Text("Real-time user channel tracking across multiple rooms")
                    .font(.title3)
                    .foregroundStyle(Color.white)
            }
            .padding()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(self.viewModel.channels, id: \.id) { channel in
                        RoomView(channel: channel)
                    }
                }
                .padding()
            }
        }
        .background {
            LinearGradient(gradient: Gradient(colors: [.blue, .purple]), startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .navigationDestination(for: ChannelModel.self) { channel in
            ChannelRoomView(channel: channel)
        }
    }
}

struct RoomView: View {
    let channel: ChannelModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(self.channel.name)
                .font(.title)

            HStack {
                Text(self.channel.roomDescription)
                    .font(.body)

                Spacer()

                NavigationLink("Join Room →", value: self.channel)
            }
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 20, style: .circular)
                .foregroundStyle(Color.white)
        }
    }
}

#Preview {
    RoomsView(viewModel: ChannelViewModel())
}
