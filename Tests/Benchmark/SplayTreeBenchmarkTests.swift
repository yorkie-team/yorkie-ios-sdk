/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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

private class StringNode: SplayNode<String> {
    var removed: Bool = false
    override init(_ value: String) {
        super.init(value)
    }

    static func create(_ value: String) -> StringNode {
        return StringNode(value)
    }

    override var length: Int {
        if self.removed {
            return 0
        }
        return self.value.count
    }
}

final class SplayTreeBenchmarkTests: XCTestCase {
    func randomValue(zeroUpTo value: Int) -> Int {
        guard value > 0 else {
            return 0
        }
        return Int.random(in: 0 ..< value)
    }

    func benchmarkRandomAccess(size: Int) throws {
        let tree = SplayTree<String>()
        for _ in 0 ..< size {
            tree.insert(StringNode("A"))
        }
        for index in 0 ..< 1000 {
            _ = try tree.find(self.randomValue(zeroUpTo: index))
        }
    }

    func stressTest(size: Int) throws {
        let tree = SplayTree<String>()
        var treeSize = 1

        for _ in 0 ..< size {
            let op = Int.random(in: 0 ..< 3)
            if op == 0 {
                if let node = try tree.find(Int.random(in: 0 ..< treeSize)).node {
                    tree.insert(previousNode: node, newNode: StringNode("A"))
                } else {
                    tree.insert(StringNode("A"))
                }
                treeSize += 1
            } else if op == 1 {
                _ = try tree.find(Int.random(in: 0 ..< treeSize))
            } else {
                if let node = try tree.find(Int.random(in: 0 ..< treeSize)).node {
                    tree.delete(node)
                    treeSize -= 1
                }
            }
        }
    }

    // MARK: - Performance Tests

    func testSplayTreeStree10000() throws {
        self.measure {
            try? self.stressTest(size: 10000)
        }
    }

    func testSplayTreeStree20000() throws {
        self.measure {
            try? self.stressTest(size: 20000)
        }
    }

    func testSplayTreeStree30000() throws {
        self.measure {
            try? self.stressTest(size: 30000)
        }
    }

    func testSplayTreeRandomAccess10000() throws {
        self.measure {
            try? self.benchmarkRandomAccess(size: 10000)
        }
    }

    func testSplayTreeRandomAccess20000() throws {
        self.measure {
            try? self.benchmarkRandomAccess(size: 20000)
        }
    }

    func testSplayTreeRandomAccess30000() throws {
        self.measure {
            try? self.benchmarkRandomAccess(size: 30000)
        }
    }

    func check_testSplayTreeEditingTrace() throws {
        guard let editTraceData = loadEditTraceData() else {
            XCTFail("Failed to load editing-trace.json")
            return
        }

        self.measure {
            let tree = SplayTree<String>()

            for edit in editTraceData {
                guard let operation = edit[0] as? Int, let position = edit[1] as? Int else {
                    continue
                }

                switch operation {
                case 0:
                    if let value = edit[2] as? String, let node = try? tree.find(position).node {
                        tree.insert(previousNode: node, newNode: StringNode(value))
                    }
                case 1:
                    if let nodeToDelete = try? tree.find(position).node {
                        tree.delete(nodeToDelete)
                    }
                default:
                    break
                }
            }
        }
    }

    private func loadEditTraceData() -> [[Any]]? {
        guard let path = Bundle(for: type(of: self)).path(forResource: "editing-trace", ofType: "json") else {
            return nil
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if let jsonResult = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let edits = jsonResult["edits"] as? [[Any]]
            {
                return edits
            }
        } catch {
            print("Error loading JSON: \(error)")
        }
        return nil
    }
}
