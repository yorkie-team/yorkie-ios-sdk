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
