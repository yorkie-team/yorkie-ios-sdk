/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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
import Foundation

/// Escapes string.
private enum JsonEscape {
    static let tempPlaceHolder = UUID().uuidString
    static let backSlash = "\\"
    static let escapedBackSlash = "\\\\"

    /// Escaping based on JS-SDK
    static let escapeSequences = [
        (original: JsonEscape.backSlash, escaped: JsonEscape.escapedBackSlash),
        (original: "\"", escaped: "\\\""),
        (original: "'", escaped: "\\'"),
        (original: "\n", escaped: "\\n"),
        (original: "\r", escaped: "\\r"),
        (original: "\t", escaped: "\\t"),
        (original: "\u{0008}", escaped: "\\b"),
        (original: "\u{000C}", escaped: "\\f"),
        (original: "\u{2028}", escaped: "\\u2028"),
        (original: "\u{2029}", escaped: "\\u2029")
    ]
}

extension String {
    func escaped() -> String {
        return JsonEscape.escapeSequences.reduce(self) { string, seq in
            string.replacingOccurrences(of: seq.original, with: seq.escaped)
        }
    }

    func unescaped() -> String {
        let target = self.replacingOccurrences(of: JsonEscape.escapedBackSlash, with: JsonEscape.tempPlaceHolder)

        let temp = JsonEscape.escapeSequences.reduce(target) { string, seq in
            string.replacingOccurrences(of: seq.escaped, with: seq.original)
        }

        return temp.replacingOccurrences(of: JsonEscape.tempPlaceHolder, with: JsonEscape.backSlash)
    }
}

/// Text and Tree indexes count UTF-16 code units (`NSString.length`, matching JS's
/// `string.length`), so a local index between the two halves of a non-BMP character splits the
/// node mid-pair. Go turns each lone half into U+FFFD while JS keeps the raw code unit, so the
/// same operation would leave different text on different SDKs. These helpers are the iOS half
/// of yorkie-js-sdk's `ensureUTF16Boundary`/`ensureNoLoneSurrogate` (yorkie-js-sdk#1447, the JS
/// side of yorkie-team/yorkie#2085).

/// Reports whether a boundary between the code units `before` and `after` falls inside a
/// surrogate pair. A missing unit (`nil`, what reading past either end of the string yields)
/// never pairs.
func splitsSurrogatePair(_ before: unichar?, _ after: unichar?) -> Bool {
    guard let before, let after else {
        return false
    }

    return (0xD800 ... 0xDBFF).contains(before) && (0xDC00 ... 0xDFFF).contains(after)
}

/// Reports whether `offset`, counted in UTF-16 code units, is a valid boundary in `value`, i.e.
/// it does not fall between the high and the low surrogate of a pair.
func isUTF16Boundary(_ value: NSString, _ offset: Int) -> Bool {
    let before: unichar? = (offset - 1 >= 0 && offset - 1 < value.length) ? value.character(at: offset - 1) : nil
    let after: unichar? = (offset >= 0 && offset < value.length) ? value.character(at: offset) : nil

    return !splitsSurrogatePair(before, after)
}

/// Throws when a local index between the code units `before` and `after` splits a surrogate
/// pair. An index there would split the node mid-pair, and the SDKs store the lone halves
/// differently: Go turns each into U+FFFD, JS (and this SDK, which stores text as `NSString` to
/// keep UTF-16 offsets) keeps the raw code unit. Rejecting it keeps the same operation from
/// leaving different text on different replicas.
///
/// - Throws: ``YorkieError`` with code `errInvalidArgument` when the boundary splits a pair.
func ensureUTF16Boundary(_ before: unichar?, _ after: unichar?) throws {
    if splitsSurrogatePair(before, after) {
        throw YorkieError(code: .errInvalidArgument, message: "index must not split a UTF-16 surrogate pair")
    }
}

/// Throws when `value` holds a surrogate code unit that is not part of a pair. Rejecting the
/// index that would split a pair is only half of the contract: content carrying a lone half has
/// the same divergence (Go stores U+FFFD, JS the raw code unit), and once stored it also pairs
/// up with whatever code unit it lands against, so the index at that seam becomes one
/// ``ensureUTF16Boundary(_:_:)`` refuses for as long as the text lives. Refusing the content
/// keeps a local edit from manufacturing either.
///
/// - Throws: ``YorkieError`` with code `errInvalidArgument` when `value` contains a lone
///   surrogate.
func ensureNoLoneSurrogate(_ value: String) throws {
    let nsValue = value as NSString
    var index = 0
    while index < nsValue.length {
        let code = nsValue.character(at: index)
        guard (0xD800 ... 0xDFFF).contains(code) else {
            index += 1
            continue
        }

        // A high surrogate followed by a low one is a whole character; step over both.
        // Anything else reaching here is a half on its own.
        let next: unichar? = index + 1 < nsValue.length ? nsValue.character(at: index + 1) : nil
        if splitsSurrogatePair(code, next) {
            index += 2
            continue
        }

        throw YorkieError(code: .errInvalidArgument, message: "content must not contain a lone UTF-16 surrogate")
    }
}
