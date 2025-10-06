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

struct ContentView: View {
    let name: String
    @State var viewModel = ContentViewModel()
    @State private var dragOffset: CGSize = .zero
    @State var currentPosition = CGPoint(x: 0, y: 0)
    
    init(name: String) {
        self.name = name
    }
    var body: some View {
        ZStack {
            Color.white.opacity(0.1)
                .onTapGesture { location in
                    changePosition(location)
                    currentPosition = location
                }
                .gesture(dragGesture)
            
            canvasView
            menuView
            
            VStack {
                Text(name)
                    .foregroundStyle(Color.white)
                    .padding(3)
                    .background(Color.red)
                    .cornerRadius(2)
                Image(systemName: viewModel.currentCursor.systemImageName)
            }
            .position(currentPosition)
        }
        .ignoresSafeArea()
        .task {
            await viewModel.initializeClient(with: name)
        }
        .onDisappear {
            Task {
                await viewModel.deactivate()
            }
        }
    }
    
    private var loadingView: some View {
        ProgressView()
    }
    
    private func errorView(_ error: TDError) -> some View {
        Text("Error occur: \(error.localizedDescription)")
    }
    
    var canvasView: some View {
        VStack {
            ForEach(viewModel.uiPresenecs) { peer in
                VStack {
                    Text(peer.presence.name)
                        .foregroundStyle(Color.white)
                        .padding(3)
                        .background(Color.red)
                        .cornerRadius(2)
                    Image(systemName: peer.presence.cursorShape.systemImageName)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.red)
                        .frame(width: 20, height: 20)
                }
                .position(
                    x: peer.presence.cursor.xPos,
                    y: peer.presence.cursor.yPos
                )
            }
        }
    }
    
    var dragGesture: some Gesture {
           DragGesture()
               .onChanged { value in
                   dragOffset = value.translation
                   currentPosition = value.location
                   changePosition(currentPosition)
               }
               .onEnded { value in
                   withAnimation(.bouncy) {
                       dragOffset = .zero
                   }
               }
       }
    
    var menuView: some View {
        VStack {
            Spacer()
            
            HStack {
                Group {
                    Button {
                        viewModel.currentCursor = .heart
                    } label: {
                        Image(systemName: CursorShape.heart.systemImageName)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.red)
                            .background(Color.white)
                    }
                    Button {
                        viewModel.currentCursor = .thumbs
                    } label: {
                        Image(systemName: CursorShape.thumbs.systemImageName)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.yellow)
                            .background(Color.white)
                    }

                    Button {
                        viewModel.currentCursor = .pen
                    } label: {
                        Image(systemName: CursorShape.pen.systemImageName)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.black)
                            .background(Color.white)
                    }
                    
                    Button {
                        viewModel.currentCursor = .cursor
                    } label: {
                        Image(systemName: CursorShape.cursor.systemImageName)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.black)
                            .background(Color.white)
                    }
                }
                .frame(width: 28, height: 28)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.red, lineWidth: 2)
                )
            }
            
            Text("\(viewModel.uiPresenecs.count + 1) users here!")
        }
    }
    
    func changePosition(_ position: CGPoint) {
        viewModel.updatePosition(position)
    }
}

#Preview {
    ContentView(name: "iOS")
}
