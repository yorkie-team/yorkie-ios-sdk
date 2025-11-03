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
import UIKit

struct ContentView: View {
    @State var viewModel = ContentViewModel()
    @State var isBold = false
    @State var isItalic = false
    @State var isUnderline = false
    @State var isStrikethrought = false
    var body: some View {
        VStack {
            HStack {
                Text("Participants: [\(self.viewModel.peers.map { $0.name }.joined(separator: ", "))]")
            }
            HStack {
                Group {
                    Button {
                        self.isBold.toggle()
                        guard let selection = viewModel.selection else { return }
                        self.viewModel.custom(range: selection, font: .bold, value: self.isBold)
                    } label: {
                        Text("B")
                            .bold()
                            .font(.largeTitle)
                            .padding(10)
                            .background(self.isBold ? Color.green : Color.white)
                            .cornerRadius(5)
                    }

                    Button {
                        self.isItalic.toggle()
                        guard let selection = viewModel.selection else { return }
                        self.viewModel.custom(range: selection, font: .italic, value: self.isItalic)
                    } label: {
                        Text("I")
                            .italic()
                            .font(.largeTitle)
                            .padding(10)
                            .background(self.isItalic ? Color.green : Color.white)
                            .cornerRadius(5)
                    }

                    Button {
                        self.isUnderline.toggle()
                        guard let selection = viewModel.selection else { return }
                        self.viewModel.custom(range: selection, font: .underline, value: self.isUnderline)
                    } label: {
                        Text("U")
                            .underline()
                            .font(.largeTitle)
                            .padding(10)
                            .background(self.isUnderline ? Color.green : Color.white)
                            .cornerRadius(5)
                    }

                    Button {
                        self.isStrikethrought.toggle()
                        guard let selection = viewModel.selection else { return }
                        self.viewModel.custom(range: selection, font: .strike, value: self.isStrikethrought)
                    } label: {
                        Text("S")
                            .strikethrough()
                            .font(.largeTitle)
                            .padding(10)
                            .background(self.isStrikethrought ? Color.green : Color.white)
                            .cornerRadius(5)
                    }
                }
                .padding(.horizontal, 20)
            }
            RTUITextField(
                text: self.viewModel.attributeString,
                textField: self.viewModel.uitextView,
                lastEditStyle: self.viewModel.lastEditStyle
            ) { @MainActor fromIndex, toIndex in
                self.viewModel.selection = NSRange(location: fromIndex, length: toIndex - fromIndex)
            } didChangeText: { ranges, text in
                var fonts = [CustomFont]()
                if self.isBold { fonts.append(.bold) }
                if self.isItalic { fonts.append(.italic) }
                if self.isUnderline { fonts.append(.underline) }
                if self.isStrikethrought { fonts.append(.strike) }
                self.viewModel.updateText(ranges: ranges, value: text, fonts: fonts)
            }
        }
        .padding()
        .task {
            await self.viewModel.initializeClient()
        }
    }
}

#Preview {
    ContentView()
}
