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
 * `TrieNode` is node of Trie.
 */
class TrieNode<V: Hashable> {
    fileprivate var value: V
    fileprivate var children: [V: TrieNode<V>]
    fileprivate var parent: TrieNode<V>?
    fileprivate var isTerminal: Bool

    init(value: V, parent: TrieNode<V>? = nil) {
        self.value = value
        self.children = [:]
        self.isTerminal = false
        self.parent = parent
    }

    /**
     * `getPath` returns the path from the Trie root to this node.
     * @returns array of path from Trie root to this node
     */
    func getPath() -> [V] {
        var path: [V] = []
        var node: TrieNode<V>? = self
        while true {
            guard let current = node else {
                break
            }

            path.append(current.value)
            node = current.parent
        }
        return path.reversed()
    }
}

extension TrieNode: CustomStringConvertible {
    var description: String {
        return String(describing: self.value)
    }
}

/**
 * `Trie` is a type of k-ary search tree for locating specific values or common prefixes.
 */
class Trie<V: Hashable> {
    private var root: TrieNode<V>

    init(value: V) {
        self.root = TrieNode<V>(value: value)
    }

    /**
     * `insert` inserts the value to the Trie
     * @param values - values array
     * @returns array of find result
     */
    func insert(values: [V]) {
        var node = self.root
        for value in values {
            if let child = node.children[value] {
                node = child
            } else {
                let child = TrieNode(value: value, parent: node)
                node.children[value] = child
                node = child
            }
        }
        node.isTerminal = true
    }

    /**
     * `find` finds all words that have the prefix in the Trie
     * @param prefix - prefix array
     */
    func find(prefix: [V]) -> [[V]] {
        var node = self.root
        for value in prefix {
            if let child = node.children[value] {
                node = child
            } else {
                return []
            }
        }
        var result: [[V]] = []
        self.traverse(node: node, isTerminalIncluded: true, output: &result)
        return result
    }

    /**
     * `traverse` does a depth first to push necessary elements to the output
     * @param node - node to start the depth first search
     * @param isTerminalIncluded - whether to traverse till the terminal or not
     * @param output - the output array
     */
    func traverse(node: TrieNode<V>, isTerminalIncluded: Bool, output: inout [[V]]) {
        if node.isTerminal {
            output.append(node.getPath())
            if isTerminalIncluded == false {
                return
            }
        }
        for (_, value) in node.children {
            self.traverse(node: value, isTerminalIncluded: isTerminalIncluded, output: &output)
        }
    }

    /**
     * `findPrefixes` finds the prefixes added to the Trie.
     * @returns array of prefixes
     */
    func findPrefixes() -> [[V]] {
        var prefixes: [[V]] = []
        for (_, value) in self.root.children {
            self.traverse(node: value, isTerminalIncluded: false, output: &prefixes)
        }
        return prefixes
    }
}

extension Trie: CustomDebugStringConvertible {
    var debugDescription: String {
        var result: [[V]] = []
        for (_, value) in self.root.children {
            self.traverse(node: value, isTerminalIncluded: true, output: &result)
        }
        return result.map { $0.description }.joined(separator: ".")
    }
}
