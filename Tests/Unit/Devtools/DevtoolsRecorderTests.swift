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

// MARK: - Helpers

/// Returns the value at `key` in `dict`, casting to `T`. Fails the current test if missing or wrong type.
private func field<T>(_ dict: [String: Any], _ key: String, file: StaticString = #file, line: UInt = #line) -> T? {
    guard let raw = dict[key] else {
        XCTFail("missing key '\(key)' in \(dict)", file: file, line: line)
        return nil
    }
    guard let typed = raw as? T else {
        XCTFail("key '\(key)': expected \(T.self), got \(type(of: raw)) (\(raw))", file: file, line: line)
        return nil
    }
    return typed
}

/// Builds a minimal ``ChangeInfo`` for use in event construction.
private func makeChangeInfo(
    message: String = "",
    operations: [any OperationInfo] = [],
    actorID: ActorID? = "aabbccddeeff001122334455",
    clientSeq: UInt32 = 1,
    serverSeq: String = "10"
) -> ChangeInfo {
    ChangeInfo(
        message: message,
        operations: operations,
        actorID: actorID,
        clientSeq: clientSeq,
        serverSeq: serverSeq
    )
}

// MARK: - DevtoolsRecorderTests

@MainActor
final class DevtoolsRecorderTests: XCTestCase {
    // MARK: DevtoolsEncoder — OperationInfo shapes

    func test_encode_add_op_info_produces_correct_shape() {
        // given
        let op = AddOpInfo(path: "$.list", index: 0)

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then
        XCTAssertEqual(result["type"] as? String, "add")
        XCTAssertEqual(result["path"] as? String, "$.list")
        XCTAssertEqual(result["index"] as? Int, 0)
    }

    func test_encode_move_op_info_produces_correct_shape() {
        // given
        let op = MoveOpInfo(path: "$.list", previousIndex: 1, index: 2)

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then
        XCTAssertEqual(result["type"] as? String, "move")
        XCTAssertEqual(result["path"] as? String, "$.list")
        XCTAssertEqual(result["previousIndex"] as? Int, 1)
        XCTAssertEqual(result["index"] as? Int, 2)
    }

    func test_encode_set_op_info_produces_correct_shape() {
        // given
        let op = SetOpInfo(path: "$.obj", key: "k")

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then
        XCTAssertEqual(result["type"] as? String, "set")
        XCTAssertEqual(result["path"] as? String, "$.obj")
        XCTAssertEqual(result["key"] as? String, "k")
    }

    func test_encode_array_set_op_info_produces_correct_shape() {
        // given
        let op = ArraySetOpInfo(path: "$.list")

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then
        XCTAssertEqual(result["type"] as? String, "array-set")
        XCTAssertEqual(result["path"] as? String, "$.list")
        XCTAssertNil(result["index"])
        XCTAssertNil(result["key"])
    }

    func test_encode_remove_op_info_with_key_omits_index() {
        // given
        let op = RemoveOpInfo(path: "$.obj", key: "k", index: nil)

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then
        XCTAssertEqual(result["type"] as? String, "remove")
        XCTAssertEqual(result["path"] as? String, "$.obj")
        XCTAssertEqual(result["key"] as? String, "k")
        XCTAssertNil(result["index"])
    }

    func test_encode_remove_op_info_with_index_omits_key() {
        // given
        let op = RemoveOpInfo(path: "$.list", key: nil, index: 3)

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then
        XCTAssertEqual(result["type"] as? String, "remove")
        XCTAssertEqual(result["path"] as? String, "$.list")
        XCTAssertNil(result["key"])
        XCTAssertEqual(result["index"] as? Int, 3)
    }

    func test_encode_increase_op_info_produces_correct_shape() {
        // given
        let op = IncreaseOpInfo(path: "$.counter", value: 5)

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then
        XCTAssertEqual(result["type"] as? String, "increase")
        XCTAssertEqual(result["path"] as? String, "$.counter")
        XCTAssertEqual(result["value"] as? Int, 5)
    }

    func test_encode_edit_op_info_nests_value_with_attributes_and_content() {
        // given
        let op = EditOpInfo(path: "$.text", from: 0, to: 2, attributes: ["bold": true], content: "hi")

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then
        XCTAssertEqual(result["type"] as? String, "edit")
        XCTAssertEqual(result["path"] as? String, "$.text")
        XCTAssertEqual(result["from"] as? Int, 0)
        XCTAssertEqual(result["to"] as? Int, 2)

        guard let value = result["value"] as? [String: Any] else {
            XCTFail("expected nested 'value' object")
            return
        }
        XCTAssertEqual(value["content"] as? String, "hi")

        guard let attrs = value["attributes"] as? [String: Any] else {
            XCTFail("expected 'attributes' in value")
            return
        }
        XCTAssertEqual(attrs["bold"] as? Bool, true)
    }

