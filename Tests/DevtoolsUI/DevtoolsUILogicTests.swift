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
@testable import YorkieDevtoolsUI

// MARK: - JSONNode.build Tests

final class JSONNodeBuildTests: XCTestCase {
    // MARK: Object nodes

    func test_build_object_produces_sorted_children_and_count_preview() throws {
        // given
        let input: [String: Any] = ["b": 2, "a": 1]

        // when
        let node = JSONNode.build(key: "x", value: input)

        // then
        XCTAssertEqual(node.key, "x")
        XCTAssertEqual(node.valuePreview, "{2}")
        let children = try XCTUnwrap(node.children)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].key, "a")
        XCTAssertEqual(children[0].valuePreview, "1")
        XCTAssertEqual(children[1].key, "b")
        XCTAssertEqual(children[1].valuePreview, "2")
    }

    func test_build_array_produces_indexed_children_and_bracket_preview() throws {
        // given
        let input: [Any] = [10, 20]

        // when
        let node = JSONNode.build(key: "arr", value: input)

        // then
        XCTAssertEqual(node.valuePreview, "[2]")
        let children = try XCTUnwrap(node.children)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].key, "[0]")
        XCTAssertEqual(children[1].key, "[1]")
    }

    // MARK: Scalar nodes

    func test_build_string_scalar_produces_quoted_preview_and_no_children() {
        // given / when
        let node = JSONNode.build(key: "s", value: "hi")

        // then
        XCTAssertEqual(node.valuePreview, "\"hi\"")
        XCTAssertNil(node.children)
    }

    func test_build_bool_true_produces_true_preview_and_no_children() {
        // given / when
        let node = JSONNode.build(key: "flag", value: true)

        // then
        XCTAssertEqual(node.valuePreview, "true")
        XCTAssertNil(node.children)
    }

    func test_build_bool_false_produces_false_preview_and_no_children() {
        // given / when
        let node = JSONNode.build(key: "flag", value: false)

        // then
        XCTAssertEqual(node.valuePreview, "false")
        XCTAssertNil(node.children)
    }

    func test_build_null_produces_null_preview_and_no_children() {
        // given / when
        let node = JSONNode.build(key: "n", value: NSNull())

        // then
        XCTAssertEqual(node.valuePreview, "null")
        XCTAssertNil(node.children)
    }

    // MARK: Empty containers

    func test_build_empty_object_produces_zero_preview_and_nil_children() {
        // given / when
        let node = JSONNode.build(key: "obj", value: [String: Any]())

        // then
        // valuePreview is "{0}" because the count is 0; children is nil (not empty array)
        XCTAssertEqual(node.valuePreview, "{0}")
        XCTAssertNil(node.children)
    }

    func test_build_empty_array_produces_zero_preview_and_nil_children() {
        // given / when
        let node = JSONNode.build(key: "arr", value: [Any]())

        // then
        // valuePreview is "[0]" because the count is 0; children is nil (not empty array)
        XCTAssertEqual(node.valuePreview, "[0]")
        XCTAssertNil(node.children)
    }

    // MARK: Nested containers

    func test_build_nested_object_in_array_produces_correct_tree() throws {
        // given
        let input: [String: Any] = ["list": [["n": 1] as [String: Any]] as [Any]]

        // when
        let root = JSONNode.build(key: "root", value: input)

        // then – root {1}
        XCTAssertEqual(root.key, "root")
        XCTAssertEqual(root.valuePreview, "{1}")

        let rootChildren = try XCTUnwrap(root.children)
        XCTAssertEqual(rootChildren.count, 1)

        // list [1]
        let listNode = rootChildren[0]
        XCTAssertEqual(listNode.key, "list")
        XCTAssertEqual(listNode.valuePreview, "[1]")

        let listChildren = try XCTUnwrap(listNode.children)
        XCTAssertEqual(listChildren.count, 1)

        // [0] {1}
        let elementNode = listChildren[0]
        XCTAssertEqual(elementNode.key, "[0]")
        XCTAssertEqual(elementNode.valuePreview, "{1}")

        let elementChildren = try XCTUnwrap(elementNode.children)
        XCTAssertEqual(elementChildren.count, 1)

        // n = 1
        let leafNode = elementChildren[0]
        XCTAssertEqual(leafNode.key, "n")
        XCTAssertEqual(leafNode.valuePreview, "1")
        XCTAssertNil(leafNode.children)
    }
}

