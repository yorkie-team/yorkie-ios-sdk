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

struct CalendarViewWrapper: UIViewRepresentable {
    @Binding var selectedDate: Date?
    @Binding var eventDates: [Date]
    var calendarView = UICalendarView()
    
    func makeUIView(context: Context) -> UICalendarView {
        calendarView.calendar = Calendar(identifier: .gregorian)
        calendarView.tintColor = .systemBlue
        calendarView.delegate = context.coordinator
        calendarView.selectionBehavior = UICalendarSelectionSingleDate(delegate: context.coordinator)

        return calendarView
    }

    func updateUIView(_ uiView: UICalendarView, context: Context) {
        var dateComponents = [DateComponents]()
        for date in (context.coordinator.eventDates + eventDates) {
            let dateComponent = Calendar(identifier: .gregorian)
                .dateComponents(in: .current, from: date)
            dateComponents.append(dateComponent)
        }
        
        context.coordinator.eventDates = self.eventDates
        uiView.reloadDecorations(forDateComponents: dateComponents, animated: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UICalendarSelectionSingleDateDelegate, UICalendarViewDelegate {
        var parent: CalendarViewWrapper
        var eventDates = [Date]()

        init(_ parent: CalendarViewWrapper) {
            self.parent = parent
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            if let date = dateComponents?.date {
                parent.selectedDate = date
            }
        }
        
        func calendarView(
            _ calendarView: UICalendarView,
            decorationFor dateComponents: DateComponents
        ) -> UICalendarView.Decoration? {
            let day = DateComponents(
                calendar: dateComponents.calendar,
                year: dateComponents.year,
                month: dateComponents.month,
                day: dateComponents.day
            )
            
            if eventDates.contains(where: { $0 == day.date }) {
                let circle = UICalendarView.Decoration.image(
                    UIImage(systemName: "circle.fill"),
                    color: UIColor.red,
                    size: .large
                )
                
                return circle
            }
            return nil
        }
    }
}