    func test_encode_edit_op_info_uses_empty_string_when_content_is_nil() {
        // given
        let op = EditOpInfo(path: "$.text", from: 0, to: 2, attributes: nil, content: nil)

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then
        guard let value = result["value"] as? [String: Any] else {
            XCTFail("expected nested 'value' object")
            return
        }
        XCTAssertEqual(value["content"] as? String, "")
    }

    func test_encode_edit_op_info_uses_empty_dict_when_attributes_are_nil() {
        // given
        let op = EditOpInfo(path: "$.text", from: 0, to: 2, attributes: nil, content: "x")

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then
        guard let value = result["value"] as? [String: Any] else {
            XCTFail("expected nested 'value' object")
            return
        }
        let attrs = value["attributes"] as? [String: Any]
        XCTAssertEqual(attrs?.isEmpty, true)
    }

    func test_encode_style_op_info_nests_value_with_attributes() {
        // given
        let op = StyleOpInfo(path: "$.text", from: 0, to: 2, attributes: ["b": "1"])

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then
        XCTAssertEqual(result["type"] as? String, "style")
        XCTAssertEqual(result["from"] as? Int, 0)
        XCTAssertEqual(result["to"] as? Int, 2)

        guard let value = result["value"] as? [String: Any] else {
            XCTFail("expected nested 'value' object")
            return
        }
        guard let attrs = value["attributes"] as? [String: Any] else {
            XCTFail("expected 'attributes' in value")
            return
        }
        XCTAssertEqual(attrs["b"] as? String, "1")
    }

    func test_encode_tree_edit_op_info_uses_kebab_case_type() {
        // given
        let op = TreeEditOpInfo(
            path: "$.tree",
            from: 0,
            to: 1,
            value: [],
            splitLevel: 0,
            fromPath: [0],
            toPath: [1]
        )

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then — type MUST be "tree-edit" (kebab-case), NOT "treeEdit"
        XCTAssertEqual(result["type"] as? String, "tree-edit")
        XCTAssertEqual(result["path"] as? String, "$.tree")
        XCTAssertEqual(result["from"] as? Int, 0)
        XCTAssertEqual(result["to"] as? Int, 1)
        XCTAssertEqual(result["fromPath"] as? [Int], [0])
        XCTAssertEqual(result["toPath"] as? [Int], [1])
        XCTAssertEqual(result["splitLevel"] as? Int, 0)
        XCTAssertNotNil(result["value"] as? [Any])
    }

    func test_encode_tree_style_op_info_uses_kebab_case_type_and_attributes_case() {
        // given
        let op = TreeStyleOpInfo(
            path: "$.tree",
            from: 0,
            to: 1,
            fromPath: [0],
            toPath: [1],
            value: .attributes(["bold": "true"])
        )

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then — type MUST be "tree-style" (kebab-case)
        XCTAssertEqual(result["type"] as? String, "tree-style")

        guard let value = result["value"] as? [String: Any] else {
            XCTFail("expected nested 'value' object")
            return
        }
        let attrs = value["attributes"] as? [String: Any]
        XCTAssertNotNil(attrs)
        XCTAssertEqual(attrs?["bold"] as? String, "true")
        XCTAssertNil(value["attributesToRemove"])
    }

    func test_encode_tree_style_op_info_attributes_to_remove_case() {
        // given
        let op = TreeStyleOpInfo(
            path: "$.tree",
            from: 0,
            to: 1,
            fromPath: [0],
            toPath: [1],
            value: .attributesToRemove(["bold", "italic"])
        )

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then
        guard let value = result["value"] as? [String: Any] else {
            XCTFail("expected nested 'value' object")
            return
        }
        let toRemove = value["attributesToRemove"] as? [String]
        XCTAssertEqual(toRemove, ["bold", "italic"])
        XCTAssertNil(value["attributes"])
    }