// MARK: - JSONNode.parse Tests

final class JSONNodeParseTests: XCTestCase {
    func test_parse_flat_object_json_returns_sorted_top_level_nodes() throws {
        // given
        let json = "{\"a\":1,\"b\":{\"c\":2}}"

        // when
        let nodes = JSONNode.parse(sortedJSON: json)

        // then – two top-level nodes sorted alphabetically
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].key, "a")
        XCTAssertEqual(nodes[0].valuePreview, "1")
        XCTAssertNil(nodes[0].children)

        XCTAssertEqual(nodes[1].key, "b")
        XCTAssertEqual(nodes[1].valuePreview, "{1}")

        let bChildren = try XCTUnwrap(nodes[1].children)
        XCTAssertEqual(bChildren.count, 1)
        XCTAssertEqual(bChildren[0].key, "c")
        XCTAssertEqual(bChildren[0].valuePreview, "2")
    }

    func test_parse_json_integer_renders_as_number_not_bool() {
        // build uses CFBooleanGetTypeID() to distinguish real JSON booleans from
        // integers, so NSNumber(value:1) and NSNumber(value:0) coming out of
        // JSONSerialization must render as "1" and "0", not "true"/"false".

        // given
        let json1 = "{\"a\":1}"
        let json0 = "{\"a\":0}"

        // when
        let nodes1 = JSONNode.parse(sortedJSON: json1)
        let nodes0 = JSONNode.parse(sortedJSON: json0)

        // then
        XCTAssertEqual(nodes1.count, 1)
        XCTAssertEqual(nodes1[0].valuePreview, "1")

        XCTAssertEqual(nodes0.count, 1)
        XCTAssertEqual(nodes0[0].valuePreview, "0")
    }

    func test_parse_json_booleans_render_as_true_and_false() {
        // CFBooleanGetTypeID() correctly identifies real JSON true/false values
        // (kCFBooleanTrue / kCFBooleanFalse) so they still render as "true"/"false".

        // given
        let jsonTrue = "{\"flag\":true}"
        let jsonFalse = "{\"flag\":false}"

        // when
        let nodesTrue = JSONNode.parse(sortedJSON: jsonTrue)
        let nodesFalse = JSONNode.parse(sortedJSON: jsonFalse)

        // then
        XCTAssertEqual(nodesTrue.count, 1)
        XCTAssertEqual(nodesTrue[0].key, "flag")
        XCTAssertEqual(nodesTrue[0].valuePreview, "true")
        XCTAssertNil(nodesTrue[0].children)

        XCTAssertEqual(nodesFalse.count, 1)
        XCTAssertEqual(nodesFalse[0].key, "flag")
        XCTAssertEqual(nodesFalse[0].valuePreview, "false")
        XCTAssertNil(nodesFalse[0].children)
    }

    func test_parse_invalid_json_returns_empty_array() {
        // given
        let json = "not json"

        // when
        let nodes = JSONNode.parse(sortedJSON: json)

        // then
        XCTAssertTrue(nodes.isEmpty)
    }

    func test_parse_json_array_wraps_result_in_root_node() {
        // given
        let json = "[10,20,30]"

        // when
        let nodes = JSONNode.parse(sortedJSON: json)

        // then – non-object fragments become a single "root" node
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].key, "root")
        XCTAssertEqual(nodes[0].valuePreview, "[3]")
    }
}

// MARK: - DevtoolsTimelineEntry Tests

final class DevtoolsTimelineEntryTests: XCTestCase {
    // MARK: local-change

    func test_local_change_entry_has_push_direction_and_op_summary() {
        // given
        let operations: [[String: Any]] = [
            ["type": "set", "path": "$", "key": "x"],
            ["type": "add", "path": "$.list", "index": 0]
        ]
        let value: [String: Any] = [
            "message": "hello",
            "operations": operations,
            "actor": "a1",
            "clientSeq": 1,
            "serverSeq": "0"
        ]
        let json: [String: Any] = ["type": "local-change", "source": "local", "value": value]

        // when
        let entry = DevtoolsTimelineEntry(id: 1, json: json)

        // then
        XCTAssertEqual(entry.type, "local-change")
        XCTAssertEqual(entry.source, "local")
        XCTAssertEqual(entry.direction, .push)
        XCTAssertTrue(entry.summary.contains("set"), "summary should mention 'set' op type")
        XCTAssertTrue(entry.summary.contains("add"), "summary should mention 'add' op type")
        XCTAssertTrue(entry.summary.contains("hello"), "summary should contain the message")
    }

