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

import Combine
import UIKit
import Yorkie

@MainActor
class ContentViewModel: ObservableObject {
    var appVersion: String {
        var version = ""
        if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            version.append(appVersion)
        }

        // Get the build number (CFBundleVersion)
        if let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            version.append(" build ")
            version.append(buildNumber)
        }
        return version
    }

    let uitextView = UITextView()

    private var client: Client
    private var document: Document
    var selection: NSRange? {
        didSet {
            self.updateMySelection()
            Task { @MainActor in
                self.updateFormattingStates()
            }
        }
    }

    private var content: String = ""
    @Published var attributeString = NSMutableAttributedString(string: "")
    @Published var lastEditStyle: EditStyle?
    @Published var isBold: Bool = false
    @Published var isItalic: Bool = false
    @Published var isUnderline: Bool = false
    @Published var isStrikethrough: Bool = false

    var mutableAttributeString: NSMutableAttributedString {
        self.attributeString.mutableCopy() as! NSMutableAttributedString
    }

    @MainActor
    func updateAttribute(_ attribute: NSMutableAttributedString, _ function: String = #function) {
        Log.log("[Attribute change] function: \(function) -> \(attribute)", level: .debug)
        self.attributeString = attribute
    }

    var documentKey = Constant.documentKey
    private let apiKey = Constant.apiKey
    @Published var peers = [Peer]()

    // Generate unique username for this device
    lazy var localUsername: String = {
        let deviceName = UIDevice.current.name
        let identifier = UUID().uuidString.prefix(8)
        return "\(deviceName)-\(identifier)"
    }()

    // Generate a random color for this device
    private lazy var localUserColor: String = {
        let colors: [String] = [
            "#a83267", "#2196F3", "#4CAF50", "#FF9800",
            "#9C27B0", "#00BCD4", "#FFEB3B", "#E91E63"
        ]
        return colors.randomElement() ?? "#a83267"
    }()

    var didFinishSync = false
    init() {
        self.client = Client(
            "https://yorkie-api-qa.navercorp.com",
            .init(apiKey: self.apiKey)
        )
        // use for local server
        // self.client = Client(Constant.serverAddress)

        self.document = Document(key: self.documentKey)
        Log.log("Document key: \(self.documentKey)", level: .info)
        Log.log("API key: \(self.apiKey)", level: .info)
    }
}

// MARK: - Yorkie handler

extension ContentViewModel {
    func updateKeys(_ key: String) {
        // let key = Constant.yesterDaydocumentKey
        guard self.documentKey != key else { return }
        self.documentKey = key

        Task {
            try await self.client.detach(self.document)
            self.document = Document(key: self.documentKey)
            await self.initializeClient()
        }
    }

    func toggleFormat(_ format: CustomFont) {
        switch format {
        case .bold:
            self.isBold.toggle()
        case .italic:
            self.isItalic.toggle()
        case .underline:
            self.isUnderline.toggle()
        case .strike:
            self.isStrikethrough.toggle()
        }
        Log.log("toggleFormat \(format): bold=\(self.isBold), italic=\(self.isItalic), underline=\(self.isUnderline), strike=\(self.isStrikethrough)", level: .debug)
    }

    func dismiss() {
        Task {
            do {
                try await self.client.detach(self.document)
                try await self.client.deactivate()
            } catch {
                fatalError()
            }
        }
    }

    func getPendingFormats() -> [CustomFont] {
        var formats: [CustomFont] = []
        if self.isBold { formats.append(.bold) }
        if self.isItalic { formats.append(.italic) }
        if self.isUnderline { formats.append(.underline) }
        if self.isStrikethrough { formats.append(.strike) }
        return formats
    }

    func initializeClient() async {
        Log.log("initializeClient", level: .debug)
        do {
            try await self.client.activate()

            try await self.client.attach(self.document, [
                "username": self.localUsername,
                "color": self.localUserColor
            ])

            try self.document.update { root, _ in
                var text = root.content as? JSONText
                if text == nil {
                    root.content = JSONText()
                    text = root.content as? JSONText
                }
            }
            self.syncTextSnapShot()

            await self.watch()
        } catch {
            Log.log("initializeClient Error: \(error.localizedDescription)", level: .error)
        }
    }