    func test_encode_tree_style_op_info_nil_case_produces_empty_value() {
        // given
        let op = TreeStyleOpInfo(
            path: "$.tree",
            from: 0,
            to: 1,
            fromPath: [0],
            toPath: [1],
            value: nil
        )

        // when
        let result = DevtoolsEncoder.encode(operationInfo: op)

        // then
        guard let value = result["value"] as? [String: Any] else {
            XCTFail("expected nested 'value' object")
            return
        }
        XCTAssertTrue(value.isEmpty)
    }

    // MARK: DevtoolsEncoder — sanitize

    func test_sanitize_passes_through_primitive_types() {
        // given
        let dict: [String: Any] = [
            "str": "hello",
            "bool": true,
            "num": NSNumber(value: 42)
        ]

        // when
        let result = DevtoolsEncoder.sanitize(dict)

        // then
        XCTAssertEqual(result["str"] as? String, "hello")
        XCTAssertEqual(result["bool"] as? Bool, true)
        XCTAssertEqual(result["num"] as? Int, 42)
    }

    func test_sanitize_recursively_handles_nested_dict() {
        // given
        let dict: [String: Any] = ["outer": ["inner": "value"]]

        // when
        let result = DevtoolsEncoder.sanitize(dict)

        // then
        let inner = result["outer"] as? [String: Any]
        XCTAssertEqual(inner?["inner"] as? String, "value")
    }

    func test_sanitize_stringifies_unknown_types() {
        // given
        struct Weird: CustomStringConvertible {
            var description: String {
                "weird-value"
            }
        }
        let dict: [String: Any] = ["weird": Weird()]

        // when
        let result = DevtoolsEncoder.sanitize(dict)

        // then — unknown type is stringified
        XCTAssertEqual(result["weird"] as? String, "weird-value")
    }

    // MARK: DevtoolsEncoder — DocEvent encoding

    func test_encode_local_change_event_has_correct_type_and_source() {
        // given
        let info = makeChangeInfo(message: "test", operations: [], actorID: "aabbccddeeff001122334455", clientSeq: 3, serverSeq: "7")
        let event = LocalChangeEvent(value: info)

        // when
        let result = DevtoolsEncoder.encode(event: event)

        // then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["type"] as? String, "local-change")
        XCTAssertEqual(result?["source"] as? String, "local")

        guard let value = result?["value"] as? [String: Any] else {
            XCTFail("expected 'value' dict")
            return
        }
        XCTAssertEqual(value["message"] as? String, "test")
        XCTAssertEqual(value["actor"] as? String, "aabbccddeeff001122334455")
        XCTAssertEqual(value["clientSeq"] as? Int, 3)
        XCTAssertEqual(value["serverSeq"] as? String, "7")
    }

    func test_encode_local_change_event_uses_actor_not_actorID_field() {
        // given — JS format uses "actor", not "actorID"
        let info = makeChangeInfo(actorID: "cafebabe00000000cafebabe")
        let event = LocalChangeEvent(value: info)

        // when
        let result = DevtoolsEncoder.encode(event: event)

        // then
        let value = result?["value"] as? [String: Any]
        XCTAssertNotNil(value?["actor"], "field must be 'actor', not 'actorID'")
        XCTAssertNil(value?["actorID"], "'actorID' must not appear in change info (JS contract uses 'actor')")
    }

    func test_encode_local_change_event_actor_is_empty_string_when_actorID_nil() {
        // given
        let info = makeChangeInfo(actorID: nil)
        let event = LocalChangeEvent(value: info)

        // when
        let result = DevtoolsEncoder.encode(event: event)

        // then
        let value = result?["value"] as? [String: Any]
        XCTAssertEqual(value?["actor"] as? String, "")
    }

    func test_encode_remote_change_event_has_correct_type_and_source() {
        // given
        let info = makeChangeInfo()
        let event = RemoteChangeEvent(value: info)

        // when
        let result = DevtoolsEncoder.encode(event: event)

        // then
        XCTAssertEqual(result?["type"] as? String, "remote-change")
        XCTAssertEqual(result?["source"] as? String, "remote")
    }

    func test_encode_snapshot_event_has_source_remote_and_server_seq_as_string() {
        // given
        let info = SnapshotInfo(serverSeq: 42, snapshot: nil, snapshotVector: "vv1")
        let event = SnapshotEvent(value: info)

        // when
        let result = DevtoolsEncoder.encode(event: event)

        // then
        XCTAssertEqual(result?["type"] as? String, "snapshot")
        XCTAssertEqual(result?["source"] as? String, "remote")

        guard let value = result?["value"] as? [String: Any] else {
            XCTFail("expected 'value' dict")
            return
        }
        // serverSeq MUST be a String, not an integer
        XCTAssertEqual(value["serverSeq"] as? String, "42")
        XCTAssertEqual(value["snapshotVector"] as? String, "vv1")
        XCTAssertNil(value["snapshot"])
    }

