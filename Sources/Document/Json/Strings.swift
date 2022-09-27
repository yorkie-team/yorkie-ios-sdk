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

/**
 * `EscapeString` escapes string.
 */
extension String {
    static let escapeSequences = [
        (original: "\\", escaped: "\\\\"),
        (original: "\"", escaped: "\\\""),
        (original: "'", escaped: "\\'"),
        (original: "\n", escaped: "\\n"),
        (original: "\r", escaped: "\\r"),
        (original: "\t", escaped: "\\t"),
        (original: "\u{2028}", escaped: "\\u{2028}"),
        (original: "\u{2029}", escaped: "\\u{2029}")
    ]

    func escaped() -> String {
        return String.escapeSequences.reduce(self) { string, seq in
            string.replacingOccurrences(of: seq.original, with: seq.escaped)
        }
    }
}