    // MARK: remote-change

    func test_remote_change_entry_has_pull_direction() {
        // given
        let value: [String: Any] = [
            "message": "",
            "operations": [[String: Any]](),
            "actor": "b1",
            "clientSeq": 0,
            "serverSeq": "1"
        ]
        let json: [String: Any] = ["type": "remote-change", "source": "remote", "value": value]

        // when
        let entry = DevtoolsTimelineEntry(id: 2, json: json)

        // then
        XCTAssertEqual(entry.direction, .pull)
    }

    // MARK: snapshot

    func test_snapshot_entry_has_pull_direction_and_serverSeq_in_summary() {
        // given
        let value: [String: Any] = [
            "serverSeq": "42",
            "snapshotVector": "",
            "snapshot": "..."
        ]
        let json: [String: Any] = ["type": "snapshot", "source": "remote", "value": value]

        // when
        let entry = DevtoolsTimelineEntry(id: 3, json: json)

        // then
        XCTAssertEqual(entry.direction, .pull)
        XCTAssertTrue(entry.summary.contains("42"), "summary should contain the serverSeq value")
    }

    // MARK: status-changed

    func test_status_changed_entry_has_neutral_direction_and_status_in_summary() {
        // given
        let value: [String: Any] = ["status": "attached", "actorID": "a1"]
        let json: [String: Any] = ["type": "status-changed", "source": "local", "value": value]

        // when
        let entry = DevtoolsTimelineEntry(id: 4, json: json)

        // then
        XCTAssertEqual(entry.direction, .neutral)
        XCTAssertTrue(entry.summary.contains("attached"))
    }

    // MARK: watched

    func test_watched_entry_has_neutral_direction() {
        // given
        let value: [String: Any] = ["clientID": "c1", "presence": [String: Any]()]
        let json: [String: Any] = ["type": "watched", "source": "remote", "value": value]

        // when
        let entry = DevtoolsTimelineEntry(id: 5, json: json)

        // then
        XCTAssertEqual(entry.direction, .neutral)
    }

    // MARK: prettyJSON round-trip

    func test_prettyJSON_is_non_empty_and_round_trips_back_to_original_type() throws {
        // given
        let json: [String: Any] = [
            "type": "snapshot",
            "source": "remote",
            "value": ["serverSeq": "1", "snapshotVector": "", "snapshot": ""]
        ]

        // when
        let entry = DevtoolsTimelineEntry(id: 6, json: json)

        // then
        XCTAssertFalse(entry.prettyJSON.isEmpty)
        let data = try XCTUnwrap(entry.prettyJSON.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(parsed["type"] as? String, entry.type)
    }

    // MARK: empty operations

    func test_change_entry_with_empty_operations_summary_equals_no_ops() {
        // given
        let value: [String: Any] = [
            "message": "",
            "operations": [[String: Any]](),
            "actor": "a1",
            "clientSeq": 1,
            "serverSeq": "1"
        ]
        let json: [String: Any] = ["type": "local-change", "source": "local", "value": value]

        // when
        let entry = DevtoolsTimelineEntry(id: 7, json: json)

        // then – summarize() returns "no ops" when operations is empty and message is empty
        XCTAssertEqual(entry.summary, "no ops")
    }

    // MARK: id propagation

    func test_entry_id_matches_the_provided_id() {
        // given
        let json: [String: Any] = ["type": "watched", "source": "remote", "value": [String: Any]()]

        // when
        let entry = DevtoolsTimelineEntry(id: 99, json: json)

        // then
        XCTAssertEqual(entry.id, 99)
    }

    // MARK: missing fields

    func test_entry_with_missing_type_uses_question_mark_fallback() {
        // given
        let json: [String: Any] = ["source": "local"]

        // when
        let entry = DevtoolsTimelineEntry(id: 0, json: json)

        // then
        XCTAssertEqual(entry.type, "?")
    }
}
