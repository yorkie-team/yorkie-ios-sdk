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

        // Don't update while composing (Hangul, emoji, etc.)
        if context.coordinator.isComposing {
            return
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

            // Use NSString for proper UTF-16 character counting (handles emoji correctly)
            let oldText = uiView.attributedText.string as NSString
            let newText = self.text.string as NSString
            let difference = abs(newText.length - oldText.length)

            if newText.length < oldText.length {
                // if edit locally, there is no edit style change, then move backward the cursor after deleting text
                if self.lastEditStyle == context.coordinator.lastEditStyle {
                    currentRange.location = max(0, currentRange.location - difference)
                } else {
                    // in case deleting from remote, calculate the cursor of deleting text and
                    // then move backward if the text index is smaller than current cursor
                    if case .remove(let startIndex, _) = self.lastEditStyle, startIndex < currentRange.location {
                        currentRange.location = max(0, currentRange.location - difference)
                    }
                }
            } else if newText.length > oldText.length {
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
            // Ensure cursor position doesn't exceed text bounds
            currentRange.location = min(currentRange.location, newText.length)
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
        var isComposing: Bool = false // Track IME composition state
        var textBeforeComposition: String = "" // Store text before composition started
        var compositionDebounceTimer: Timer?

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

        func textViewDidChange(_ textView: UITextView) {
            let isCurrentlyComposing = textView.markedTextRange != nil

            // Cancel any existing debounce timer
            self.compositionDebounceTimer?.invalidate()

            if isCurrentlyComposing {
                // Composition started or in progress
                if !self.isComposing {
                    // Composition just started
                    self.isComposing = true
                    self.textBeforeComposition = textView.text
                }
                // Don't send updates during composition
                return
            }

            // Composition might have ended, use debounce to ensure we capture final text
            if self.isComposing {
                self.compositionDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.handleCompositionEnd(textView)
                }
                return
            }

            // Normal text change (not during composition) - including emoji input
            // Emoji don't trigger markedTextRange, so they come through here
            self.handleDirectTextChange(textView)
        }

        private func handleCompositionEnd(_ textView: UITextView) {
            self.isComposing = false

            let currentText = textView.text ?? ""
            let previousText = self.textBeforeComposition

            // Find what changed
            let currentNS = currentText as NSString
            let previousNS = previousText as NSString

            // Find the range that changed
            var changeStart = 0
            let minLength = min(currentNS.length, previousNS.length)

            // Find where strings start to differ
            for i in 0 ..< minLength {
                if currentNS.character(at: i) != previousNS.character(at: i) {
                    changeStart = i
                    break
                }
            }

            // If we didn't find a difference in common part, change is at the end
            if changeStart == 0, minLength > 0 {
                changeStart = minLength
            }

            if currentNS.length > previousNS.length {
                // Text was inserted
                let insertedLength = currentNS.length - previousNS.length
                let insertedText = currentNS.substring(with: NSRange(location: changeStart, length: insertedLength))
                let range = NSRange(location: changeStart, length: 0)
                self.parent.didChangeText([range as NSValue], insertedText)
            } else if currentNS.length < previousNS.length {
                // Text was deleted
                let deletedLength = previousNS.length - currentNS.length
                let range = NSRange(location: changeStart, length: deletedLength)
                self.parent.didChangeText([range as NSValue], "")
            }

            self.textBeforeComposition = ""
        }

        private func handleDirectTextChange(_: UITextView) {
            // This handles direct text changes including emoji
            // The shouldChangeTextIn already notified the parent, so we don't need to do anything here
            // This method is kept for future enhancements if needed
        }

        // iOS 18 and earlier
        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            // Allow IME composition (markedText) to proceed
            if textView.markedTextRange != nil || self.isComposing {
                return true
            }

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
            // Allow IME composition (markedText) to proceed
            if textView.markedTextRange != nil || self.isComposing {
                return true
            }

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
