/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
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
@testable import Yorkie

/**
 * TextView emulates an external editor like CodeMirror to test whether change
 * events are delivered properly.
 */
class TextView {
    private var value: String = ""

    public func applyChanges(operations: [any OperationInfo], enableLog: Bool = false) {
        let oldValue = self.value
        var changeLogs = [String]()
        operations.forEach { operation in
            if let operation = operation as? EditOpInfo {
                self.value = [
                    self.value.substring(from: 0, to: operation.from - 1),
                    operation.content ?? "",
                    self.value.substring(from: operation.to, to: self.value.count - 1)
                ].joined(separator: "")

                changeLogs.append("{f:\(operation.from), t:\(operation.to), c:\(operation.content ?? "")}")
            }
        }

        if enableLog {
            print("apply: \(oldValue)->\(self.value) [\(changeLogs.joined(separator: ","))]")
        }
    }

    public var toString: String {
        self.value
    }
}

private extension String {
    func substring(from: Int, to: Int) -> String {
        guard from <= to, from < self.count, from >= 0 else {
            return ""
        }

        let adaptedTo = min(to, self.count - 1)

        let start = index(self.startIndex, offsetBy: from)
        let end = index(self.startIndex, offsetBy: adaptedTo)
        let range = start ... end

        return String(self[range])
    }
}

/**
 * `buildIndexTree` builds an index tree from the given element node.
 */
func buildIndexTree(_ node: JSONTreeElementNode) async throws -> IndexTree<CRDTTreeNode>? {
    let doc = Document(key: "test")
    try await doc.update { root in
        root.t = JSONTree(initialRoot: node)
    }
    return try await(doc.getRoot().t as? JSONTree)?.getIndexTree()
}
