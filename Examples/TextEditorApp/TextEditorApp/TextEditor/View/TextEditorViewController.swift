/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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

import UIKit

@MainActor
class TextEditorViewController: UIViewController {
    private let textView: UITextView = {
        let view = UITextView(frame: .zero)

        view.contentInsetAdjustmentBehavior = .automatic
        view.textAlignment = .justified
        view.backgroundColor = UIColor(red: 244 / 256, green: 240 / 256, blue: 232 / 256, alpha: 1)
        view.textColor = .black

        return view
    }()

    var model: TextViewModel?

    var isTyping = false
    var editOperations: [(NSRange, String)] = []

    let defaultFont = UIFont.preferredFont(forTextStyle: .body)

    var doneEditButton: UIBarButtonItem?

    override func viewDidLoad() {
        super.viewDidLoad()

        self.title = "Text Editor"

        view.backgroundColor = .white

        self.textView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(self.textView)

        self.textView.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor).isActive = true
        self.textView.leftAnchor.constraint(equalTo: view.layoutMarginsGuide.leftAnchor).isActive = true
        self.textView.rightAnchor.constraint(equalTo: view.layoutMarginsGuide.rightAnchor).isActive = true
        self.textView.bottomAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor).isActive = true

        self.textView.textStorage.delegate = self
        self.textView.delegate = self

        self.textView.allowsEditingTextAttributes = true
        self.textView.typingAttributes = [.font: self.defaultFont]

        let doneAction = UIAction { [weak self] _ in
            self?.textView.resignFirstResponder()
        }

        let button = UIBarButtonItem(systemItem: .done, primaryAction: doneAction)
        button.isEnabled = false
        self.navigationItem.rightBarButtonItem = button
        self.doneEditButton = button

        self.model = TextViewModel(self.textView.textStorage, self.defaultFont)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        if isBeingDismissed {
            Task {
                await self.model?.cleanup()
            }
        }
    }
}

extension TextEditorViewController: UITextViewDelegate {
    func textViewDidBeginEditing(_: UITextView) {
        self.doneEditButton?.isEnabled = true
    }

    func textViewDidEndEditing(_: UITextView) {
        self.doneEditButton?.isEnabled = false
    }

    func textViewDidChange(_: UITextView) {
        self.isTyping = false

        self.model?.edit(self.editOperations)

        self.editOperations = []
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        print("#### textView shouldChangeTextIn called. \(range), \(text), \((text as NSString).length)")

        self.isTyping = true

        return true
    }
}

extension TextEditorViewController: NSTextStorageDelegate {
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
        print("didProcessEditiong called...\(editedRange), \(delta)")

        guard self.textView.isFirstResponder else {
            return
        }

        let changedString = textStorage.mutableString.substring(with: editedRange)

        if editedMask.contains(.editedCharacters) {
            print("char changed...")

            if self.isTyping {
                let rangeParameter: NSRange

                if delta < 0 {
                    rangeParameter = NSRange(location: editedRange.location, length: -delta)
                } else {
                    rangeParameter = NSRange(location: editedRange.location, length: changedString.count - delta)
                }

                print("Char changed 2... \(rangeParameter) [\(changedString)]")

                self.editOperations.append((rangeParameter, changedString))

            } else {
                // Correct cursor positon.
                if let prev = self.textView.selectedTextRange {
                    let prevIndex = self.textView.offset(from: self.textView.beginningOfDocument, to: prev.start)

                    print("#### cursor \(prev), \(delta) \(prevIndex)")

                    if editedRange.location <= prevIndex,
                       let newPosStart = self.textView.position(from: prev.start, offset: delta),
                       let newPosEnd = self.textView.position(from: prev.end, offset: delta)
                    {
                        self.textView.selectedTextRange = self.textView.textRange(from: newPosStart, to: newPosEnd)
                    }
                }
            }
        }

        if editedMask.contains(.editedAttributes) {
            // TODO:
        }
    }
}
