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

import XCTest
@testable import Yorkie

class JSONProxyTests: XCTestCase {
    func test_can_set() {
        let target = TestDocument<DocComponentA>()
        target.update { root in
            root.boolean = true
            root.integer = 111
            root.long = 9_999_999
            root.double = 1.2222222
            root.string = "abc"

            root.compB = JSONObject<DocComponentB>()
            root.compB?.compC = JSONObject<DocComponentC>()
            root.compB?.id = "b"

            root.compB?.compC?.id = "c"
            root.compB?.compC?.compD = JSONObject<DocComponentD>()

            root.compB?.compC?.compD?.id = "d-1"

            XCTAssertEqual(root.toSortedJSON(),
                           """
                           {"boolean":"true","double":1.2222222,"integer":111,"long":9999999,"nested":{"id":"b","nested":{"id":"c","nested":{"id":"d-1"}}},"string":"abc"}
                           """)

            root.compB?.compC?.compD?.id = "d-2"

            XCTAssertEqual(root.toSortedJSON(),
                           """
                           {"boolean":"true","double":1.2222222,"integer":111,"long":9999999,"nested":{"id":"b","nested":{"id":"c","nested":{"id":"d-2"}}},"string":"abc"}
                           """)
        }
    }

    func test_can_remove() throws {
        let target = TestDocument<DocComponentA>()
        target.update { root in
            root.boolean = true
            root.integer = 111
            root.long = 9_999_999
            root.double = 1.2222222
            root.string = "abc"

            root.compB = JSONObject()
            root.compB?.compC = JSONObject()
            root.compB?.id = "b"
            root.compB?.compC?.id = "c"
            root.compB?.compC?.compD = JSONObject()
            root.compB?.compC?.compD?.id = "d-1"

            XCTAssertEqual(root.toSortedJSON(),
                           """
                           {"boolean":"true","double":1.2222222,"integer":111,"long":9999999,"nested":{"id":"b","nested":{"id":"c","nested":{"id":"d-1"}}},"string":"abc"}
                           """)

            _ = try? root.remove(member: \DocComponentA.string)
            _ = try? root.remove(member: \DocComponentA.integer)
            _ = try? root.remove(member: \DocComponentA.compB)

            XCTAssertEqual(root.toSortedJSON(),
                           """
                           {"boolean":"true","double":1.2222222,"long":9999999}
                           """)
        }
    }
}

class TestDocument<T: JSONSpec> {
    func update(_ callback: (_ root: JSONObject<T>) -> Void) {
        let root = JSONObject<T>(target: CRDTObject(createdAt: TimeTicket.initial), context: ChangeContext(id: ChangeID.initial, root: CRDTRoot()))
        callback(root)
    }
}

class DocComponentA: JSONSpec {
    var compB: JSONObject<DocComponentB>?
    var boolean: Bool?
    var integer: Int32?
    var long: Int64?
    var double: Double?
    var string: String?

    required init() {}

    static var keyMap: [AnyKeyPath: String] {
        [
            \DocComponentA.compB: "nested",
            \DocComponentA.boolean: "boolean",
            \DocComponentA.integer: "integer",
            \DocComponentA.long: "long",
            \DocComponentA.double: "double",
            \DocComponentA.string: "string"
        ]
    }
}

class DocComponentB: JSONSpec {
    var id: String?
    var compC: JSONObject<DocComponentC>?

    required init() {}

    static var keyMap: [AnyKeyPath: String] {
        [\DocComponentB.id: "id",
         \DocComponentB.compC: "nested"]
    }
}

class DocComponentC: JSONSpec {
    var id: String?
    var compD: JSONObject<DocComponentD>?

    required init() {}

    static var keyMap: [AnyKeyPath: String] {
        [\DocComponentC.id: "id",
         \DocComponentC.compD: "nested"]
    }
}

class DocComponentD: JSONSpec {
    var id: String?

    required init() {}

    static var keyMap: [AnyKeyPath: String] {
        [\DocComponentD.id: "id"]
    }
}
