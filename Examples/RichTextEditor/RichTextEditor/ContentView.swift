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
    @Environment(\.dismiss) var dismiss
    @StateObject var viewModel = ContentViewModel()
    @State private var showSettings = false
    @State private var documentKey = ""

    var appVersion: String {
        var version = ""
        if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            version.append(appVersion)
        }
        if let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            version.append(" build ")
            version.append(buildNumber)
        }
        return version
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with peers and version
            HStack(alignment: .top) {
                Text("Participants: [\(self.viewModel.localUsername), \(self.viewModel.peers.filter { $0.name != self.viewModel.localUsername }.map { $0.name }.joined(separator: ", "))]")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("v\(self.appVersion)")
                    .font(.system(size: 11))
                // .foregroundColor(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // Toolbar
            HStack(spacing: 12) {
                // Bold button
                Button(action: {
                    if let selection = self.viewModel.selection, selection.length > 0 {
                        self.viewModel.custom(range: selection, font: .bold, value: !self.viewModel.isBold)
                    } else {
                        self.viewModel.toggleFormat(.bold)
                    }
                }) {
                    Text("B")
                        .font(.system(size: 18, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(self.viewModel.isBold ? Color.blue.opacity(0.2) : Color(UIColor.systemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(UIColor.systemGray4), lineWidth: 1)
                        )
                }

                // Italic button
                Button(action: {
                    if let selection = self.viewModel.selection, selection.length > 0 {
                        self.viewModel.custom(range: selection, font: .italic, value: !self.viewModel.isItalic)
                    } else {
                        self.viewModel.toggleFormat(.italic)
                    }
                }) {
                    Text("I")
                        .font(.system(size: 18).italic())
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(self.viewModel.isItalic ? Color.blue.opacity(0.2) : Color(UIColor.systemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(UIColor.systemGray4), lineWidth: 1)
                        )
                }

                // Underline button
                Button(action: {
                    if let selection = self.viewModel.selection, selection.length > 0 {
                        self.viewModel.custom(range: selection, font: .underline, value: !self.viewModel.isUnderline)
                    } else {
                        self.viewModel.toggleFormat(.underline)
                    }
                }) {
                    Text("U")
                        .font(.system(size: 18))
                        .underline()
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(self.viewModel.isUnderline ? Color.blue.opacity(0.2) : Color(UIColor.systemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(UIColor.systemGray4), lineWidth: 1)
                        )
                }

                // Strikethrough button
                Button(action: {
                    if let selection = self.viewModel.selection, selection.length > 0 {
                        self.viewModel.custom(range: selection, font: .strike, value: !self.viewModel.isStrikethrough)
                    } else {
                        self.viewModel.toggleFormat(.strike)
                    }
                }) {
                    Text("S")
                        .font(.system(size: 18))
                        .strikethrough()
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(self.viewModel.isStrikethrough ? Color.blue.opacity(0.2) : Color(UIColor.systemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(UIColor.systemGray4), lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(height: 60)
            .background(Color(UIColor.systemGray6))

            RTUITextField(text: self.viewModel.attributeString, textField: self.viewModel.uitextView, lastEditStyle: self.viewModel.lastEditStyle, didChangeSelection: { fromIndex, toIndex in
                self.viewModel.selection = NSRange(location: fromIndex, length: toIndex - fromIndex)
            }, didChangeText: { range, value in
                let pendingFormats = self.viewModel.getPendingFormats()
                self.viewModel.updateText(ranges: range, value: value, fonts: pendingFormats)
            })
            .padding(16)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(content: {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Back") {
                    self.viewModel.dismiss()
                    self.dismiss.callAsFunction()
                }
            }
        })
        .navigationTitle("Rich Text Editor")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await self.viewModel.initializeClient()
        }
        .sheet(isPresented: self.$showSettings) {
            NavigationView {
                VStack(spacing: 20) {
                    Text("Document Settings")
                        .font(.headline)
                        .padding(.top)

                    Text("Enter a document key to connect to a different collaborative session")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    TextField("Document Key", text: self.$documentKey)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .padding(.horizontal)

                    Spacer()
                }
                .navigationBarItems(
                    leading: Button("Cancel") {
                        self.showSettings = false
                    },
                    trailing: Button("Done") {
                        self.showSettings = false
                        self.viewModel.updateKeys(self.documentKey)
                    }
                )
            }
        }
    }
}

// Wrapper for UITextView to use in SwiftUI
struct RichTextEditorView: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = UIFont.systemFont(ofSize: 18)
        textView.backgroundColor = .systemBackground
        textView.layer.borderColor = UIColor.systemGray4.cgColor
        textView.layer.borderWidth = 1
        textView.layer.cornerRadius = 8
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        return textView
    }

    func updateUIView(_: UITextView, context: Context) {
        // Update logic here
    }
}

#Preview {
    NavigationView {
        ContentView()
    }
}