    func updateText(ranges: [NSValue], value: String, fonts: [CustomFont]) {
        Log.log("updateText: ranges: \(ranges), value: \(value), fonts: \(fonts.sorted(by: { $0.rawValue > $1.rawValue }).map { $0.rawValue }.joined(separator: ", "))", level: .info)
        try? self.document.update { [weak self] root, _ in
            guard let self, let content = root.content as? JSONText else {
                Log.log("content not found: \(String(describing: root.content))", level: .warning)
                return
            }
            guard let ranges = ranges as? [NSRange], let range = ranges.first else {
                Log.log("range not found: \(ranges)", level: .warning)
                return
            }
            let toIdx = range.location + range.length
            Log.log("updateText edit range: \(range.location) -> \(toIdx)", level: .debug)
            content.edit(range.location, toIdx, value, fonts.attributes)
            if value.isEmpty {
                // delete
                let att = self.mutableAttributeString
                guard att.string.count >= range.length + range.location else { return }
                att.deleteCharacters(in: range)
                self.updateAttribute(att)
            } else {
                // insert character
                let att = self.mutableAttributeString

                // Ensure insertion point is within valid bounds
                let safeLocation = min(range.location, att.length)

                let newAttribute = NSMutableAttributedString(string: value)
                let isBold = fonts.contains(.bold)
                let isItalic = fonts.contains(.italic)
                var font = UIFont.defaulf
                if isBold { font = font.boldSelf() }
                if isItalic { font = font.italicSelf() }

                // add font style (bold and italic)
                // Use the actual length of the inserted text (handles emoji correctly)
                let _range = NSRange(location: 0, length: (value as NSString).length)
                newAttribute.addAttribute(.font, value: font, range: _range)

                // add underline if needed
                let isUnderline = fonts.contains(.underline)
                if isUnderline {
                    newAttribute.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue], range: _range)
                }
                // add strike through if needed
                let isStrike = fonts.contains(.strike)
                if isStrike {
                    newAttribute.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue], range: _range)
                }
                att.insert(newAttribute, at: safeLocation)
                self.updateAttribute(att)
            }
        }
    }

    func custom(range: NSRange, font: CustomFont, value: Bool) {
        Log.log("custom range: [\(range.location):\(range.length)] -> \(font), value: \(value)", level: .debug)
        try? self.document.update { root, _ in
            guard let content = root.content as? JSONText else { return }

            let toIdx = range.location + range.length
            Log.log("custom range set style: [\(range.location):\(toIdx)] -> \(font), value: \(value)", level: .debug)
            content.setStyle(range.location, toIdx, [font.rawValue: value])
        }
    }

    func watch() async {
        self.document.subscribe { [weak self] event, _ in
            Log.log("did receive event \(event.type)", level: .debug)
            if let event = event as? RemoteChangeEvent {
                // adding text from FE and sync to iOS
                // receive when peer changes text
                let events = self?.decodeEvent(event)
                self?.applyEvents(events)
            } else if let event = event as? PresenceChangedEvent {
                // receive when peer change cursor
                self?.decodeEvent(event.value)
            } else if let event = event as? LocalChangeEvent {
                // apply local changes for style
                let events = self?.decodeEvent(event)
                self?.applyEvents(events)
            } else if let _ = event as? SyncStatusChangedEvent {
                self?.syncTextSnapShot()
            } else if let event = event as? UnwatchedEvent {
                if let name = event.value.presence["username"] as? String {
                    var peers = self?.peers ?? []
                    let previous = peers.first(where: { $0.name == name })
                    self?.updatePeerSelection(with: previous, peer: nil)

                    if let previous, let uitextView = self?.uitextView {
                        self?.removePeerCursor(previous, in: uitextView)
                    }
                    peers.removeAll(where: { $0.name == name })
                    self?.update(peers: peers)
                } else {
                    Log.log("Can not get this peer name :\(event.value.presence)", level: .error)
                }
            } else if let event = event as? WatchedEvent {
                self?.decodeEvent(event.value)
            }
        }
    }
}