    func test_encode_snapshot_event_includes_base64_snapshot_when_present() {
        // given
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let info = SnapshotInfo(serverSeq: 1, snapshot: bytes, snapshotVector: "vv2")
        let event = SnapshotEvent(value: info)

        // when
        let result = DevtoolsEncoder.encode(event: event)

        // then
        guard let value = result?["value"] as? [String: Any] else {
            XCTFail("expected 'value' dict")
            return
        }
        XCTAssertEqual(value["snapshot"] as? String, bytes.base64EncodedString())
    }

    func test_encode_status_changed_event_includes_actor_id_when_present() {
        // given
        let info = StatusInfo(status: .attached, actorID: "aabbccddeeff001122334455")
        let event = StatusChangedEvent(source: .local, value: info)

        // when
        let result = DevtoolsEncoder.encode(event: event)

        // then
        XCTAssertEqual(result?["type"] as? String, "status-changed")

        guard let value = result?["value"] as? [String: Any] else {
            XCTFail("expected 'value' dict")
            return
        }
        XCTAssertEqual(value["status"] as? String, "attached")
        XCTAssertEqual(value["actorID"] as? String, "aabbccddeeff001122334455")
    }

    func test_encode_status_changed_event_omits_actor_id_when_nil() {
        // given
        let info = StatusInfo(status: .detached, actorID: nil)
        let event = StatusChangedEvent(source: .local, value: info)

        // when
        let result = DevtoolsEncoder.encode(event: event)

        // then
        guard let value = result?["value"] as? [String: Any] else {
            XCTFail("expected 'value' dict")
            return
        }
        XCTAssertNil(value["actorID"])
    }

    func test_encode_initialized_event_has_source_local_and_array_value() {
        // given
        let peers: [PeerElement] = [("client-1", ["cursor": "pos1"])]
        let event = InitializedEvent(value: peers)

        // when
        let result = DevtoolsEncoder.encode(event: event)

        // then
        XCTAssertEqual(result?["type"] as? String, "initialized")
        XCTAssertEqual(result?["source"] as? String, "local")

        guard let value = result?["value"] as? [[String: Any]] else {
            XCTFail("expected 'value' as array of dicts")
            return
        }
        XCTAssertEqual(value.count, 1)
        XCTAssertEqual(value[0]["clientID"] as? String, "client-1")
    }

    func test_encode_watched_event_has_source_remote() {
        // given
        let peer: PeerElement = ("client-2", [:])
        let event = WatchedEvent(value: peer)

        // when
        let result = DevtoolsEncoder.encode(event: event)

        // then
        XCTAssertEqual(result?["type"] as? String, "watched")
        XCTAssertEqual(result?["source"] as? String, "remote")

        guard let value = result?["value"] as? [String: Any] else {
            XCTFail("expected 'value' dict")
            return
        }
        XCTAssertEqual(value["clientID"] as? String, "client-2")
    }

    func test_encode_unwatched_event_has_source_remote() {
        // given
        let peer: PeerElement = ("client-3", [:])
        let event = UnwatchedEvent(value: peer)

        // when
        let result = DevtoolsEncoder.encode(event: event)

        // then
        XCTAssertEqual(result?["type"] as? String, "unwatched")
        XCTAssertEqual(result?["source"] as? String, "remote")
    }

    func test_encode_presence_changed_event_has_source_remote() {
        // given
        let peer: PeerElement = ("client-4", ["x": "1"])
        let event = PresenceChangedEvent(value: peer)

        // when
        let result = DevtoolsEncoder.encode(event: event)

        // then
        XCTAssertEqual(result?["type"] as? String, "presence-changed")
        XCTAssertEqual(result?["source"] as? String, "remote")
    }

