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

import Foundation

/// Pre-attach ticket re-issue for ``Document`` (yorkie-js-sdk#1449).
///
/// A document has no actor until a client attaches it, so every edit made before ``Client/attach``
/// mints its tickets under the initial actor. Two clients that fill the same key before attaching
/// would push values with the same `createdAt` -- an element's identity -- and diverge. On attach, a
/// never-synced document therefore re-issues the tickets it minted to the client's actor, in the
/// local changes and in the root alike.
///
/// Kept in its own file rather than the `Document` class body, which is at this project's
/// `type_body_length` budget; the private state it needs is reached through
/// ``Document/installReissuedState(changes:root:presences:changeID:)``.
/// See `docs/design/pre-attach-ticket-reissue.md` in yorkie-js-sdk.
extension Document {
    /// Returns the source a queued local change has to be executed under when it is replayed.
    ///
    /// A change an undo or a redo produced ran with ``OpSource/undoRedo``, the only source
    /// ``SetOperation`` and ``RemoveOperation`` consult to skip an operation whose target sits under
    /// a removed parent. Replaying it as `.local` runs an operation that never ran, so the rebuilt
    /// root differs from the one the user sees. Every path that replays the queue
    /// (``applySnapshot(_:_:_:_:)``, the re-issue, `restoreAppendedChanges`) goes through this.
    static func replaySource(of change: Change) -> OpSource {
        change.isUndoRedo ? .undoRedo : .local
    }

    /// Sets the actor of this document and, when `reissue` is true, re-issues the tickets a
    /// never-synced document minted under its previous actor to the new one.
    ///
    /// Without `reissue` it rewrites only the change ids and each operation's `executedAt`; the root
    /// and the tickets inside the operations keep the actor they were minted under. With `reissue`, a
    /// document that has synced, has no local changes or already has the actor falls back to the plain
    /// ``setActor(_:)``. A position or element id taken from a re-issued document before then no
    /// longer resolves.
    ///
    /// Internal: rewriting element identity under a caller-chosen actor is not a capability for
    /// application code. Only the owning ``Client`` asks for it, because whether the re-issue is sound
    /// depends on what else the actor has minted, which only the client knows.
    ///
    /// - Parameters:
    ///   - actorID: The actor to set.
    ///   - reissue: Whether to re-issue the tickets of a never-synced document.
    /// - Returns: Whether the tickets were re-issued.
    /// - Throws: ``YorkieError`` when the re-issue fails; the document is left untouched.
    @discardableResult
    func setActor(_ actorID: ActorID, reissue: Bool) throws -> Bool {
        if reissue, try self.reissueActor(actorID) {
            return true
        }

        self.setActor(actorID)
        return false
    }

    /// Whether every ticket naming this document's actor was minted by a local change still queued:
    /// nothing has been pushed and nothing pulled.
    var neverSynced: Bool {
        if self.absorbedRemote || self.status != .detached || self.checkpoint != .initial {
            return false
        }

        let actor = self.changeID.getActorID()
        return self.changeID.getVersionVector().allSatisfy { $0.key == actor }
    }

    /// Returns whether this document has produced a local change carrying operations, i.e. whether
    /// tickets naming its actor may already be in the document its key names. The client reads it to
    /// decide whether a re-issue -- which starts the actor's lamports back at 1 -- can still be sound
    /// for that key.
    func hasMintedOperations() -> Bool {
        self.mintedOperations
    }

    /// Re-issues the tickets of a never-synced document to `actor` and returns true, or returns
    /// false and changes nothing when the document has synced, has no local changes or already has
    /// the actor.
    ///
    /// The local changes go through ``Reissue/reissueOperations(_:from:to:)``, and the root and
    /// presences are rebuilt by replaying them on a fresh root: a never-synced root is exactly the
    /// initial root plus its local changes, and the replay is the computation the server performs on
    /// the pushed changes. Everything is built aside and swapped in at the end, so a throw leaves the
    /// document untouched.
    private func reissueActor(_ actor: ActorID) throws -> Bool {
        guard let prev = self.changeID.getActorID() else {
            return false
        }
        let localChanges = self.getPendingChangeStructs()
        guard prev != actor, !localChanges.isEmpty, self.neverSynced else {
            return false
        }

        // Each rebuilt change carries over the source it was originally executed with
        // (``Change/isUndoRedo``): see ``replaySource(of:)``.
        var changes = [Change]()
        changes.reserveCapacity(localChanges.count)
        for change in localChanges {
            let id = change.id
            let operations = try Reissue.reissueOperations(change.operations, from: prev, to: actor)
            changes.append(Change(
                id: id
                    .setActor(actor)
                    .setVersionVector(Self.reissueVersionVector(id.getVersionVector(), from: prev, to: actor)),
                operations: operations,
                presenceChange: change.presenceChange,
                message: change.message,
                isUndoRedo: change.isUndoRedo,
                wasMintedAsPresencePatch: change.wasMintedAsPresencePatch
            ))
        }

        let root = CRDTRoot()
        var presences = [ActorID: StringValueTypeDictionary]()
        for change in changes {
            try change.execute(root: root, presences: &presences, source: Self.replaySource(of: change))
        }

        let changeID = self.changeID
            .setActor(actor)
            .setVersionVector(Self.reissueVersionVector(self.changeID.getVersionVector(), from: prev, to: actor))

        // The devtools recording holds the raw changes as they were minted, which no longer replay
        // onto this root. The baseline is built aside as well so a failure leaves the recording alone.
        let baseline = self.isEnableDevtools()
            ? try self.reissueBaseline(root: root, presences: presences, changeID: changeID)
            : nil

        // Nothing below can throw: swap everything in.
        var onlineClients = self.onlineClients
        if onlineClients.remove(prev) != nil {
            onlineClients.insert(actor)
        }

        self.installReissuedState(changes: changes, root: root, presences: presences, changeID: changeID)
        self.onlineClients = onlineClients

        // The panel replays a history onto a freshly built empty document, so a recording that starts
        // after the attach would replay onto a root that never had the pre-attach changes. The
        // re-issued root is handed over as the recording's first event instead.
        if let baseline {
            self.attachDevtoolsRecorder()?.reset(baseline: baseline)
        }
        return true
    }

    /// Builds the snapshot event that gives a devtools recording started over a baseline to replay
    /// from, the way ``applySnapshot(_:_:_:_:)`` builds the one it publishes.
    private func reissueBaseline(
        root: CRDTRoot,
        presences: [ActorID: StringValueTypeDictionary],
        changeID: ChangeID
    ) throws -> DocEvent {
        let snapshot = try Converter.snapshotToBytes(root: root.object, presences: presences)
        let snapshotVector = try Converter.versionVectorToHex(vector: changeID.getVersionVector())
        return SnapshotEvent(value: SnapshotInfo(
            serverSeq: self.checkpoint.getServerSeq(),
            snapshot: snapshot,
            snapshotVector: snapshotVector
        ))
    }

    /// Returns a copy of `vector` whose entry for `from` is moved to `to`, keeping the larger
    /// lamport when `to` already has one.
    static func reissueVersionVector(_ vector: VersionVector, from: ActorID, to: ActorID) -> VersionVector {
        var reissued = vector.deepcopy()
        guard let lamport = reissued.get(from) else {
            return reissued
        }

        reissued.unset(actorID: from)
        if let existing = reissued.get(to), existing > lamport {
            reissued.set(actorID: to, lamport: existing)
        } else {
            reissued.set(actorID: to, lamport: lamport)
        }
        return reissued
    }
}
