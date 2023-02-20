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

import Combine
import UIKit

@MainActor
class TextEditorViewController: UIViewController {
    private let defaultFont = UIFont.preferredFont(forTextStyle: .body)
    private let textView: UITextView = {
        let view = UITextView(frame: .zero)

        view.contentInsetAdjustmentBehavior = .automatic
        view.textAlignment = .justified
        view.backgroundColor = UIColor(red: 244 / 256, green: 240 / 256, blue: 232 / 256, alpha: 1)
        view.textColor = .black

        return view
    }()

    private var cancellables = Set<AnyCancellable>()
    private var model: TextViewModel?

    private var isTyping = false
    private var editOperations: [TextEditOperation] = []

    private var doneEditButton: UIBarButtonItem?

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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Receive events from TextView Model.
        let subject = PassthroughSubject<[TextEditOperation], Never>()

        subject.sink { elements in
            Task {
                await MainActor.run { [weak self] in
                    self?.updateText(elements)
                }
            }
        }.store(in: &self.cancellables)

        self.model = TextViewModel(subject)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        Task {
            await self.model?.cleanup()
            self.model = nil
        }
    }

    func updateText(_ elements: [TextEditOperation]) {
        guard elements.isEmpty == false else {
            return
        }

        let storage = self.textView.textStorage

        var selection = self.textView.isFirstResponder ? self.textView.selectedTextRange : nil

        storage.beginEditing()

        elements.forEach { element in
            let range = element.range ?? NSRange(location: 0, length: storage.length)

            storage.replaceCharacters(in: range, with: element.content)

            if element.content.isEmpty == false {
                let attrRange = NSRange(location: range.location, length: element.content.count)

                storage.addAttributes([.font: self.defaultFont], range: attrRange)
                storage.fixAttributes(in: attrRange)
            }

            // Correct cursor positon.
            if let prev = selection {
                let prevStartIndex = self.textView.offset(from: self.textView.beginningOfDocument, to: prev.start)

                let delta = element.content.isEmpty ? -range.length : element.content.count - range.length

                if prevStartIndex >= range.location,
                   let newPosStart = self.textView.position(from: prev.start, offset: delta),
                   let newPosEnd = self.textView.position(from: prev.end, offset: delta)
                {
                    selection = self.textView.textRange(from: newPosStart, to: newPosEnd)
                } else {
                    selection = nil
                }
            }
        }

        storage.endEditing()

        // Must change selectedTextRange after endEditing()
        if let selection {
            self.textView.selectedTextRange = selection
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

        let operations = self.editOperations
        self.editOperations = []

        Task { [weak self] in
            await self?.model?.edit(operations)
        }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
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
            if self.isTyping {
                let rangeParameter = NSRange(location: editedRange.location, length: delta < 0 ? -delta : changedString.count - delta)

                print("Char changed ... \(rangeParameter) [\(changedString)]")

                self.editOperations.append(TextEditOperation(range: rangeParameter, content: changedString))
            }
        }

        if editedMask.contains(.editedAttributes) {
            // TODO:
        }
    }
}