    func test_encode_connection_and_sync_events_as_ios_only() {
        // given
        let connectionEvent = ConnectionChangedEvent(value: .connected)
        let syncEvent = SyncStatusChangedEvent(value: .synced)

        // when
        let connection = DevtoolsEncoder.encode(event: connectionEvent)
        let sync = DevtoolsEncoder.encode(event: syncEvent)

        // then — diagnostic events are captured and tagged iosOnly
        XCTAssertEqual(connection?["type"] as? String, "connection-changed")
        XCTAssertEqual(connection?["value"] as? String, "connected")
        XCTAssertEqual(connection?["iosOnly"] as? Bool, true)
        XCTAssertEqual(sync?["type"] as? String, "sync-status-changed")
        XCTAssertEqual(sync?["value"] as? String, "synced")
        XCTAssertEqual(sync?["iosOnly"] as? Bool, true)
    }

    func test_encode_auth_and_epoch_events_return_nil() {
        // given
        let authEvent = AuthErrorEvent(value: AuthErrorValue(reason: "forbidden", method: .pushPull))
        let epochEvent = EpochMismatchEvent(value: EpochMismatchValue(method: "PushPull"))

        // when / then
        XCTAssertNil(DevtoolsEncoder.encode(event: authEvent))
        XCTAssertNil(DevtoolsEncoder.encode(event: epochEvent))
    }

    // MARK: DevtoolsRecorder — ring buffer behaviour

    func test_record_captures_diagnostics_but_ignores_auth_and_epoch() {
        // given
        let recorder = DevtoolsRecorder(docKey: "doc-1", maxEvents: 10)

        // when
        recorder.record(ConnectionChangedEvent(value: .connected))
        recorder.record(SyncStatusChangedEvent(value: .synced))
        recorder.record(AuthErrorEvent(value: AuthErrorValue(reason: "401", method: .watch)))
        recorder.record(EpochMismatchEvent(value: EpochMismatchValue(method: "PushPull")))

        // then — connection + sync are captured; auth + epoch are ignored
        XCTAssertEqual(recorder.count, 2)
    }

    func test_record_counts_replayable_events() {
        // given
        let recorder = DevtoolsRecorder(docKey: "doc-2", maxEvents: 10)

        // when
        recorder.record(LocalChangeEvent(value: makeChangeInfo(message: "a")))
        recorder.record(LocalChangeEvent(value: makeChangeInfo(message: "b")))
        recorder.record(RemoteChangeEvent(value: makeChangeInfo(message: "c")))

        // then
        XCTAssertEqual(recorder.count, 3)
    }

    func test_ring_buffer_drops_oldest_events_when_over_capacity() {
        // given
        let recorder = DevtoolsRecorder(docKey: "doc-3", maxEvents: 3)

        // when — record 5 events with distinguishable messages
        for index in 1 ... 5 {
            recorder.record(LocalChangeEvent(value: makeChangeInfo(message: "msg-\(index)")))
        }

        // then — buffer holds only the last 3
        XCTAssertEqual(recorder.count, 3)

        let batches = recorder.dump()
        let messages = batches.compactMap { batch -> String? in
            guard let encoded = batch.first,
                  let value = encoded["value"] as? [String: Any]
            else { return nil }
            return value["message"] as? String
        }
        XCTAssertEqual(messages, ["msg-3", "msg-4", "msg-5"])
    }

    func test_clear_resets_the_buffer() {
        // given
        let recorder = DevtoolsRecorder(docKey: "doc-4", maxEvents: 10)
        recorder.record(LocalChangeEvent(value: makeChangeInfo()))

        // when
        recorder.clear()

        // then
        XCTAssertEqual(recorder.count, 0)
        XCTAssertTrue(recorder.dump().isEmpty)
    }

    // MARK: DevtoolsRecorder — dump shape

