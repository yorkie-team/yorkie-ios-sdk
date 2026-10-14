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

/// Ports yorkie-js-sdk#1477 `presence_patch_test.ts`: presence is sent as a patch while the server
/// advertises `presence-patch` and holds a base, and as a full put otherwise.
///
/// Not ported, because this SDK has no counterpart for what they exercise:
/// - "puts when an update removes a presence key" and "puts when an undo removes the key it
///   introduced": ``Presence`` can only add or overwrite a key (`set` has no way to delete one) and
///   there is no presence undo, so no update removes a key and the JS `removesKey` fallback has
///   nothing to guard.
///
/// Persistence writes a pending patch as the put it stands for (a deliberate divergence from JS, see
/// `Converter.toPersistedChange`) and records that it was minted as a patch, so "heals a restored
/// patch the server stored as empty" is ported against a restored put that still owes the heal.
final class PresencePatchTests: XCTestCase {
    private let actor = "000000000000000000000001"

    private enum Kind: Equatable {
        case put, patch, clear, none
    }

    @MainActor
    private func makeDoc() -> Document {
        let doc = Document(key: "presence-patch-test")
        doc.setActor(self.actor)
        return doc
    }

    private func kind(of change: PresenceChange?) -> Kind {
        switch change {
        case .put: return .put
        case .patch: return .patch
        case .clear: return .clear
        case nil: return .none
        }
    }

    /// The presence-change kind of every change the document still has to push.
    @MainActor
    private func pendingKinds(_ doc: Document) -> [Kind] {
        doc.createChangePack().getChanges().map { self.kind(of: $0.presenceChange) }
    }

    /// Hands the document a server pack that acknowledges everything pushed so far, advertising the
    /// given capabilities.
    @MainActor
    private func ack(_ doc: Document, _ capabilities: [String]) throws {
        let pack = doc.createChangePack()
        let lastSeq = pack.getChanges().last?.id.getClientSeq() ?? 0
        try doc.applyChangePack(ChangePack(key: pack.getDocumentKey(),
                                           checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                                           isRemoved: false,
                                           changes: [],
                                           versionVector: nil,
                                           capabilities: capabilities))
    }

    @MainActor
    private func presence(of change: Change) -> StringValueTypeDictionary? {
        switch change.presenceChange {
        case .put(let presence): return presence
        case .patch(let presence, _): return presence
        default: return nil
        }
    }

    @MainActor
    private func full(of change: Change) -> StringValueTypeDictionary? {
        if case .patch(_, let full) = change.presenceChange {
            return full
        }
        return nil
    }

    // MARK: Recording

