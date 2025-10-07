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
    @State var viewModel = ViewModel()
    @State private var selectedDate: Date?
    @State private var newEvent = ""
    
    var body: some View {
        VStack {
            CalendarViewWrapper(
                selectedDate: $selectedDate,
                eventDates: $viewModel.scheduledDates
            )
            .frame(height: 450)
            
            Spacer()
            
            if let selectedDate {
                VStack {
                    ScrollView {
                        makeDateDetail(selectedDate)
                            .padding()
                    }
                    .scrollIndicators(.hidden, axes: .vertical)
                    
                    Spacer()
                    eventEditing
                }
            }
        }
        .padding()
        .task {
            await viewModel.initializeClient()
        }
    }
    
    @ViewBuilder
    func makeDateDetail(_ date: Date) -> some View {
        let events = viewModel.schedulers[date] ?? []
        
        VStack {
            ForEach(events, id: \.uuid) { event in
                EventDetailView(event: event.text, updateEvent: { updated in
                    guard let selectedDate else { return }
                    updateEvent(event, at: selectedDate, withNewText: updated)
                }) {
                    guard let selectedDate else { return }
                    deleteEvent(event, date: selectedDate)
                }
            }
        }
    }
    
    var eventEditing: some View {
        VStack {
            if let date = selectedDate {
                let stringDate = viewModel.dateFormater.string(from: date)
                Text("Date: \(stringDate)")
            }
            
            TextField("Add Event", text: $newEvent)
            
            Button {
                addEvent(newEvent, to: selectedDate)
            } label: {
                Text("Add Event")
            }
        }
    }
}

extension ContentView {
    func addEvent(_ event: String, to date: Date?) {
        guard let date else { return }
        viewModel.addEvent(event, at: date)
        // clear event name after adding
        newEvent = ""
    }
    
    func deleteEvent(_ event: Event, date: Date) {
        viewModel.deleteEvent(event, date: date)
    }
    
    func updateEvent(
        _ event: Event,
        at date: Date,
        withNewText text: String
    ) {
        viewModel.updateEvent(event, at: date, withNewText: text)
    }
}

#Preview {
    ContentView()
}
