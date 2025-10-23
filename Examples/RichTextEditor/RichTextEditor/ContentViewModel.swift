//
//  ContentViewModel.swift
//  RichTextEditor
//
//  Created by ivan.do on 8/10/25.
//

import Foundation
import UIKit
import Yorkie

/// requirements:
/// [DONE] adding text from FE and sync to iOS with correct attribute
/// [DONE] adding text from iOS and sync to FE with correct attribute
/// [DONE] style text from FE and sync to iOS with correct attribute
/// [DONE] style text from iOS and sync to FE with correct attribute
/// [DONE] remove text from FE and sync to iOS
/// [DONE] remove text from iOS and sunc to FE
///
/// [DONE] sync selection from FE to iOS
/// [DONE] sync selection from iOS to FE
///
/// sync cursor from FE to iOS
/// sync cursor from iOS to FE
///
/// [DONE] adding text from FE can make cursor of iOS change unintented

@Observable
class ContentViewModel {
    let uitextView = UITextView()

    @ObservationIgnored private var client: Client
    @ObservationIgnored private let document: Document
    @ObservationIgnored var selection: NSRange? {
        didSet {
            self.updateMySelection()
        }
    }

    var triggerFlag = false
    @ObservationIgnored private var content: String = ""
    var attributeString = NSMutableAttributedString(string: "")
    var lastEditStyle: EditStyle?
    var mutableAttributeString: NSMutableAttributedString {
        self.attributeString.mutableCopy() as! NSMutableAttributedString
    }

    func updateAttribute(_ attribute: NSMutableAttributedString, _ function: String = #function) {
        Log.log("[Attribute change] function: \(function) -> \(attribute)", level: .debug)
        self.attributeString = attribute
    }

    @ObservationIgnored var peers = [Peer]()

    init() {
        self.client = Client(Constant.serverAddress)
        self.document = Document(key: Constant.documentKey)
    }
}

// MARK: - Yorkie handler

extension ContentViewModel {
    func initializeClient() async {
        do {
            try await self.client.activate()

            try await self.client.attach(self.document, [
                "username": "iOS",
                "color": "#a83267"
            ])
            self.syncTextSnapShot()

            await self.watch()
        } catch {
            print(error.localizedDescription)
        }
    }

    func updateText(ranges: [NSValue], value: String, fonts: [CustomFont]) {
        // TODO: - Crash!
        try? self.document.update { [weak self] root, _ in
            guard let self, let content = root.content as? JSONText else {
                return
            }
            guard let ranges = ranges as? [NSRange], let range = ranges.first else { return }
            let toIdx = range.location + range.length
            content.edit(range.location, toIdx, value, fonts.attributes)
            if value.isEmpty {
                // delete
                let att = self.mutableAttributeString
                att.deleteCharacters(in: range)
                self.updateAttribute(att)
            } else {
                // insert character
                let att = self.mutableAttributeString
                let newAttribute = NSMutableAttributedString(string: value)
                let isBold = fonts.contains(.bold)
                let isItalic = fonts.contains(.italic)
                var font = UIFont.defaulf
                if isBold { font = font.boldSelf() }
                if isItalic { font = font.italicSelf() }

                // add font style (bold and italic)
                let _range = NSRange(location: 0, length: 1)
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
                att.insert(newAttribute, at: range.location)
                self.updateAttribute(att)
            }
        }
    }