extension ContentViewModel {
    // decode event local change with styles only
    // adding or remove will be handled in local
    func decodeEvent(_ event: LocalChangeEvent) -> [EditStyle] {
        // this is local change and will apply to local only
        // use this function to add attribute to local attribute after publishing to other peers
        var result: [EditStyle] = []
        let changeInfo = event.value
        for operation in changeInfo.operations {
            if let operation = operation as? StyleOpInfo, let attributes = operation.attributes {
                let fromIndex = operation.from // location
                let toIndex = operation.to // location
                let styles = self.decodeStyle(from: attributes)
                result.append(.style(startIndex: fromIndex, toIndex: toIndex, styles: styles))
            }
        }
        Log.log("decode event local change: \(result)", level: .debug)
        return result
    }

    func decodeEvent(_ peer: PeerElement) {
        // change selection
        // change cursors
        let peerUsername = peer.presence["username"] as? String ?? "iOS"
        if peerUsername == self.localUsername {
            Log.log("Local change, no update", level: .debug)
            return
        }
        guard let presencesChanges = peer.presence["selection"] as? [Any] else {
            Log.log("no selection", level: .debug)
            let name = peer.presence["username"] as? String ?? "anonymous"
            let color = peer.presence["color"] as? String ?? "anonymous"
            // cache previous peer selection for reuse
            var peers = self.peers
            let previous = peers.first(where: { $0.name == name })

            peers.removeAll(where: { $0.name == name })
            let nextPeer = Peer(clientID: peer.clientID, name: name, position: .init(), color: color)
            peers.append(
                nextPeer
            )
            self.updatePeerSelection(with: previous, peer: nextPeer)
            self.update(peers: peers)

            return
        }
        guard presencesChanges.count == 2 else { return }
        let name = peer.presence["username"] as? String ?? "anonymous"
        let color = peer.presence["color"] as? String ?? "anonymous"

        let fromIDs: TextPosStruct? = self.decodePresence(presencesChanges.first!)
        let toIDs: TextPosStruct? = self.decodePresence(presencesChanges.last!)

        guard let fromIDs, let toIDs else {
            Log.log("receive no presences changes: \(presencesChanges)", level: .warning)
            return
        }

        let (fromPos, toPos) = (fromIDs, toIDs)

        if let (fromIdx, toIdx) = try? (self.document.getRoot().content as? JSONText)?.posRangeToIndexRange((fromPos, toPos)) {
            Log.log("found range from: [\(fromPos):\(toPos)] -> [\(fromIdx):\(toIdx)]", level: .debug)
            let range: NSRange

            if fromIdx <= toIdx {
                range = NSRange(location: fromIdx, length: toIdx - fromIdx)
            } else {
                range = NSRange(location: toIdx, length: fromIdx - toIdx)
            }

            // cache previous peer selection for reuse
            var peers = self.peers
            let previous = peers.first(where: { $0.name == name })

            peers.removeAll(where: { $0.name == name })
            let nextPeer = Peer(clientID: peer.clientID, name: name, position: range, color: color)
            peers.append(
                nextPeer
            )
            self.updatePeerSelection(with: previous, peer: nextPeer)
            self.update(peers: peers)
        } else {
            Log.log("can not find range from: [\(fromPos):\(toPos)]", level: .warning)
        }
    }

    @MainActor
    func applyEvents(_ events: [EditStyle]?) {
        guard let events else { return }
        Log.log("applyEvents: \(events)", level: .debug)
        for event in events {
            self.lastEditStyle = event
            switch event {
            case .add(let startIndex, let text, let styles):
                self.add(startIndex: startIndex, text: text, styles: styles)
            case .style(let startIndex, let toIndex, let styles):
                self.style(startIndex: startIndex, toIndex: toIndex, styles: styles)
            case .remove(let startIndex, let toIndex):
                self.remove(startIndex: startIndex, toIndex: toIndex)
            }
        }
    }

    @MainActor
    func add(startIndex: Int, text: String, styles: [Style]) {
        Log.log("add: startIndex: \(startIndex), text: \(text), styles: \(styles)", level: .debug)
        let newAttributeString = NSMutableAttributedString(string: text)
        let newAppliedStyles = newAttributeString.apply(styles: styles)
        let attributeStringss = self.mutableAttributeString

        // Ensure startIndex is within valid bounds
        let safeStartIndex = min(startIndex, attributeStringss.length)
        attributeStringss.insert(newAppliedStyles, at: safeStartIndex)

        self.updateAttribute(attributeStringss)
    }

