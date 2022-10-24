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

import XCTest
@testable import Yorkie

class TrieTests: XCTestCase {
    let philWords = ["phil", "philosophy", "philanthropy", "philadelphia"]
    let unWords = ["un", "undo", "unpack", "unhappy"]
    let otherWords = ["english", "hello"]
    var words: [String] {
        return self.philWords + self.unWords + self.otherWords
    }

    func test_can_find_words_with_specific_prefix() {
        let trie = Trie<String>(value: "")
        for word in self.words {
            trie.insert(values: word.map { String($0) })
        }
        let philResult = trie
            .find(prefix: "phil".map { String($0) })
            .map { $0.joined(separator: "") }

        let unResult = trie
            .find(prefix: "un".map { String($0) })
            .map { $0.joined(separator: "") }
        XCTAssertEqual(self.philWords.sorted(), philResult.sorted())
        XCTAssertEqual(self.unWords.sorted(), unResult.sorted())
    }

    func test_can_find_prefixes() {
        let trie = Trie<String>(value: "")
        for word in self.words {
            trie.insert(values: word.map { String($0) })
        }
        let commonPrefixes = ["phil", "un"] + self.otherWords
        let prefixesResult = trie
            .findPrefixes()
            .map { $0.joined(separator: "") }
        XCTAssertEqual(commonPrefixes.sorted(), prefixesResult.sorted())
    }
}
