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
        for operation in operations {
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

/**
 * `buildIndexTree` builds an index tree from the given element node.
 */
func buildIndexTree(_ node: JSONTreeElementNode) async throws -> IndexTree<CRDTTreeNode>? {
    let doc = Document(key: "test")
    try await doc.update { root, _ in
        root.t = JSONTree(initialRoot: node)
    }
    return try await(doc.getRoot().t as? JSONTree)?.getIndexTree()
}

/**
 * `idT` is a dummy CRDTTreeNodeID for testing.
 */
let idT = CRDTTreeNodeID(createdAt: TimeTicket.initial, offset: 0)

/**
 * `dummyContext` is a helper context that is used for testing.
 */
let dummyContext = ChangeContext(id: ChangeID.initial, root: CRDTRoot())

/**
 * `posT` is a helper function that issues a new CRDTTreeNodeID.
 */
func posT(_ offset: Int32 = 0) -> CRDTTreeNodeID {
    CRDTTreeNodeID(createdAt: dummyContext.issueTimeTicket, offset: offset)
}

/**
 * `timeT` is a helper function that issues a new TimeTicket.
 */
func timeT() -> TimeTicket {
    dummyContext.issueTimeTicket
}

extension Task where Success == Never, Failure == Never {
    /**
     * `sleep` is a helper function that suspends the current task for the given milliseconds.
     */
    static func sleep(miliseconds: UInt64) async throws {
        try await self.sleep(nanoseconds: miliseconds * 1_000_000)
    }
}

/**
 * `sleep` is a helper function that suspends the current task for the given milliseconds.
 */
func sleep(milliseconds: UInt64) async throws {
    try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
}

/**
 * `BroadcastExpectValue` is a helper struct for easy equality comparison in test functions.
 */
public struct BroadcastExpectValue: Equatable {
    public let topic: String
    public let payload: Payload

    public static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.topic == rhs.topic && lhs.payload == rhs.payload
    }
}
