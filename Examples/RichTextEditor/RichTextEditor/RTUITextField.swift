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

struct RTUITextField: UIViewRepresentable {
    var lastEditStyle: EditStyle?
    var text: NSMutableAttributedString
    let textField: UITextView
    var didChangeSelection: (Int, Int) -> Void
    var didChangeText: ([NSValue], String) -> Void

    init(
        text: NSMutableAttributedString,
        textField: UITextView,
        lastEditStyle: EditStyle?,
        didChangeSelection: @escaping (Int, Int) -> Void,
        didChangeText: @escaping ([NSValue], String) -> Void
    ) {
        self.text = text
        self.textField = textField
        self.didChangeSelection = didChangeSelection
        self.didChangeText = didChangeText
        self.lastEditStyle = lastEditStyle
    }

    func makeUIView(context: Context) -> UITextView {
        self.textField.textColor = .label
        self.textField.font = UIFont.systemFont(ofSize: Constant.TextInfo.fontSize, weight: .medium)
        self.textField.backgroundColor = UIColor.systemGray6
        self.textField.delegate = context.coordinator
        return self.textField
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        defer {
            // save style for checking latter after change style from local or remote
            // compare this style to make sure that is not local change
            context.coordinator.lastEditStyle = lastEditStyle
        }
        UIView.setAnimationsEnabled(false)
        if let selectedRange = context.coordinator.selectRange, !selectedRange.isEmpty {
            uiView.attributedText = self.text

            let beginning = uiView.beginningOfDocument
            let selectionStart = selectedRange.start
            let selectionEnd = selectedRange.end

            let location = uiView.offset(from: beginning, to: selectionStart)
            let length = uiView.offset(from: selectionStart, to: selectionEnd)

            uiView.selectedRange = NSRange(location: location, length: length)
        } else {
            var currentRange = uiView.selectedRange
            let difference = abs(self.text.string.count - uiView.attributedText.string.count)
            if self.text.string.count < uiView.attributedText.string.count {
                // if edit locally, there is no edit style change, then move backward the cursor after deleting text
                if self.lastEditStyle == context.coordinator.lastEditStyle {
                    currentRange.location -= difference
                } else {
                    // in case deleting from remote, calculate the cursor of deleting text and
                    // then move backward if the text index is smaller than current cursor
                    if case .remove(let startIndex, _) = self.lastEditStyle, startIndex < currentRange.location {
                        currentRange.location -= difference
                    }
                }
            } else if self.text.string.count > uiView.attributedText.string.count {
                // if edit locally, there is no edit style change, then move forward the cursor after adding text
                if self.lastEditStyle == context.coordinator.lastEditStyle {
                    currentRange.location += difference
                } else {
                    // in case adding from remote, calculate the cursor of adding text and
                    // then move forward if the text index is greater than current cursor
                    if case .add(let startIndex, _, _) = self.lastEditStyle, currentRange.location > startIndex {
                        currentRange.location += difference
                    }
                }
                // adding text after the cursor can lead to the cursor is moving forward! += (difference)
            }

            uiView.attributedText = self.text
            uiView.selectedRange = currentRange
        }
        UIView.setAnimationsEnabled(true)
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(self)
        coordinator.lastEditStyle = self.lastEditStyle
        return coordinator
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: RTUITextField
        var selectRange: UITextRange?
        var lastEditStyle: EditStyle?

        init(_ parent: RTUITextField) {
            self.parent = parent
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if let selectedTextRange = textView.selectedTextRange {
                let fromIndex = self.parent.textField.offset(from: textView.beginningOfDocument, to: selectedTextRange.start)
                let toIndex = self.parent.textField.offset(from: textView.beginningOfDocument, to: selectedTextRange.end)
                self.selectRange = selectedTextRange
                self.parent.didChangeSelection(fromIndex, toIndex)
            }
        }

        // iOS 18 and earlier
        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            let ranges = range as NSValue
            self.parent.didChangeText([ranges], text)
            return false
        }

        // iOS 26.0+ and later
        func textView(
            _ textView: UITextView,
            shouldChangeTextInRanges ranges: [NSValue],
            replacementText text: String
        ) -> Bool {
            self.parent.didChangeText(ranges, text)
            return false
        }
    }
}

class CustomCursorView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .red
        self.layer.cornerRadius = 1
    }

    init(frame: CGRect, color: UIColor) {
        super.init(frame: frame)
        self.backgroundColor = color
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