    @MainActor
    func style(startIndex: Int, toIndex: Int, styles: [Style]) {
        Log.log("style: startIndex: \(startIndex), toIndex: \(toIndex), styles: \(styles)", level: .debug)
        let attributeStringss = self.mutableAttributeString

        // Ensure indices are within valid bounds
        guard startIndex >= 0, toIndex <= attributeStringss.length, startIndex < toIndex else {
            Log.log("style: invalid range [\(startIndex):\(toIndex)] for length \(attributeStringss.length)", level: .warning)
            return
        }

        let newAttributeStringss = attributeStringss.apply(styles: styles, range: .init(location: startIndex, length: toIndex - startIndex))

        self.updateAttribute(newAttributeStringss)
    }

    @MainActor
    func removeStyle(startIndex: Int, toIndex: Int) {
        Log.log("remove style: startIndex: \(startIndex), toIndex: \(toIndex)", level: .debug)
        let attributeStringss = self.mutableAttributeString

        // Ensure indices are within valid bounds
        guard startIndex >= 0, toIndex <= attributeStringss.length, startIndex < toIndex else {
            Log.log("removeStyle: invalid range [\(startIndex):\(toIndex)] for length \(attributeStringss.length)", level: .warning)
            return
        }

        attributeStringss.removeAttribute(.backgroundColor, range: .init(location: startIndex, length: toIndex - startIndex))
        self.updateAttribute(attributeStringss)
    }

    @MainActor
    func remove(startIndex: Int, toIndex: Int) {
        Log.log("remove: startIndex: \(startIndex), toIndex: \(toIndex)", level: .debug)
        let attributeStringss = self.mutableAttributeString

        // Ensure indices are within valid bounds
        guard startIndex >= 0, toIndex <= attributeStringss.length, startIndex < toIndex else {
            Log.log("remove: invalid range [\(startIndex):\(toIndex)] for length \(attributeStringss.length)", level: .warning)
            return
        }

        attributeStringss.deleteCharacters(in: .init(location: startIndex, length: toIndex - startIndex))
        self.updateAttribute(attributeStringss)
    }

    func decodeStyle(from atrributes: [String: Any]?) -> [Style] {
        guard let atrributes else { return [] }
        var styles = [Style]()
        if let bold = atrributes["bold"] as? String {
            if bold == "true" {
                styles.append(.bold)
            } else if bold == "null" || bold == "false" {
                styles.append(.unBold)
            } else {
                Log.log("can not decode style: \(String(describing: atrributes["bold"]))", level: .error)
            }
        }
        if let italic = atrributes["italic"] as? String {
            if italic == "true" {
                styles.append(.italic)
            } else if italic == "null" || italic == "false" {
                styles.append(.unItalic)
            } else {
                Log.log("can not decode style: \(String(describing: atrributes["italic"]))", level: .error)
            }
        }
        if let underline = atrributes["underline"] as? String {
            if underline == "true" {
                styles.append(.underline)
            } else if underline == "null" || underline == "false" {
                styles.append(.nonUnderline)
            } else {
                Log.log("can not decode style: \(String(describing: atrributes["underline"]))", level: .error)
            }
        }
        if let strike = atrributes["strike"] as? String {
            if strike == "true" {
                styles.append(.strike)
            } else if strike == "null" || strike == "false" {
                styles.append(.unStrike)
            } else {
                Log.log("can not decode style: \(String(describing: atrributes["strike"]))", level: .error)
            }
        }

        Log.log("decoded styles: \(styles)", level: .debug)
        return styles
    }

    func decodeEvent(_ event: RemoteChangeEvent) -> [EditStyle] {
        let operations = event.value.operations
        var result: [EditStyle] = []
        for operation in operations {
            if let operation = operation as? EditOpInfo {
                let content = operation.content // this is the new string to add
                let fromIndex = operation.from // location
                let toIndex = operation.to
                let styles = self.decodeStyle(from: operation.attributes)

                if toIndex > fromIndex, content == nil {
                    result.append(.remove(startIndex: fromIndex, toIndex: toIndex))
                } else {
                    result.append(.add(startIndex: fromIndex, text: content ?? "", styles: styles))
                }
            } else if let operation = operation as? StyleOpInfo, let attributes = operation.attributes {
                let fromIndex = operation.from // location
                let toIndex = operation.to
                let styles = self.decodeStyle(from: attributes)
                result.append(.style(startIndex: fromIndex, toIndex: toIndex, styles: styles))
            } else {
                Log.log("unhandled decoded event: \(operation)", level: .warning)
            }
        }
        Log.log("decoded event: \(result)", level: .debug)
        return result
    }