    func custom(range: NSRange, font: CustomFont, value: Bool) {
        try? self.document.update { root, _ in
            guard let content = root.content as? JSONText else { return }

            let toIdx = range.location + range.length
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
            } else if let event = event as? SyncStatusChangedEvent {
                // for debug only
                print(event)
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
        return result
    }

    func decodeEvent(_ peer: PeerElement) {
        // change selection
        // change cursors
        if (peer.presence["username"] as? String ?? "iOS") == "iOS" {
            print("[debug] event: -> this is iOS, ignore changed!")
            return
        }
        guard let presencesChanges = peer.presence["selection"] as? [Any] else {
            return
        }
        guard presencesChanges.count == 2 else { return }
        let name = peer.presence["username"] as? String ?? "anonymous"
        let color = peer.presence["color"] as? String ?? "anonymous"

        let fromIDs: TextPosStruct? = self.decodePresence(presencesChanges.first!)
        let toIDs: TextPosStruct? = self.decodePresence(presencesChanges.last!)

        guard let fromIDs, let toIDs else { return }

        let (fromPos, toPos) = (fromIDs, toIDs)

        if let (fromIdx, toIdx) = try? (self.document.getRoot().content as? JSONText)?.posRangeToIndexRange((fromPos, toPos)) {
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
        }
    }

    func applyEvents(_ events: [EditStyle]?) {
        print("[debug] -> apply events: \(events)")
        guard let events else { return }
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

    func add(startIndex: Int, text: String, styles: [Style]) {
        let newAttributeString = NSMutableAttributedString(string: text)
        let newAppliedStyles = newAttributeString.apply(styles: styles)
        let attributeStringss = self.mutableAttributeString
        attributeStringss.insert(newAppliedStyles, at: startIndex)

        self.updateAttribute(attributeStringss)
    }

    func style(startIndex: Int, toIndex: Int, styles: [Style]) {
        let attributeStringss = self.mutableAttributeString
        let newAttributeStringss = attributeStringss.apply(styles: styles, range: .init(location: startIndex, length: toIndex - startIndex))

        self.updateAttribute(newAttributeStringss)
    }

    func removeStyle(startIndex: Int, toIndex: Int) {
        let attributeStringss = self.mutableAttributeString
        attributeStringss.removeAttribute(.backgroundColor, range: .init(location: startIndex, length: toIndex - startIndex))
        self.updateAttribute(attributeStringss)
    }

    func remove(startIndex: Int, toIndex: Int) {
        guard self.attributeString.string.count >= toIndex else { return }
        let attributeStringss = self.mutableAttributeString
        // TODO: - Crashs
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
                print("Error, can not handle this style: \((atrributes["bold"] as? String) ?? "NIL")")
            }
        }
        if let italic = atrributes["italic"] as? String {
            if italic == "true" {
                styles.append(.italic)
            } else if italic == "null" || italic == "false" {
                styles.append(.unItalic)
            } else {
                print("Error, can not handle this style: \((atrributes["italic"] as? String) ?? "NIL")")
            }
        }
        if let underline = atrributes["underline"] as? String {
            if underline == "true" {
                styles.append(.underline)
            } else if underline == "null" || underline == "false" {
                styles.append(.nonUnderline)
            } else {
                print("Error, can not handle this style: \((atrributes["underline"] as? String) ?? "NIL")")
            }
        }
        if let strike = atrributes["strike"] as? String {
            if strike == "true" {
                styles.append(.strike)
            } else if strike == "null" || strike == "false" {
                styles.append(.unStrike)
            } else {
                print("Error, can not handle this style: \((atrributes["strike"] as? String) ?? "NIL")")
            }
        }
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
            }
        }
        return result
    }

    func syncPeerSelection(previous: Peer? = nil, peer: Peer) {
        guard let attribute: NSMutableAttributedString = self.attributeString.mutableCopy() as? NSMutableAttributedString else { return }
        guard !self.content.isEmpty else { return }
        if let previous, previous.position.length + previous.position.location <= self.attributeString.string.count {
            attribute.removeAttribute(.backgroundColor, range: previous.position)
        }
        defer {
            updateAttribute(attribute)
        }

        // color the peer when length is more than 0
        // the peer is selecting
        guard !self.content.isEmpty else {
            self.updateAttribute(attribute)
            return
        }
        if peer.position.length > 0, peer.position.length + peer.position.location <= self.attributeString.string.count {
            let color = peer.color.rgb()
            attribute.addAttribute(
                .backgroundColor,
                value: UIColor(
                    red: color.r,
                    green: color.g,
                    blue: color.b,
                    alpha: color.a
                ),
                range: peer.position
            )
        }
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
        let content = self.document.getRoot().content as? JSONText
        guard let attributes = content?.values?.map({ $0.getAttributes() }) else { return }
        let attributesString: NSMutableAttributedString
        if self.content == (content?.toString ?? "") {
            attributesString = self.mutableAttributeString
        } else {
            self.content = (content?.toString ?? "")
            attributesString = NSMutableAttributedString(string: content!.toString)
        }

        var step = 0
        for (index, i) in attributes.enumerated() {
            let text = content!.toString

            let length = content!.values?[index].count ?? 0

            defer { step += length }

            let startIndex = text.index(text.startIndex, offsetBy: max(step, 0))
            let endIndex = text.index(text.startIndex, offsetBy: min(max(step + length + 1, 0), text.count))

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
        print(peers)
        for peer in peers {
            self.decodeEvent(peer)
        }
    }
}

// MARK: - Cursors

extension ContentViewModel {
    func updateMySelection() {
        guard let selection else { return }
        try? self.document.update { root, presence in
            let fromIdx = selection.location
            let toIdx = selection.location + selection.length
            guard ((root.content as? JSONText)?.length ?? 0) >= fromIdx else { return }

            if let range = try? (root.content as? JSONText)?.indexRangeToPosRange((fromIdx, toIdx)) {
                let array = [range.0, range.1]

                presence.set(["selection": array])
            }
        }
    }

    func update(peers: [Peer]) {
        self.peers = peers
        for i in peers where i.name != "iOS" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                // TODO: - Refactor this to wait until the text is updated after adding cursor without using DispatchQueueMain
                self.placeCursor(at: i.position.location, in: self.uitextView, with: i)
            }
        }
    }

    func placeCursor(at index: Int, in textView: UITextView, with peer: Peer) {
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
            cursor.accessibilityLabel = peer.clientID

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
            contentView.accessibilityLabel = peer.clientID
            textView.addSubview(contentView)
        }
    }

    func updatePeerSelection(with previous: Peer?, peer: Peer) {
        // prevent out of bounds
        let attribute: NSMutableAttributedString = self.mutableAttributeString
        // guard !self.content.isEmpty else { return }
        if let previous, previous.position.length + previous.position.location <= self.mutableAttributeString.string.count {
            // TODO: - this crashs!
            attribute.removeAttribute(.backgroundColor, range: previous.position)
            self.removeStyle(startIndex: previous.position.location, toIndex: previous.position.length + previous.position.location)
        }

        // color the peer when length is more than 0
        // the peer is selecting
        guard !self.content.isEmpty else {
            self.updateAttribute(attribute)
            return
        }
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

extension Collection where Element == CustomFont {
    var attributes: [String: Bool] {
        self.reduce(into: [String: Bool]()) { partialResult, element in
            partialResult[element.rawValue] = true
        }
    }
}
