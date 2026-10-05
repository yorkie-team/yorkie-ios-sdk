/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

import Foundation

extension String {
    func substring(from: Int, to: Int) -> String {
        guard from <= to, from < self.count else {
            return ""
        }

        let adaptedTo = min(to, self.count - 1)

        let start = index(self.startIndex, offsetBy: from)
        let end = index(self.startIndex, offsetBy: adaptedTo)
        let range = start ... end

        return String(self[range])
    }

    var toDocKey: String {
        let lower = self.lowercased()
        let regex = try? NSRegularExpression(pattern: "[^a-z0-9-]")

        return regex?.stringByReplacingMatches(in: lower, options: [], range: NSRange(0 ..< lower.count), withTemplate: "-").substring(from: 0, to: 119) ?? ""
    }

    var toJSONObject: Any {
        if let data = self.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? self
        }

        return self
    }

    var toJSONString: String {
        convertToJSONString(self)
    }
}

/**
 * `isJSONDocument` reports whether the given string would parse as JSON, and so
 * could not be told apart from the value it encodes if it were stored raw.
 */
func isJSONDocument(_ value: String) -> Bool {
    guard let data = value.data(using: .utf8) else {
        return false
    }
    return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
}

/**
 * `stringifyAttrValue` encodes one attribute value for storage.
 *
 * A string that is not itself a JSON document is stored as-is, which is what
 * the Go SDK stores for the same attribute, so `color="red"` puts the same three
 * bytes on the wire from either SDK. A string that IS a JSON document keeps its
 * quotes, because raw storage could not tell it from the value it encodes: "1"
 * would come back as the number 1 and "true" as the boolean.
 */
func stringifyAttrValue(_ value: Any) -> String {
    if let string = value as? String, !isJSONDocument(string) {
        return string
    }
    return convertToJSONString(value)
}

/**
 * `logicalAttrValue` returns the attribute value as a peer storing values raw
 * would hold it: a JSON-encoded string yields the string itself, anything else
 * yields the stored text unchanged. A value written raw does not parse at all
 * and passes straight through.
 */
func logicalAttrValue(_ stored: String) -> String {
    (stored.toJSONObject as? String) ?? stored
}

func convertToJSONString(_ data: Any) -> String {
    if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]),
       let escapedValue = String(bytes: jsonData, encoding: .utf8)
    {
        return escapedValue
    }
    return "null"
}