    func decodePresence<T: Decodable>(_ dictionary: Any?) -> T? {
        do {
            let dictionary = dictionary as? [String: Any]
            guard let dictionary else {
                return nil
            }
            let data = try JSONSerialization.data(withJSONObject: dictionary, options: [])
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.log("decodePresence error event: \(error.localizedDescription)", level: .error)
            return nil
        }
    }
}

enum Style: Equatable {
    case bold, italic, strike, underline
    case unBold, unItalic, unStrike, nonUnderline
    case selection(r: CGFloat, g: CGFloat, b: CGFloat)

    var isBoldOrItalic: Bool {
        [.bold, .italic, .unBold, .unItalic].contains(self)
    }
}

enum EditStyle: Equatable {
    case add(startIndex: Int, text: String, styles: [Style])
    case style(startIndex: Int, toIndex: Int, styles: [Style])
    case remove(startIndex: Int, toIndex: Int)
}

extension NSMutableAttributedString {
    func apply(styles: [Style], range: NSRange? = nil) -> NSMutableAttributedString {
        let attributesString = self.mutableCopy() as! Self
        let fullRange = range ?? NSRange(location: 0, length: self.length)

        if styles.isEmpty {
            attributesString.addAttribute(.font, value: UIFont.defaulf, range: fullRange)
            return attributesString
        }

        // handle strike and underline style
        for style in styles where ![.bold, .unBold, .italic, .unItalic].contains(style) {
            switch style {
            case .strike:
                attributesString.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue], range: fullRange)
            case .underline:
                attributesString.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue], range: fullRange)
            case .unStrike:
                attributesString.removeAttribute(.strikethroughStyle, range: fullRange)
            case .nonUnderline:
                attributesString.removeAttribute(.underlineStyle, range: fullRange)
            case .selection(let r, let g, let b):
                attributesString.addAttribute(.backgroundColor, value: UIColor(red: r, green: g, blue: b, alpha: 1), range: fullRange)
            case .bold, .unBold, .italic, .unItalic:
                fatalError("not handle here!")
            }
        }

        // handle font style
        let styles = styles.filter { $0.isBoldOrItalic }
        for style in styles {
            attributesString.enumerateAttribute(.font, in: fullRange, options: []) { font, range, _ in
                // use default font if there's no font exists
                let font = font as? UIFont ?? .defaulf
                switch style {
                case .bold:
                    attributesString.addAttribute(.font, value: font.boldSelf(), range: range)
                case .italic:
                    attributesString.addAttribute(.font, value: font.italicSelf(), range: range)
                case .unBold:
                    attributesString.addAttribute(.font, value: font.unBoldSelf(), range: range)
                case .unItalic:
                    attributesString.addAttribute(.font, value: font.unItalicSelf(), range: range)
                default: fatalError("not handle here!")
                }
            }
        }
        return attributesString
    }
}

