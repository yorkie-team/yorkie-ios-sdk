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

struct EventDetailView: View {
    let event: String
    var updateEvent: (String) -> Void
    var deleteEvent: () -> Void

    @State var isEditing = false
    @State var textEditing = ""
    @FocusState var forcusField: Bool

    var body: some View {
        HStack {
            if self.isEditing {
                TextField("", text: self.$textEditing)
                    .focused(self.$forcusField)
            } else {
                Text(self.event)
            }

            Spacer()
            if self.isEditing {
                HStack {
                    Button {
                        self.updateEvent(self.textEditing)
                        self.toggleEditing(false)
                    } label: {
                        Text("Save")
                    }

                    Button {
                        self.toggleEditing(false)
                    } label: {
                        Text("Cancel")
                    }
                }
            } else {
                HStack {
                    Button {
                        self.toggleEditing(true)
                    } label: {
                        Image(systemName: "highlighter.badge.ellipsis")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20, alignment: .center)
                    }

                    Button {
                        self.deleteEvent()
                    } label: {
                        Image(systemName: "trash")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20, alignment: .center)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray, lineWidth: 2)
        )
    }

    func toggleEditing(_ _isEditing: Bool) {
        withAnimation {
            self.isEditing = _isEditing
            self.forcusField = true
        }

        if self.isEditing {
            self.textEditing = self.event
        } else {
            self.textEditing = ""
        }
    }
}

#Preview {
    EventDetailView(event: "Go to work or Not?") { _ in
    } deleteEvent: {}
}
