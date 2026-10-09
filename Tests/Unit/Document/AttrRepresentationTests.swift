/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
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
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

/// Ports: `packages/sdk/test/unit/document/attr_representation_test.ts` from
/// yorkie-js-sdk PR #1365 "Charge an attribute to live only while it is the
/// live value" (commit 190204f8).
///
/// The Go SDK's `Style` takes `map[string]string` and stores the value it is
/// given; this SDK JSON-encodes it. That split is yorkie-js-sdk#2003, and it
/// has two halves.
///
/// Reading: a Go-authored `color="red"` arrives here as the three characters
/// `red`, which is not a JSON document. Parsing it unguarded used to throw out
/// of applying a change BEFORE the checkpoint advanced, so the server
/// redelivered the same change forever and the document could never be
/// opened. Snapshot load did not throw -- the raw bytes go straight into the
/// RHT -- so a client could attach successfully and then die on first render.
///
/// Sizing: `RHTNode` charges `(len(key) + len(value)) * 2` in both SDKs, over
/// the LOGICAL value in UTF-8 bytes -- matching what the Go SDK stores and
/// charges, rather than the JSON-quoted form counted in UTF-16 units.

/// `styleRawOnTree` writes an attribute the way a Go peer does: value stored
/// raw, bypassing `stringifyAttrValue`.
@MainActor
private func styleRawOnTree(_ doc: Document, key: String, raw: String) throws {
    guard let tree = doc.getRootObject().get(key: "t") as? CRDTTree else {
        throw YorkieError(code: .errUnexpected, message: "tree not found")
    }
    guard let firstChild = tree.indexTree.root.innerChildren.first else {
        throw YorkieError(code: .errUnexpected, message: "no first child")
    }

    let ticket = doc.changeID.createTimeTicket(delimiter: 0)
    _ = firstChild.setAttrs([key: raw], ticket)
}

/// `styleRawOnText` writes an attribute the way a Go peer does: value stored
/// raw, on the first live, non-empty text node.
@MainActor
private func styleRawOnText(_ doc: Document, key: String, raw: String) throws {
    guard let text = doc.getRootObject().get(key: "k") as? CRDTText else {
        throw YorkieError(code: .errUnexpected, message: "text not found")
    }

    // swiftlint:disable:next empty_count
    for node in text.rgaTreeSplit where !node.isRemoved && node.value.count > 0 {
        let ticket = doc.changeID.createTimeTicket(delimiter: 0)
        node.value.setAttr(key: key, value: raw, updatedAt: ticket)
        return
    }

    throw YorkieError(code: .errUnexpected, message: "no live text node")
}

/// `sizeOfStyled` measures the live-data delta a single style edit books,
/// independent of the fixed cost of the seeded tree itself.
@MainActor
private func sizeOfStyled(_ attrs: [String: Any]) throws -> Int {
    let doc = Document(key: "test-doc")
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot: JSONTreeElementNode(
            type: "doc",
            children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abc")])
            ]
        ))
    }
    let before = doc.getDocSize().live.data
    try doc.update { root, _ in
        try (root.t as? JSONTree)?.styleByPath([0], [1], attrs)
    }
    return doc.getDocSize().live.data - before
}

/// `storedTreeAttrs` reaches past the public API to the raw bytes an
/// attribute is stored and transmitted as: the representation IS what this
/// describes, and every public reader parses it back.
@MainActor
private func storedTreeAttrs(_ attrs: [String: Any]) throws -> [String: String] {
    let doc = Document(key: "test-doc")
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot: JSONTreeElementNode(
            type: "doc",
            children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")])
            ]
        ))
        try (root.t as? JSONTree)?.styleByPath([0], [1], attrs)
    }

    guard let tree = doc.getRootObject().get(key: "t") as? CRDTTree,
          let firstChild = tree.indexTree.root.innerChildren.first
    else {
        XCTFail("tree not initialized")
        return [:]
    }

    var out = [String: String]()
    for node in firstChild.attrs ?? RHT() where !node.isRemoved {
        out[node.key] = node.value
    }
    return out
}

final class AttrRepresentationTests: XCTestCase {
    // MARK: - an attribute written by a peer that stores values raw