    @MainActor
    func test_sends_a_full_put_until_the_server_advertises_the_capability() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["cursor": 0]) }
        XCTAssertEqual(self.pendingKinds(doc), [.put])

        // A reply without the capability keeps it on puts.
        try self.ack(doc, [])
        try doc.update { _, presence in presence.set(["cursor": 1]) }
        XCTAssertEqual(self.pendingKinds(doc), [.put])
    }

    @MainActor
    func test_patches_once_the_capability_and_a_base_are_both_there() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a", "cursor": 0]) }
        try self.ack(doc, [presencePatchCapability])

        try doc.update { _, presence in presence.set(["cursor": 1]) }
        let change = try XCTUnwrap(doc.createChangePack().getChanges().first)
        XCTAssertEqual(self.kind(of: change.presenceChange), .patch)
        XCTAssertEqual(self.presence(of: change), ["cursor": "1"])

        // The patch still carries the whole presence locally, so the document the change applies to is
        // not left holding the changed key alone.
        XCTAssertEqual(self.full(of: change), ["name": "\"a\"", "cursor": "1"])
        XCTAssertEqual(doc.getMyEncodedPresence(), ["name": "\"a\"", "cursor": "1"])

        // Only the changed key goes on the wire, and no removed keys.
        let pbChange = try XCTUnwrap(Converter.toChangePack(pack: doc.createChangePack()).changes.first)
        XCTAssertEqual(pbChange.presenceChange.type, .patch)
        XCTAssertEqual(Array(pbChange.presenceChange.presence.data.keys), ["cursor"])
        XCTAssertTrue(pbChange.presenceChange.removedKeys.isEmpty)
    }

    @MainActor
    func test_accumulates_the_keys_of_several_sets_in_one_update() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])

        try doc.update { _, presence in
            presence.set(["cursor": 1])
            presence.set(["selection": ["id-1"]])
        }

        let change = try XCTUnwrap(doc.createChangePack().getChanges().first)
        XCTAssertEqual(self.kind(of: change.presenceChange), .patch)
        XCTAssertEqual(Set(self.presence(of: change)?.keys ?? [:].keys), ["cursor", "selection"])
    }

    @MainActor
    func test_keeps_a_key_that_fails_to_encode_out_of_the_patch() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])

        // NaN has no JSON encoding, so the key is dropped and must not enter the patch.
        try doc.update { _, presence in presence.set(["bad": Double.nan, "cursor": 1]) }

        let change = try XCTUnwrap(doc.createChangePack().getChanges().first)
        XCTAssertEqual(self.kind(of: change.presenceChange), .patch)
        XCTAssertEqual(Set(self.presence(of: change)?.keys ?? [:].keys), ["cursor"])
        XCTAssertNil(self.full(of: change)?["bad"])
    }

    @MainActor
    func test_puts_again_after_a_clear_which_leaves_the_server_no_base() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        XCTAssertTrue(doc.canPatchPresence())

        try doc.update { _, presence in presence.clear() }
        XCTAssertFalse(doc.canPatchPresence())

        try doc.update { _, presence in presence.set(["name": "b"]) }
        XCTAssertEqual(self.pendingKinds(doc), [.clear, .put])
    }

    @MainActor
    func test_puts_for_the_rest_of_an_update_that_clears() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])

        // The context carries one presence change, so a patch after a clear would replace it and the
        // server has no base to fold that patch into.
        try doc.update { _, presence in
            presence.clear()
            presence.set(["name": "b"])
        }
        XCTAssertEqual(self.pendingKinds(doc), [.put])
    }

    @MainActor
    func test_puts_a_presence_too_large_for_the_server_to_cache() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])

        // 4 KiB is the server's base limit, counting 64 B per key on top of the key and value bytes.
        try doc.update { _, presence in presence.set(["selection": ["id-\(String(repeating: "x", count: 5000))"]]) }
        XCTAssertEqual(self.pendingKinds(doc), [.put])
    }

    func test_measures_the_cacheable_presence_the_way_the_server_does() {
        // key (1) + encoded value + 64 == 4096 is the last size that is cached.
        let atLimit = ["k": String(repeating: "x", count: 4096 - 64 - 1)]
        let overLimit = ["k": String(repeating: "x", count: 4096 - 64 - 1 + 1)]
        XCTAssertTrue(Presence.isCacheable(atLimit))
        XCTAssertFalse(Presence.isCacheable(overLimit))

        // Bytes, not characters: "é" is two UTF-8 bytes, in the key and in the value alike.
        XCTAssertTrue(Presence.isCacheable(["é": String(repeating: "x", count: 4096 - 64 - 2)]))
        XCTAssertFalse(Presence.isCacheable(["é": String(repeating: "é", count: 2030)]))

        // Every key pays the overhead.
        XCTAssertTrue(Presence.isCacheable(Dictionary(uniqueKeysWithValues: (0 ..< 40).map { ("k\($0)", "1") })))
        XCTAssertFalse(Presence.isCacheable(Dictionary(uniqueKeysWithValues: (0 ..< 80).map { ("k\($0)", "1") })))
    }

    // MARK: Healing

    @MainActor
    func test_heals_with_a_put_when_a_reply_drops_the_capability() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        try doc.update { _, presence in presence.set(["cursor": 1]) }
        XCTAssertEqual(self.pendingKinds(doc), [.patch])

        // The push landed on an old server, which stored the patch as an empty presence. Its reply
        // advertises nothing, so a full put has to follow.
        try self.ack(doc, [])
        XCTAssertEqual(self.pendingKinds(doc), [.put])
        let healed = try XCTUnwrap(doc.createChangePack().getChanges().first)
        XCTAssertEqual(self.presence(of: healed), ["name": "\"a\"", "cursor": "1"])
    }

    @MainActor
    func test_does_not_heal_when_no_patch_was_outstanding() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])

        // Only puts were sent, so a reply that drops the capability leaves nothing to heal.
        try self.ack(doc, [])
        XCTAssertEqual(self.pendingKinds(doc), [])
    }

    @MainActor
    func test_heals_on_a_push_ack_whose_remote_state_is_dropped() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        try doc.update { _, presence in presence.set(["cursor": 1]) }
        XCTAssertEqual(self.pendingKinds(doc), [.patch])

        // PushOnly/SyncOff take only the push ack from the reply. The capability is metadata about
        // the server that took the push, not the remote state being skipped, so the heal must happen
        // on this path too.
        let pack = doc.createChangePack()
        let lastSeq = try XCTUnwrap(pack.getChanges().last).id.getClientSeq()
        doc.acknowledgePushedChanges(ChangePack(key: pack.getDocumentKey(),
                                                checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                                                isRemoved: false,
                                                changes: [],
                                                versionVector: nil))
        XCTAssertEqual(self.pendingKinds(doc), [.put])
    }

    @MainActor
    func test_drops_the_heal_while_minting_is_suspended() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        try doc.update { _, presence in presence.set(["cursor": 1]) }

        // Inside the re-anchor window an update would refuse, and the heal must not throw out of the
        // pack it runs in.
        _ = doc.discardLocalChanges()
        XCTAssertFalse(doc.isMintable)
        XCTAssertNoThrow(try self.ack(doc, []))
        XCTAssertEqual(self.pendingKinds(doc), [])
    }

    // MARK: Base unavailable

    @MainActor
    func test_rewrites_the_earliest_pending_patch_into_a_put_on_a_lost_base() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        try doc.update { _, presence in presence.set(["cursor": 1]) }
        try doc.update { _, presence in presence.set(["selection": ["id-1"]]) }
        XCTAssertEqual(self.pendingKinds(doc), [.patch, .patch])

        doc.restorePresencePatches()

        // Only the first one is rewritten: the server folds the rest in order, so the put in front of
        // them is the base they need.
        XCTAssertEqual(self.pendingKinds(doc), [.put, .patch])
        let first = try XCTUnwrap(doc.createChangePack().getChanges().first)
        XCTAssertEqual(self.presence(of: first), ["name": "\"a\"", "cursor": "1"])
    }

    @MainActor
    func test_still_owes_a_heal_while_later_patches_stay_queued() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        try doc.update { _, presence in presence.set(["cursor": 1]) }
        try doc.update { _, presence in presence.set(["selection": ["id-1"]]) }

        doc.restorePresencePatches()
        XCTAssertEqual(self.pendingKinds(doc), [.put, .patch])

        // The second patch is still on its way to a server that may not take one, so a reply without
        // the capability has to heal rather than conclude that the rewrite already left a put behind.
        try self.ack(doc, [])
        XCTAssertEqual(self.pendingKinds(doc), [.put])
        let healed = try XCTUnwrap(doc.createChangePack().getChanges().first)
        XCTAssertEqual(self.presence(of: healed), ["name": "\"a\"", "cursor": "1", "selection": "[\"id-1\"]"])
    }

    @MainActor
    func test_drops_the_base_when_the_server_lost_it() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        XCTAssertTrue(doc.canPatchPresence())

        // No pending patch to rewrite, but the base is gone all the same.
        doc.restorePresencePatches()
        XCTAssertFalse(doc.canPatchPresence())

        try doc.update { _, presence in presence.set(["cursor": 1]) }
        XCTAssertEqual(self.pendingKinds(doc), [.put])
    }

    // MARK: Restore

    @MainActor
    func test_owes_a_put_again_after_restoring_from_offline_persistence() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        XCTAssertTrue(doc.canPatchPresence())

        let restored = try Document.fromBytes(key: doc.getKey(), bytes: doc.toBytes())
        XCTAssertFalse(restored.canPatchPresence())

        try restored.update { _, presence in presence.set(["cursor": 1]) }
        XCTAssertEqual(self.pendingKinds(restored), [.put])
    }

    @MainActor
    func test_owes_a_put_again_after_an_in_place_restore() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        let bytes = try doc.toBytes()

        let target = self.makeDoc()
        try target.restoreFromBytes(bytes)
        XCTAssertFalse(target.canPatchPresence())

        try target.update { _, presence in presence.set(["cursor": 1]) }
        XCTAssertEqual(self.pendingKinds(target), [.put])
    }

    @MainActor
    func test_leaves_every_flag_down_after_a_reanchor() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        try doc.update { _, presence in presence.set(["cursor": 1]) }
        XCTAssertTrue(doc.presenceBase.patchable)
        XCTAssertTrue(doc.presenceBase.baseSent)
        XCTAssertTrue(doc.presenceBase.patchSent)

        doc.resetForReanchor()

        XCTAssertEqual(doc.presenceBase, PresenceBaseState())
    }

    // MARK: Persistence (put(full) instead of a patch)

    @MainActor
    func test_persists_a_pending_patch_as_the_put_it_stands_for() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        try doc.update { _, presence in presence.set(["cursor": 1]) }
        XCTAssertEqual(self.pendingKinds(doc), [.patch])

        // The in-memory queue still holds the patch; only the persisted copy is a put, because a
        // protobuf presence change has no field for the patch's local-only `full`.
        let restored = try Document.fromBytes(key: doc.getKey(), bytes: doc.toBytes())
        XCTAssertEqual(self.pendingKinds(doc), [.patch])
        XCTAssertEqual(self.pendingKinds(restored), [.put])
        let pending = try XCTUnwrap(restored.createChangePack().getChanges().first)
        XCTAssertEqual(self.presence(of: pending), ["name": "\"a\"", "cursor": "1"])
        XCTAssertEqual(restored.getMyEncodedPresence(), ["name": "\"a\"", "cursor": "1"])
        // It is a put now, but it was minted as a patch, so it still counts as an outstanding one.
        XCTAssertTrue(restored.hasPendingPresencePatch())
        XCTAssertTrue(restored.presenceBase.patchSent)

        // The append-only log is written by the same converter, so it never holds a patch either, and
        // replaying it onto a document that has not seen the snapshot rebuilds the whole presence
        // rather than the changed key alone.
        let stored = try doc.getPendingChangesAfter(0)
        let replayed = Document(key: doc.getKey())
        try replayed.restoreAppendedChanges(stored)
        XCTAssertEqual(self.pendingKinds(replayed), [.put])
        XCTAssertEqual(replayed.getMyEncodedPresence(), ["name": "\"a\"", "cursor": "1"])
    }

    @MainActor
    func test_heals_a_restored_patch_the_server_stored_as_empty() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        try doc.update { _, presence in presence.set(["cursor": 1]) }

        // The queue is persisted as a put, but the change was minted as a patch and may have been
        // pushed as one before the restart: an old server stored it as an empty presence and its reply
        // was lost. The retry is deduplicated by clientSeq, so only the heal can repair the presence.
        let restored = try Document.fromBytes(key: doc.getKey(), bytes: doc.toBytes())
        XCTAssertEqual(self.pendingKinds(restored), [.put])
        XCTAssertTrue(restored.presenceBase.patchSent)

        try self.ack(restored, [])
        XCTAssertEqual(self.pendingKinds(restored), [.put])
        let healed = try XCTUnwrap(restored.createChangePack().getChanges().first)
        XCTAssertEqual(self.presence(of: healed), ["name": "\"a\"", "cursor": "1"])
    }

    @MainActor
    func test_does_not_heal_a_restored_put_that_was_never_a_patch() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }

        let restored = try Document.fromBytes(key: doc.getKey(), bytes: doc.toBytes())
        XCTAssertEqual(self.pendingKinds(restored), [.put])
        XCTAssertFalse(restored.presenceBase.patchSent)

        try self.ack(restored, [])
        XCTAssertEqual(self.pendingKinds(restored), [])
    }

    @MainActor
    func test_heals_a_patch_restored_from_the_append_only_log() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        try doc.update { _, presence in presence.set(["cursor": 1]) }

        let replayed = self.makeDoc()
        try replayed.restoreAppendedChanges(doc.getPendingChangesAfter(0))
        XCTAssertEqual(self.pendingKinds(replayed), [.put])
        XCTAssertTrue(replayed.presenceBase.patchSent)

        try self.ack(replayed, [])
        let healed = try XCTUnwrap(replayed.createChangePack().getChanges().first)
        XCTAssertEqual(self.presence(of: healed), ["name": "\"a\"", "cursor": "1"])
    }

    @MainActor
    func test_keeps_the_patch_mark_across_a_second_restart() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        try doc.update { _, presence in presence.set(["cursor": 1]) }

        let once = try Document.fromBytes(key: doc.getKey(), bytes: doc.toBytes())
        let twice = try Document.fromBytes(key: doc.getKey(), bytes: once.toBytes())
        XCTAssertTrue(twice.presenceBase.patchSent)

        try self.ack(twice, [])
        XCTAssertEqual(self.pendingKinds(twice), [.put])
    }

    @MainActor
    func test_stops_owing_a_heal_once_the_restored_patch_is_acknowledged_by_a_server_with_the_capability() throws {
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.ack(doc, [presencePatchCapability])
        try doc.update { _, presence in presence.set(["cursor": 1]) }

        let restored = try Document.fromBytes(key: doc.getKey(), bytes: doc.toBytes())
        try self.ack(restored, [presencePatchCapability])
        XCTAssertEqual(self.pendingKinds(restored), [], "a server that takes patches stored it faithfully")
    }

    // MARK: Wire

    @MainActor
    func test_folds_a_patch_decoded_off_the_wire_onto_the_presence_it_holds() throws {
        // The server folds a patch into the base it holds before storing one, so a pulled pack does
        // not normally carry one. One that does -- an echo, a peer ahead of this SDK -- must not fail
        // the whole pack.
        let doc = self.makeDoc()
        try doc.update { _, presence in presence.set(["name": "a", "cursor": 0]) }

        var pbPack = Converter.toChangePack(pack: doc.createChangePack())
        pbPack.changes[0].presenceChange.type = .patch
        pbPack.changes[0].presenceChange.presence.data = ["cursor": "2"]

        let decoded = try Converter.fromChangePack(pbPack)
        let change = try XCTUnwrap(decoded.getChanges().first)
        guard case .patch(let carried, let full) = change.presenceChange else {
            return XCTFail("expected a patch, got \(String(describing: change.presenceChange))")
        }
        XCTAssertEqual(carried, ["cursor": "2"])
        XCTAssertNil(full)

        // No `full` came off the wire, so the carried keys are folded onto the presence already held
        // for that actor -- what the server would have done before storing it.
        var presences: [ActorID: StringValueTypeDictionary] = [self.actor: ["name": "\"a\""]]
        try change.execute(root: CRDTRoot(), presences: &presences, source: .remote)
        XCTAssertEqual(presences[self.actor], ["name": "\"a\"", "cursor": "2"])
    }
}