    func test_dump_wraps_each_event_as_single_element_batch() {
        // given
        let recorder = DevtoolsRecorder(docKey: "doc-5", maxEvents: 10)
        recorder.record(LocalChangeEvent(value: makeChangeInfo(message: "x")))
        recorder.record(RemoteChangeEvent(value: makeChangeInfo(message: "y")))

        // when
        let batches = recorder.dump()

        // then — 2 batches, each containing exactly 1 event
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].count, 1)
        XCTAssertEqual(batches[1].count, 1)
    }

    func test_dump_full_sync_message_has_correct_envelope_shape() {
        // given
        let recorder = DevtoolsRecorder(docKey: "my-doc", maxEvents: 10)
        recorder.record(LocalChangeEvent(value: makeChangeInfo()))

        // when
        let message = recorder.dumpFullSyncMessage()

        // then
        XCTAssertEqual(message["source"] as? String, DevtoolsEventSource.sdk)
        XCTAssertEqual(message["msg"] as? String, DevtoolsMessageType.fullSync.rawValue)
        XCTAssertEqual(message["docKey"] as? String, "my-doc")
        XCTAssertNotNil(message["events"])
    }

    // MARK: DevtoolsRecorder — exportJSON

    func test_export_json_returns_valid_json_array() throws {
        // given
        let recorder = DevtoolsRecorder(docKey: "doc-6", maxEvents: 10)
        recorder.record(LocalChangeEvent(value: makeChangeInfo(message: "hello")))
        recorder.record(RemoteChangeEvent(value: makeChangeInfo(message: "world")))

        // when
        let data = recorder.exportJSON(pretty: false)

        // then
        XCTAssertNotNil(data)
        let unwrappedData = try XCTUnwrap(data)
        let parsed = try? JSONSerialization.jsonObject(with: unwrappedData, options: [])
        XCTAssertNotNil(parsed as? [[[String: Any]]])
    }

    func test_export_json_returns_nil_when_buffer_is_empty_but_still_valid_array() {
        // given
        let recorder = DevtoolsRecorder(docKey: "doc-7", maxEvents: 10)

        // when
        let data = recorder.exportJSON(pretty: false)

        // then — empty buffer → `[]` is valid JSON
        XCTAssertNotNil(data)
        if let data {
            let parsed = try? JSONSerialization.jsonObject(with: data)
            let array = parsed as? [Any]
            XCTAssertEqual(array?.isEmpty, true)
        }
    }

    // MARK: Document integration — isEnableDevtools flag

    func test_document_devtools_disabled_by_default() async {
        // given
        let doc = Document(key: "d1")

        // when / then
        let enabled = await doc.isEnableDevtools()
        XCTAssertFalse(enabled)
    }

    func test_document_with_devtools_disabled_option_reports_false() async {
        // given
        let doc = Document(key: "d2", opts: DocumentOptions(disableGC: false, enableDevtools: false))

        // when / then
        let enabled = await doc.isEnableDevtools()
        XCTAssertFalse(enabled)
    }

    func test_document_with_devtools_enabled_option_reports_true() async {
        // given
        let doc = Document(key: "d3", opts: DocumentOptions(disableGC: false, enableDevtools: true))

        // when / then
        let enabled = await doc.isEnableDevtools()
        XCTAssertTrue(enabled)
    }

    func test_document_dump_devtools_returns_nil_when_disabled() async throws {
        // given
        let doc = Document(key: "d4", opts: DocumentOptions(disableGC: false, enableDevtools: false))
        try await doc.update { root, _ in
            root.key = "value"
        }

        // when
        let data = await doc.dumpDevtools()

        // then — disabled → recorder never created → nil
        XCTAssertNil(data)
    }

    func test_document_dump_devtools_returns_nil_before_any_event_when_enabled() async {
        // given — recorder is created lazily on first published event
        let doc = Document(key: "d5", opts: DocumentOptions(disableGC: false, enableDevtools: true))

        // when — no events published yet
        let data = await doc.dumpDevtools()

        // then — recorder not yet created → nil
        XCTAssertNil(data)
    }

    func test_document_with_enableDevtools_records_local_change_and_dumps_valid_json() async throws {
        // given
        let doc = Document(key: "d6", opts: DocumentOptions(disableGC: false, enableDevtools: true))

        // when — call update to produce a LocalChangeEvent via Document.publish
        try await doc.update { root, _ in
            root.title = "hello"
        }

        // then
        let data = await doc.dumpDevtools()
        XCTAssertNotNil(data, "dumpDevtools() must return non-nil after a local change")

        if let data {
            let parsed = try? JSONSerialization.jsonObject(with: data)
            XCTAssertNotNil(parsed as? [Any], "dumpDevtools() must return a valid JSON array")
        }
    }

    func test_document_devtools_dump_contains_correct_event_type_after_update() async throws {
        // given
        let doc = Document(key: "d7", opts: DocumentOptions(disableGC: false, enableDevtools: true))

        // when
        try await doc.update { root, _ in
            root.x = Int64(1)
        }

        // then — inspect via the recorder directly
        let recorder = await doc.devtoolsRecorder
        XCTAssertNotNil(recorder)
        XCTAssertEqual(recorder?.count, 1)

        let batches = recorder?.dump() ?? []
        XCTAssertEqual(batches.count, 1)

        let encoded = batches[0][0]
        XCTAssertEqual(encoded["type"] as? String, "local-change")
        XCTAssertEqual(encoded["source"] as? String, "local")
    }
}
