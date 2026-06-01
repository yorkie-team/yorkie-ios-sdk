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
import Yorkie

struct ChannelRoomView: View {
    @Environment(\.dismiss) var dismiss

    @StateObject var viewModel: ChannelRoomViewModel

    init(channel: ChannelModel) {
        self._viewModel = StateObject(wrappedValue: ChannelRoomViewModel(channel: channel))
    }

    var body: some View {
        VStack {
            HStack {
                Button {
                    Task {
                        await self.viewModel.leaveChannel()
                        self.dismiss()
                    }
                } label: {
                    Text("← Back to Rooms")
                }

                Spacer()
            }
            .padding([.horizontal, .bottom])

            Text(self.viewModel.room.name)
                .font(.largeTitle)

            Text(self.viewModel.room.roomDescription)
                .font(.title3)

            Spacer()
            LoadingView(isLoading: self.$viewModel.isLoading)
            UserOnlineView(viewModel: self.viewModel)
            RoomErrorView(msg: self.$viewModel.errorMsg)
            Spacer()
        }
        .task {
            await self.viewModel.joinChannel()
        }
        .navigationBarBackButtonHidden()
    }
}

struct LoadingView: View {
    @Binding var isLoading: Bool
    var body: some View {
        if self.isLoading {
            ProgressView()
        } else {
            EmptyView()
        }
    }
}

struct UserOnlineView: View {
    @ObservedObject var viewModel: ChannelRoomViewModel

    var body: some View {
        if self.viewModel.isLoading || self.viewModel.errorMsg != nil {
            EmptyView()
        } else {
            VStack {
                Text("\(self.viewModel.numberOfMembers)")
                    .font(.title)
                    .scaleEffect(self.viewModel.isAnimating ? 1.5 : 1.0)
                    .animation(.bouncy, value: self.viewModel.isAnimating)

                Text("User\(self.viewModel.numberOfMembers > 1 ? "s" : "") Online")
                    .textCase(.uppercase)
                    .scaleEffect(self.viewModel.isAnimating ? 1.5 : 1.0)
                    .animation(.bouncy, value: self.viewModel.isAnimating)

                Text(self.viewModel.joinedStatus.message)
                    .padding()
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .foregroundStyle(self.viewModel.joinedStatus.joined ? .green : .yellow)
                    }
            }
        }
    }
}

struct RoomErrorView: View {
    @Binding var msg: String?

    var body: some View {
        if let msg {
            Text(msg)
                .font(.caption)
        } else {
            EmptyView()
        }
    }
}

#Preview {
    ChannelRoomView(channel: ChannelModel(id: "dev", name: "💻 Development", roomDescription: "Tech talk and coding"))
}