extension ContentViewModel {
    func syncTextSnapShot() {
        Log.log("syncTextSnapShot", level: .debug)
        let content = self.document.getRoot().content as? JSONText
        guard let attributes = content?.values?.map({ $0.getAttributes() }) else { return }
        let attributesString: NSMutableAttributedString
        if self.content == (content?.toString ?? "") {
            attributesString = self.mutableAttributeString
        } else {
            self.content = (content?.toString ?? "")
            attributesString = NSMutableAttributedString(string: content!.toString)
        }
        if self.didFinishSync {
            guard content?.toString != self.attributeString.string else {
                print("nothing todo here!")
                return
            }
        }

        self.didFinishSync = true
        var step = 0
        for (index, i) in attributes.enumerated() {
            let text = content!.toString

            let length = content!.values?[index].count ?? 0

            defer { step += length }
            guard step < text.utf16.count else { continue }

            // Use UTF-16 indices to handle emoji properly
            let utf16Start = text.utf16.index(text.utf16.startIndex, offsetBy: step)
            let utf16End = text.utf16.index(text.utf16.startIndex, offsetBy: min(step + length, text.utf16.count))

            // Convert UTF-16 indices to String indices safely
            guard let startIndex = utf16Start.samePosition(in: text),
                  let endIndex = utf16End.samePosition(in: text)
            else {
                Log.log("Failed to convert UTF-16 indices to String indices at step \(step)", level: .warning)
                continue
            }

            let range = startIndex ..< endIndex

            let nsRange = NSRange(range, in: text)
            var font: UIFont = .defaulf

            let isBold = i["bold"]?.value as? String == "true"
            let isItalic = i["italic"]?.value as? String == "true"

            if isBold {
                font = font.boldSelf()
            }
            if isItalic {
                font = font.italicSelf()
            }

            attributesString.addAttributes([.font: font], range: nsRange)

            // Underline
            if let underline = i["underline"]?.value as? String {
                if underline == "true" {
                    attributesString.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue], range: nsRange)
                } else {
                    attributesString.removeAttribute(.underlineStyle, range: nsRange)
                }
            }
            // Strike
            if let strike = i["strike"]?.value as? String {
                if strike == "true" {
                    attributesString.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue], range: nsRange)
                } else {
                    attributesString.removeAttribute(.strikethroughStyle, range: nsRange)
                }
            }
        }

        self.updateAttribute(attributesString)
        // notify the view to trigger view to update
        let peers = self.document.getPresences(false)

        for peer in peers {
            self.decodeEvent(peer)
        }
    }
}

// MARK: - Cursors

extension ContentViewModel {
    @MainActor
    func updateFormattingStates() {
        guard let selection = self.selection else {
            // No selection, keep current button states
            return
        }

        if self.attributeString.length == 0 {
            // Empty text, keep current button states
            return
        }

        // If there's a selection (length > 0), check if entire selection has the formatting
        // If just cursor (length == 0), check at cursor position
        let checkRange: NSRange
        if selection.length > 0 {
            checkRange = selection
        } else {
            // Check at cursor position
            var position = selection.location
            if position >= self.attributeString.length {
                position = max(0, self.attributeString.length - 1)
            }
            checkRange = NSRange(location: position, length: 1)
        }

        // Check if entire range has each formatting
        // Only update button states from text when there's a selection
        // When no selection (cursor), keep the manually toggled states
        if selection.length > 0 {
            self.isBold = self.hasFormattingInRange(checkRange, checkBold: true)
            self.isItalic = self.hasFormattingInRange(checkRange, checkItalic: true)
            self.isUnderline = self.hasFormattingInRange(checkRange, checkUnderline: true)
            self.isStrikethrough = self.hasFormattingInRange(checkRange, checkStrikethrough: true)
        }
    }

    private func hasFormattingInRange(_ range: NSRange, checkBold: Bool = false, checkItalic: Bool = false, checkUnderline: Bool = false, checkStrikethrough: Bool = false) -> Bool {
        guard range.location + range.length <= self.attributeString.length else { return false }

        var hasFormatting = true
        self.attributeString.enumerateAttributes(in: range, options: []) { attributes, _, stop in
            if checkBold || checkItalic {
                if let font = attributes[.font] as? UIFont {
                    if checkBold && !font.fontDescriptor.symbolicTraits.contains(.traitBold) {
                        hasFormatting = false
                        stop.pointee = true
                    }
                    if checkItalic && !font.fontDescriptor.symbolicTraits.contains(.traitItalic) {
                        hasFormatting = false
                        stop.pointee = true
                    }
                } else {
                    hasFormatting = false
                    stop.pointee = true
                }
            }

            if checkUnderline {
                if let underlineStyle = attributes[.underlineStyle] as? Int, underlineStyle != 0 {
                    // Has underline
                } else {
                    hasFormatting = false
                    stop.pointee = true
                }
            }

            if checkStrikethrough {
                if let strikethroughStyle = attributes[.strikethroughStyle] as? Int, strikethroughStyle != 0 {
                    // Has strikethrough
                } else {
                    hasFormatting = false
                    stop.pointee = true
                }
            }
        }

        return hasFormatting
    }

