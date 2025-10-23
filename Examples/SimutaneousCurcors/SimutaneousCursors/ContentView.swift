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

struct LineShape: Shape {
    var points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard self.points.count > 1 else { return path }

        path.move(to: self.points[0])
        for point in self.points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }
}

struct LineDrawingView: View {
    let positions: [CGPoint]
    var body: some View {
        LineShape(points: self.positions)
            .stroke(Color.black, lineWidth: 3)
    }
}

struct ContentView: View {
    let name: String
    @State var viewModel = ContentViewModel()
    @State private var dragOffset: CGSize = .zero
    @State var currentPosition = CGPoint(x: 0, y: 0)
    @State var isTouchDown = false

    init(name: String) {
        self.name = name
    }

    var body: some View {
        ZStack {
            Color.white.opacity(0.1)
                .onTapGesture { location in
                    self.viewModel.currentTimer?.invalidate()
                    self.viewModel.currentTimer = nil

                    let isTouchDownInsideX = location.x > self.currentPosition.x - 40 && location.x < self.currentPosition.x + 40
                    let isTouchDownInsideY = location.y > self.currentPosition.y - 40 && location.y < self.currentPosition.y + 40
                    self.isTouchDown = true
                    self.changePosition(location, isTouchDown: isTouchDownInsideX && isTouchDownInsideY)
                    if isTouchDownInsideX && isTouchDownInsideY {
                        self.viewModel.currentTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                            self.changePosition(location, isTouchDown: false)
                        }
                    }
                    self.currentPosition = location
                }
                .gesture(self.dragGesture)
            self.canvasView
            self.menuView

            VStack {
                Text(self.name)
                    .foregroundStyle(Color.white)
                    .padding(3)
                    .background(Color.red)
                    .cornerRadius(2)
                Image(systemName: self.viewModel.currentCursor.systemImageName)
                    .foregroundStyle(
                        Color(
                            uiColor: .init(
                                red: self.viewModel.currentCursor.color.r,
                                green: self.viewModel.currentCursor.color.g,
                                blue: self.viewModel.currentCursor.color.b,
                                alpha: 1
                            )
                        )
                    )
            }
            .position(self.viewModel.currentCursor == .pen ? .init(x: self.currentPosition.x + 20, y: self.currentPosition.y - 20) : self.currentPosition)
            .overlay {
                if self.isTouchDown, self.viewModel.currentCursor != .cursor, self.viewModel.currentCursor != .pen {
                    AnimationView(
                        shape: self.viewModel.currentCursor,
                        position: .init(
                            x: self.currentPosition.x,
                            y: self.currentPosition.y
                        )
                    )
                }
            }

            ForEach(self.viewModel.drawingNames, id: \.self) { name in
                let drawingPath = self.viewModel.paths[name] ?? []
                LineDrawingView(positions: drawingPath)
            }
        }
        .ignoresSafeArea()
        .task {
            await self.viewModel.initializeClient(with: self.name)
        }
        .onDisappear {
            Task {
                await self.viewModel.deactivate()
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
        Group {
            ForEach(self.viewModel.uiPresenecs) { peer in
                VStack {
                    Text(peer.presence.name)
                        .foregroundStyle(Color.white)
                        .padding(3)
                        .background(Color.red)
                        .cornerRadius(2)
                    Image(systemName: peer.presence.cursorShape.systemImageName)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(
                            Color(
                                uiColor: .init(
                                    red: peer.presence.cursorShape.color.r,
                                    green: peer.presence.cursorShape.color.g,
                                    blue: peer.presence.cursorShape.color.b,
                                    alpha: 1
                                )
                            )
                        )
                        .frame(width: 20, height: 20)
                }
                .position(
                    x: peer.presence.cursor.xPos + (peer.presence.cursorShape == .pen ? 20 : 0),
                    y: peer.presence.cursor.yPos + (peer.presence.cursorShape == .pen ? -20 : 0)
                )
                .overlay {
                    if peer.presence.pointerDown, peer.presence.cursorShape != .cursor, peer.presence.cursorShape != .pen {
                        AnimationView(
                            shape: peer.presence.cursorShape,
                            position: .init(
                                x: peer.presence.cursor.xPos,
                                y: peer.presence.cursor.yPos
                            )
                        )
                    }
                }
            }
        }
    }

    var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                self.dragOffset = value.translation
                self.currentPosition = value.location
                self.changePosition(self.currentPosition, isTouchDown: self.viewModel.currentCursor == .pen)
            }
            .onEnded { _ in
                withAnimation(.bouncy) {
                    self.dragOffset = .zero
                }
                self.isTouchDown = false
                self.changePosition(self.currentPosition, isTouchDown: false)
            }
    }

    var menuView: some View {
        VStack {
            Spacer()

            HStack {
                Group {
                    Button {
                        self.viewModel.currentCursor = .heart
                    } label: {
                        Image(systemName: CursorShape.heart.systemImageName)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.red)
                            .background(Color.white)
                    }
                    Button {
                        self.viewModel.currentCursor = .thumbs
                    } label: {
                        Image(systemName: CursorShape.thumbs.systemImageName)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.yellow)
                            .background(Color.white)
                    }

                    Button {
                        self.viewModel.currentCursor = .pen
                    } label: {
                        Image(systemName: CursorShape.pen.systemImageName)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.black)
                            .background(Color.white)
                    }

                    Button {
                        self.viewModel.currentCursor = .cursor
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

            Text("\(self.viewModel.uiPresenecs.count) users here!")
        }
    }

    func changePosition(_ position: CGPoint, isTouchDown: Bool) {
        self.viewModel.updatePosition(position, isTouchDown: isTouchDown)
    }
}

struct HeartView: View {
    let shape: CursorShape
    let position: CGPoint
    init(shape: CursorShape, position: CGPoint) {
        self.shape = shape
        self.position = position
    }

    @State var offsetY: CGFloat = 0
    @State var opacity: CGFloat = 1
    var body: some View {
        Image(systemName: self.shape.systemImageName)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color(uiColor: .init(red: self.shape.color.r, green: self.shape.color.g, blue: self.shape.color.b, alpha: 1)))
            .frame(width: 20, height: 20)
            .opacity(self.opacity)
            .position(x: self.position.x, y: self.position.y + self.offsetY)
            .onAppear {
                withAnimation(.easeOut(duration: 5)) {
                    self.offsetY = -100
                    self.opacity = 0
                }
            }
    }
}

struct AnimationView: View {
    let shape: CursorShape
    let position: CGPoint
    @State var timer: Timer?

    @State private var hearts: [UUID] = []
    var body: some View {
        VStack {
            ZStack {
                ForEach(self.hearts, id: \.self) { _ in
                    HeartView(shape: self.shape, position: .init(x: self.position.x + .random(in: 0 ... 20), y: self.position.y + .random(in: 0 ... 20)))
                }
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                if self.hearts.count <= 10 {
                    withAnimation {
                        self.hearts.append(.init())
                    }
                }
            }
        }
    }
}
