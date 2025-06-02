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

class TextEditorViewController: UIViewController {
    private let defaultFont = UIFont.preferredFont(forTextStyle: .body)
    private let textView: UITextView = {
        let textStorage = NSTextStorage()
        let textContainer = NSTextContainer(size: .zero)
        textContainer.widthTracksTextView = true
        let layoutManager = PeerSelectionDisplayLayoutManager()
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let view = UITextView(frame: .zero, textContainer: textContainer)

        view.contentInsetAdjustmentBehavior = .automatic
        view.textAlignment = .justified
        view.backgroundColor = UIColor(red: 244 / 256, green: 240 / 256, blue: 232 / 256, alpha: 1)
        view.textColor = .black

        return view
    }()

    private var cancellables = Set<AnyCancellable>()
    private var model: TextViewModel?

    private var isTyping = false
    private var isHangulJamoTyping = false
    private var isCompositioning = false {
        didSet {
            if oldValue != self.isCompositioning {
                Task {
                    do {
                        if self.isCompositioning {
                            try await self.model?.pause()
                        } else {
                            try await self.model?.resume()
                        }
                    } catch {
                        assertionFailure()
                    }
                }
            }
        }
    }

    private var editOperations: [TextOperation] = []
    private var peerSelection: [String: (NSRange, UIColor)] = [:]

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
        self.textView.inputDelegate = self

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
        let subject = PassthroughSubject<[TextOperation], Never>()

        subject.sink { [weak self] elements in
            Task {
                self?.updateTextStorage(elements)
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

    func updateTextStorage(_ elements: [TextOperation]) {
        print("#### updateTextStorage \(elements)")

        guard elements.isEmpty == false else {
            return
        }

        let storage = self.textView.textStorage
        var selection = self.textView.isFirstResponder ? self.textView.selectedTextRange : nil

        storage.beginEditing()

        for element in elements {
            switch element {
            case .edit(range: let range, content: let content):
                let range = range ?? NSRange(location: 0, length: storage.length)

                storage.replaceCharacters(in: range, with: content)

                if content.isEmpty == false {
                    let attrRange = NSRange(location: range.location, length: content.count)

                    storage.addAttributes([.font: self.defaultFont], range: attrRange)
                    storage.fixAttributes(in: attrRange)
                }

                let delta = content.isEmpty ? -range.length : content.count - range.length

                // Correct cursor positon.
                if let prev = selection {
                    let prevStartIndex = self.textView.offset(from: self.textView.beginningOfDocument, to: prev.start)

                    if prevStartIndex >= range.location,
                       let newPosStart = self.textView.position(from: prev.start, offset: delta),
                       let newPosEnd = self.textView.position(from: prev.end, offset: delta)
                    {
                        selection = self.textView.textRange(from: newPosStart, to: newPosEnd)
                    } else {
                        selection = nil
                    }
                }

                // Correct peer selection position.
                for selection in self.peerSelection {
                    var prevSelectRange = selection.value.0
                    let newDocEnd = storage.length

                    if newDocEnd < prevSelectRange.location {
                        prevSelectRange = NSRange(location: 0, length: 0)
                    } else {
                        if prevSelectRange.location > range.location {
                            prevSelectRange = NSRange(location: prevSelectRange.location + delta, length: prevSelectRange.length)
                        }

                        if prevSelectRange.location + prevSelectRange.length > range.location {
                            prevSelectRange = NSRange(location: prevSelectRange.location, length: prevSelectRange.length + delta)
                        }
                    }

                    self.peerSelection[selection.key] = (prevSelectRange, selection.value.1)
                }

                self.peerSelection = self.peerSelection.filter { $0.value.0.length > 0 }

            case .select(let range, let actorID):

                print("#### select \(range) \(self.textView.textStorage.length)")

                let newColor = UIColor(red: CGFloat.random(in: 0 ... 1), green: CGFloat.random(in: 0 ... 1), blue: CGFloat.random(in: 0 ... 1), alpha: 0.2)

                if let color = peerSelection[actorID]?.1 {
                    self.peerSelection[actorID] = (range, color)
                } else {
                    self.peerSelection[actorID] = (range, newColor)
                }
            }
        }

        self.redrawPeerSelections()

        storage.endEditing()

        // Must change selectedTextRange after endEditing()
        if let selection {
            self.textView.selectedTextRange = selection
        }
    }

    func redrawPeerSelections() {
        let storage = self.textView.textStorage

        for (key, value) in self.peerSelection {
            let key = PeerSelectionDisplayLayoutManager.createKey(key)
            let allRange = NSRange(location: 0, length: storage.length)

            // The local value may be different from the value of the peer.
            let newRange = NSIntersectionRange(allRange, value.0)

            print("#### newRange \(newRange), \(value.0), \(storage.length)")

            storage.removeAttribute(key, range: allRange)
            storage.addAttribute(key, value: value.1, range: newRange)
        }
    }
}

extension TextEditorViewController: UITextViewDelegate {
    func textViewDidBeginEditing(_: UITextView) {
        self.doneEditButton?.isEnabled = true
        self.isCompositioning = false
    }

    func textViewDidEndEditing(_: UITextView) {
        self.doneEditButton?.isEnabled = false
        self.isCompositioning = false
    }

    func textViewDidChange(_: UITextView) {
        let isMultiStageInput = self.textView.markedTextRange != nil

        self.isCompositioning = (self.isHangulJamoTyping || isMultiStageInput)

        self.isTyping = false

        let operations = self.editOperations
        self.editOperations = []

        Task { [weak self] in
            await self?.model?.edit(operations)
        }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let str = text as NSString

        self.isTyping = true
        self.isHangulJamoTyping = false

        if str.length == 1 {
            let firstCharacter = str.character(at: 0)

            // Hangul Compatibility Jamo
            if firstCharacter > 0x3130 && firstCharacter < 0x318F {
                self.isHangulJamoTyping = true
            }
        }

        return true
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        if let selectedTextRange = textView.selectedTextRange {
            let fromIndex = self.textView.offset(from: self.textView.beginningOfDocument, to: selectedTextRange.start)
            let toIndex = self.textView.offset(from: self.textView.beginningOfDocument, to: selectedTextRange.end)

            print("#### \(fromIndex), \(toIndex)")

            Task { [weak self] in
                await self?.model?.edit([.select(range: NSRange(location: fromIndex, length: toIndex - fromIndex), actorID: "")])
            }
        }
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

                self.editOperations.append(.edit(range: rangeParameter, content: changedString))

                if changedString.isEmpty == false {
                    let firstCharacter = (changedString as NSString).character(at: 0)
                    // Hangul Compatibility vowels.
                    if firstCharacter >= 0x314F && firstCharacter <= 0x3163 ||
                        firstCharacter >= 0x3187 && firstCharacter <= 0x318E
                    {
                        self.isHangulJamoTyping = false
                    }
                }
            }
        }

        if editedMask.contains(.editedAttributes) {
            // TODO(humdrum): Implement attributes editing
        }
    }
}

extension TextEditorViewController: UITextInputDelegate {
    func selectionWillChange(_: UITextInput?) {}

    func selectionDidChange(_: UITextInput?) {
        self.isCompositioning = false
    }

    func textWillChange(_: UITextInput?) {}

    func textDidChange(_: UITextInput?) {}

    @available(iOS 18.4, *)
    func conversationContext(_ context: UIConversationContext?, didChange textInput: (any UITextInput)?) {}
}