    func updateMySelection() {
        Log.log("updateMySelection", level: .debug)
        guard let selection else { return }
        try? self.document.update { root, presence in
            let fromIdx = selection.location
            let toIdx = selection.location + selection.length
            guard ((root.content as? JSONText)?.length ?? 0) >= fromIdx else { return }

            if let range = try? (root.content as? JSONText)?.indexRangeToPosRange((fromIdx, toIdx)) {
                let array = [range.0, range.1]

                presence.set(["selection": array])

                Log.log("selection: \(fromIdx) -> \(toIdx) | range: \(range)", level: .debug)
            } else {
                Log.log("selection: \(fromIdx) -> \(toIdx) | range: NIL", level: .warning)
            }
        }
    }

    @MainActor
    func update(peers: [Peer]) {
        Log.log("peers: \(peers.map { $0.name }.sorted().joined(separator: ", "))", level: .debug)
        self.peers = peers
        for i in peers where i.name != self.localUsername {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                // TODO: - Refactor this to wait until the text is updated after adding cursor without using DispatchQueueMain
                self.placeCursor(at: i.position.location, in: self.uitextView, with: i)
            }
        }
    }

    func removePeerCursor(_ peer: Peer, in textView: UITextView) {
        let subviews = textView.subviews.filter { $0.accessibilityLabel == peer.name }
        for subview in subviews {
            subview.removeFromSuperview()
        }
    }

    func placeCursor(at index: Int, in textView: UITextView, with peer: Peer) {
        let subviews = textView.subviews.filter { $0.accessibilityLabel == peer.name }
        for subview in subviews {
            subview.removeFromSuperview()
        }

        guard index <= textView.text.count else { return }

        // get UITextPosition from character offset
        if let position = textView.position(from: textView.beginningOfDocument, offset: index) {
            // Get caret rectangle at that position
            let caretRect = textView.caretRect(for: position)
            let _color = peer.color.rgb()
            let color = UIColor(red: _color.r, green: _color.g, blue: _color.b, alpha: _color.a)

            // Create and place custom cursor
            let cursor = CustomCursorView(
                frame: CGRect(x: caretRect.origin.x, y: caretRect.origin.y, width: 2, height: caretRect.height),
                color: color
            )
            cursor.accessibilityLabel = peer.name

            // Remove old cursor if needed
            textView.subviews.filter { $0.accessibilityLabel == peer.clientID }.forEach { $0.removeFromSuperview() }

            textView.addSubview(cursor)

            let contentView = UILabel()
            contentView.text = peer.name
            contentView.font = UIFont.systemFont(ofSize: 14)
            contentView.textColor = .white

            contentView.backgroundColor = color
            contentView.layer.cornerRadius = 6
            contentView.clipsToBounds = true
            contentView.sizeToFit()
            let padding: CGFloat = 2
            contentView.frame = CGRect(
                x: caretRect.origin.x,
                y: caretRect.maxY + padding,
                width: contentView.frame.width + 12,
                height: contentView.frame.height + 6
            )
            contentView.accessibilityLabel = peer.name
            textView.addSubview(contentView)
        }
    }

    func updatePeerSelection(with previous: Peer?, peer: Peer?) {
        // Log.log("peer selection: \(peer.name)|\(peer.id)|[\(peer.position.location),\(peer.position.length)]", level: .debug)
        // prevent out of bounds
        let attribute: NSMutableAttributedString = self.mutableAttributeString
        // guard !self.content.isEmpty else { return }
        if let previous, previous.position.length + previous.position.location <= self.mutableAttributeString.string.count {
            attribute.removeAttribute(.backgroundColor, range: previous.position)
            self.removeStyle(startIndex: previous.position.location, toIndex: previous.position.length + previous.position.location)
        }

        // color the peer when length is more than 0
        // the peer is selecting
        guard !self.content.isEmpty else {
            self.updateAttribute(attribute)
            return
        }
        guard let peer else { return }
        if peer.position.length > 0, peer.position.length + peer.position.location <= self.mutableAttributeString.string.count {
            let color = peer.color.rgb()
            self.style(
                startIndex: peer.position.location,
                toIndex: peer.position.length + peer.position.location,
                styles: [.selection(r: color.r, g: color.g, b: color.b)]
            )
        }
    }
}
