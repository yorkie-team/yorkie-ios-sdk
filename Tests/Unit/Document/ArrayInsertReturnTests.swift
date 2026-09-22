/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
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

/// `insertAfter` wraps what `insertAfterInternal` returns in a proxy and hands it to the
/// caller. The container branches build a clone, insert *that*, and populate it -- so
/// returning the original left the caller holding a proxy over a detached element.
///
/// It fails quietly rather than loudly: the root still takes the writes, because operations
/// address elements by `createdAt`, so only the clone is left behind. The clone is what
/// `Document.update` measures against `maxSizeLimit` and what later index-based edits resolve
/// against, so the two drifting apart is the whole problem.
final class ArrayInsertReturnTests: XCTestCase {
    @MainActor
    func test_the_proxy_returned_for_an_inserted_object_writes_through_to_the_clone() throws {
        // given
        let doc = Document(key: "insert-return-object")
        try doc.update { root, _ in root.arr = [Int64(0)] }
        let ids = (doc.getRootObject().get(key: "arr") as? CRDTArray)?.map { $0.createdAt } ?? []

        // when -- mutate through the proxy the insert handed back.
        try doc.update { root, _ in
            guard let arr = root.arr as? JSONArray else { return }
            let inserted = try arr.insertAfter(previousID: ids[0], value: ["a": Int64(1)] as [String: Any])
            (inserted as? JSONObject)?.set(key: "b", value: Int64(2))
        }

        // then
        XCTAssertEqual(doc.toSortedJSON(), "{\"arr\":[0,{\"a\":1,\"b\":2}]}")
        XCTAssertEqual(doc.getCloneRoot()?.toSortedJSON(), doc.toSortedJSON(),
                       "the write went to a detached element, so the clone never saw it")
    }

    @MainActor
    func test_the_proxy_returned_for_an_inserted_array_writes_through_to_the_clone() throws {
        // given
        let doc = Document(key: "insert-return-array")
        try doc.update { root, _ in root.arr = [Int64(0)] }
        let ids = (doc.getRootObject().get(key: "arr") as? CRDTArray)?.map { $0.createdAt } ?? []

        // when
        try doc.update { root, _ in
            guard let arr = root.arr as? JSONArray else { return }
            let inserted = try arr.insertAfter(previousID: ids[0], value: [Int64(9)] as [Any])
            (inserted as? JSONArray)?.append(Int64(8))
        }

        // then
        XCTAssertEqual(doc.toSortedJSON(), "{\"arr\":[0,[9,8]]}")
        XCTAssertEqual(doc.getCloneRoot()?.toSortedJSON(), doc.toSortedJSON(),
                       "the append went to a detached element, so the clone never saw it")
    }
}