    @MainActor
    func test_does_not_throw_when_a_tree_carrying_it_is_read() throws {
        // given
        let doc = Document(key: "test-doc")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(
                type: "doc",
                children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")])
                ]
            ))
        }
        try styleRawOnTree(doc, key: "color", raw: "red")

        // when
        guard let tree = doc.getRootObject().get(key: "t") as? CRDTTree else {
            return XCTFail("tree not initialized")
        }

        // then
        XCTAssertEqual(tree.toXML(), "<doc><p color=\"red\">ab</p></doc>")
        // `toJSON`/`toSortedJSON` are non-throwing here; reaching this line
        // without a crash is the port of `assert.doesNotThrow`.
        _ = doc.toJSON()
        _ = doc.toSortedJSON()
    }

    @MainActor
    func test_does_not_throw_when_a_text_carrying_it_is_read() throws {
        // given
        let doc = Document(key: "test-doc")
        try doc.update { root, _ in
            root.k = JSONText()
            _ = (root.k as? JSONText)?.edit(0, 0, "abcdefghij")
        }
        try styleRawOnText(doc, key: "color", raw: "red")

        // when
        _ = doc.toJSON()
        let sorted = doc.toSortedJSON()

        // then
        XCTAssertTrue(sorted.contains("\"color\":\"red\""))
    }

    /// Mirrors JS: "cannot forge JSON structure through a text attribute".
    @MainActor
    func test_cannot_forge_json_structure_through_a_text_attribute() throws {
        // given
        let doc = Document(key: "test-doc")
        try doc.update { root, _ in
            root.k = JSONText()
            _ = (root.k as? JSONText)?.edit(0, 0, "abcdefghij")
        }

        // when
        try styleRawOnText(doc, key: "evil", raw: "[\"x\",\"y\"]")

        // then
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(doc.toJSON().utf8)) as? [String: Any])
        let first = try XCTUnwrap((parsed["k"] as? [[String: Any]])?.first)
        XCTAssertEqual((first["attrs"] as? [String: Any])?["evil"] as? [String], ["x", "y"])
    }

    /// Mirrors JS: "cannot break JSON parsing through an object-valued text attribute".
    @MainActor
    func test_cannot_break_json_parsing_through_an_object_valued_text_attribute() throws {
        // given
        let doc = Document(key: "test-doc")
        try doc.update { root, _ in
            root.k = JSONText()
            _ = (root.k as? JSONText)?.edit(0, 0, "abcdefghij")
        }

        // when
        try styleRawOnText(doc, key: "evil", raw: "{\"val\":\"forged\"}")

        // then
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(doc.toJSON().utf8)) as? [String: Any])
        let first = try XCTUnwrap((parsed["k"] as? [[String: Any]])?.first)
        XCTAssertEqual(((first["attrs"] as? [String: Any])?["evil"] as? [String: String]), ["val": "forged"])
        XCTAssertEqual(first["val"] as? String, "abcdefghij", "the real value is untouched")
    }

    /// Mirrors JS: "cannot forge XML structure through a tree attribute". `toXML`
    /// builds markup by concatenation, so a peer-written value holding `"` or `<`
    /// must be escaped rather than forge an attribute or element.
    @MainActor
    func test_cannot_forge_xml_structure_through_a_tree_attribute() throws {
        // given
        let doc = Document(key: "test-doc")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(
                type: "doc",
                children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")])
                ]
            ))
        }

        // when
        try styleRawOnTree(doc, key: "color", raw: "red\" onload=\"<script>")

        // then
        let tree = try XCTUnwrap(doc.getRootObject().get(key: "t") as? CRDTTree)
        XCTAssertEqual(tree.toXML(), "<doc><p color=\"red&quot; onload=&quot;&lt;script&gt;\">ab</p></doc>")
    }

    @MainActor
    func test_reads_back_as_the_string_the_peer_wrote_not_as_a_dropped_key() throws {
        // given
        let doc = Document(key: "test-doc")
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(
                type: "doc",
                children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")])
                ]
            ))
        }
        try styleRawOnTree(doc, key: "color", raw: "red")

        // when
        guard let tree = doc.getRootObject().get(key: "t") as? CRDTTree else {
            return XCTFail("tree not initialized")
        }

        // then
        XCTAssertTrue(tree.toXML().contains("color=\"red\""))
    }

    // MARK: - attribute sizing

    /// The numbers on the right are what the Go SDK charges for the same
    /// attribute: `(len(key) + len(value)) * 2` over UTF-8 bytes of the raw
    /// value. yorkie-js-sdk#2003 reports Go 16 and JS 20 for `bold="true"`;
    /// they now agree.
    @MainActor
    func test_charges_the_logical_value_in_utf8_bytes_matching_the_server() throws {
        // then
        XCTAssertEqual(try sizeOfStyled(["bold": "true"]), 16, "bold=true")
        XCTAssertEqual(try sizeOfStyled(["color": "red"]), 16, "color=red")
        // Non-ASCII is where the old UTF-16 count reversed the sign of the gap.
        XCTAssertEqual(try sizeOfStyled(["color": "빨강"]), 22, "color=빨강")
        // A non-string keeps its JSON form on the wire, which is what Go would
        // hold as a string, so both charge the same.
        XCTAssertEqual(try sizeOfStyled(["bold": true]), 16, "bold=true (boolean)")
        XCTAssertEqual(try sizeOfStyled(["size": 12]), 12, "size=12 (number)")
    }

    /// The typed attribute API has to keep working exactly as before.
    @MainActor
    func test_still_reads_typed_values_back_with_their_types() throws {
        // given
        let doc = Document(key: "test-doc")

        // when
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(
                type: "doc",
                children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abc")])
                ]
            ))
            try (root.t as? JSONTree)?.styleByPath([0], [1], ["bold": true, "size": 12, "name": "1"])
        }

        // then
        let json = doc.toSortedJSON()
        XCTAssertTrue(json.contains("\"bold\":true"), "boolean stays a boolean")
        XCTAssertTrue(json.contains("\"size\":12"), "number stays a number")
        XCTAssertTrue(json.contains("\"name\":\"1\""), "a string that looks like a number stays a string")
    }

    // MARK: - the attribute representation

    //
    // What yorkie-js-sdk#2003 closes, and the one case it cannot.
    //
    // The issue was filed against the server "because the question is which
    // representation is canonical". It is now the server's: a string is
    // stored as itself, so `color="red"` puts the same three bytes on the
    // wire from either SDK, and a Go peer reads back exactly what an
    // iOS/JS peer wrote.
    //
    // One case is irreducible without a type tag on the wire. A string that
    // is ITSELF a JSON document -- "1", "true", "null" -- keeps its quotes,
    // because stored raw it could not be told from the value it encodes and
    // would come back as a number or a boolean. Those still differ from what
    // Go would store, and Go cannot express the distinction at all.

    @MainActor
    func test_stores_an_ordinary_string_as_itself_as_the_server_does() throws {
        // when
        let stored = try storedTreeAttrs(["color": "red", "font": "Arial", "hex": "#fff"])

        // then
        XCTAssertEqual(stored["color"], "red")
        XCTAssertEqual(stored["font"], "Arial")
        XCTAssertEqual(stored["hex"], "#fff")
    }

    @MainActor
    func test_stores_every_non_string_as_the_server_would_hold_it() throws {
        // when
        let stored = try storedTreeAttrs(["bold": true, "size": 12, "ratio": 1.5])

        // then
        XCTAssertEqual(stored["bold"], "true")
        XCTAssertEqual(stored["size"], "12")
        XCTAssertEqual(stored["ratio"], "1.5")
    }

    /// THE REMAINING GAP. Pinned rather than fixed: closing it needs a
    /// value-kind field on the wire, which is a protocol change on both SDKs
    /// and the server and still leaves a default for every value already
    /// stored.
    @MainActor
    func test_keeps_the_quotes_on_a_string_that_is_itself_json_and_so_still_differs() throws {
        // when
        let stored = try storedTreeAttrs(["flag": "true", "count": "1", "blank": "null"])

        // then
        XCTAssertEqual(stored["flag"], "\"true\"", "the server would store `true`")
        XCTAssertEqual(stored["count"], "\"1\"", "the server would store `1`")
        XCTAssertEqual(stored["blank"], "\"null\"", "the server would store `null`")
    }

    @MainActor
    func test_round_trips_a_string_that_looks_like_a_non_string_which_is_why() throws {
        // given
        let doc = Document(key: "test-doc")

        // when
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(
                type: "doc",
                children: [
                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")])
                ]
            ))
            try (root.t as? JSONTree)?.styleByPath([0], [1], ["flag": "true", "count": "1"])
        }

        // then
        let json = doc.toSortedJSON()
        XCTAssertTrue(json.contains("\"flag\":\"true\""), "still a string")
        XCTAssertTrue(json.contains("\"count\":\"1\""), "still a string")
    }
}
