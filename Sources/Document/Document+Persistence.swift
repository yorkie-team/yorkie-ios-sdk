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

/// The JSON shape of the checkpoint blob inside a ``Document/toBytes()`` envelope.
///
/// `serverSeq` is a string (matching yorkie-js-sdk's `checkpoint.getServerSeq().toString()`,
/// since `Int64` does not round-trip losslessly through JSON in every decoder); `clientSeq`
/// is a plain JSON number.
private struct PersistedCheckpoint: Codable {
    let serverSeq: String
    let clientSeq: UInt32
}

/// The restorable state of a ``Document``: everything ``Document/toBytes()`` persists and
/// ``Document/applyPersistedState(_:)`` installs.
///
/// Bundling these fields keeps ``Document/applyPersistedState(_:)`` to a single parameter
/// instead of one per field, which this project's `function_parameter_count` lint budget
/// (5) would otherwise reject.
struct PersistedDocumentState {
    /// The root object to install.
    let root: CRDTRoot
    /// The presences to install.
    let presences: [ActorID: StringValueTypeDictionary]
    /// The checkpoint to install.
    let checkpoint: Checkpoint
    /// The change id to install.
    let changeID: ChangeID
    /// The pending local changes to install.
    let localChanges: [Change]
    /// The compaction epoch to install.
    let epoch: Int64
    /// The document id to install.
    let docID: DocumentID
}

/// Offline local-persistence support for ``Document``: serializing a document's restorable
/// state to bytes and restoring it, so an app can survive a process restart with its
/// un-pushed local changes intact.
///
/// Kept in its own file rather than the `Document` class body itself, which is already at
/// this project's `type_body_length` budget; the few private fields this extension needs
/// (`root`, `presences`, `localChanges`, and the `changeID` setter) are reached through the
/// internal ``Document/persistenceSnapshot()`` / ``Document/applyPersistedState(root:presences:checkpoint:changeID:localChanges:epoch:docID:)``
/// bridge instead of widening their access level.
///
/// ## Envelope format
///
/// The envelope packs six blobs, in order: a protobuf snapshot of the root object and
/// presences, the checkpoint (JSON), the change id (protobuf binary), the pending local
/// changes, the compaction epoch (decimal string), and the document id (UTF-8). Each blob is
/// prefixed with its length as a 4-byte little-endian `UInt32` — the same `packBlobs` framing
/// yorkie-js-sdk uses, so the two encodings stay structurally comparable.
///
/// ## Divergence from yorkie-js-sdk
///
/// Upstream serializes the pending-changes blob as JSON change structs
/// (`change.toStruct()`), which TypeScript gets for free from structural typing. This SDK
/// already has a protobuf path for changes (``Converter/toChange(_:)``), and hand-rolling
/// `Codable` for every ``Operation`` case to match upstream's JSON shape would be pure
/// duplication for no benefit: this blob is local-only and never crosses SDKs, so only
/// round-trip fidelity within iOS is required, not wire parity with JS. The pending-changes
/// blob is therefore a serialized ``PbChangePack`` used purely as a container for its
/// `changes` field — reusing an existing message rather than adding a new one, the same
/// reasoning upstream gives for reusing its `Snapshot` message in ``Converter/snapshotToBytes(root:presences:)``.
/// Blob order and the 4-byte-LE framing are otherwise identical to upstream.
public extension Document {
    /// Serializes the full restorable state of this document into a self-contained byte
    /// envelope: the root and presences (as a snapshot), the checkpoint, the change id, the
    /// pending local changes, the compaction epoch, and the document id.
    /// ``fromBytes(key:bytes:opts:)`` reverses it, so a document survives a process restart
    /// with its un-pushed edits intact.
    ///
    /// - Returns: The serialized envelope.
    /// - Throws: ``YorkieError`` when a root element cannot be encoded (see
    ///   ``Converter/snapshotToBytes(root:presences:)``) or the checkpoint fails to encode
    ///   as JSON.
    func toBytes() throws -> Data {
        let state = self.persistenceSnapshot()

        let snapshotBlob = try Converter.snapshotToBytes(root: state.root, presences: state.presences)

        let persistedCheckpoint = PersistedCheckpoint(
            serverSeq: state.checkpoint.getServerSeqAsString(),
            clientSeq: state.checkpoint.getClientSeq()
        )
        let checkpointBlob = try JSONEncoder().encode(persistedCheckpoint)

        let changeIDBlob = try Converter.toChangeID(state.changeID).serializedData()

        var pbPendingChanges = PbChangePack()
        pbPendingChanges.changes = Converter.toChanges(state.localChanges)
        let pendingChangesBlob = try pbPendingChanges.serializedData()

        let epochBlob = Data(String(self.getEpoch()).utf8)
        let docIDBlob = Data(self.getDocID().utf8)

        return Self.packBlobs([snapshotBlob, checkpointBlob, changeIDBlob, pendingChangesBlob, epochBlob, docIDBlob])
    }

    /// Reconstructs a document from the bytes produced by ``toBytes()``, restoring the
    /// root, presences, checkpoint, change id, pending local changes, epoch and document id.
    ///
    /// - Parameters:
    ///   - key: The key of the reconstructed document.
    ///   - bytes: The envelope produced by a prior ``toBytes()``.
    ///   - opts: The options for the reconstructed document. Defaults to
    ///     ``DocumentOptions`` with GC enabled.
    /// - Returns: A new document restored from `bytes`.
    /// - Throws: ``YorkieError`` with ``ErrorCode/errInvalidArgument`` when `bytes` is not a
    ///   well-formed envelope (a truncated length prefix, a blob length exceeding the
    ///   remaining bytes, a blob count other than six, or a malformed field within a blob).
    static func fromBytes(key: DocKey, bytes: Data, opts: DocumentOptions = DocumentOptions(disableGC: false)) throws -> Document {
        let decoded = try Self.decodePersistedBytes(bytes)

        let document = Document(key: key, opts: opts)
        document.applyPersistedState(PersistedDocumentState(
            root: CRDTRoot(rootObject: decoded.root),
            presences: decoded.presences,
            checkpoint: decoded.checkpoint,
            changeID: decoded.changeID,
            localChanges: decoded.localChanges,
            epoch: decoded.epoch,
            docID: decoded.docID
        ))
        return document
    }

    /// Rehydrates this document in place from the bytes produced by ``toBytes()``,
    /// overwriting the root, presences, checkpoint, change id, pending local changes, epoch
    /// and document id. Unlike the static ``fromBytes(key:bytes:opts:)``, it mutates the
    /// existing instance so a document the caller already holds (and is about to attach)
    /// recovers its persisted, un-pushed state.
    ///
    /// Actor guard: the persisted change id must carry the same actor this document already
    /// has, when both are known. If a store is reused under a different client identity, the
    /// current actor differs from the persisted one; restoring anyway would stamp subsequent
    /// edits with the current actor while the restored root/changes keep the persisted actor,
    /// silently diverging the CRDT against a server that keys on the current actor. On
    /// mismatch this throws instead, so the caller can surface the data loss and re-anchor
    /// rather than corrupt state.
    ///
    /// - Parameter bytes: The envelope produced by a prior ``toBytes()``.
    /// - Throws: ``YorkieError`` with `errInvalidArgument` when `bytes` is malformed (see
    ///   ``fromBytes(key:bytes:opts:)``), or with `errActorMismatch` when the persisted actor
    ///   does not match this document's current actor. The two are distinguished so a caller
    ///   can tell a store reused under another identity from bytes it simply cannot decode.
    func restoreFromBytes(_ bytes: Data) throws {
        let currentActor = self.changeID.getActorID()
        let decoded = try Self.decodePersistedBytes(bytes)
        let restoredActor = decoded.changeID.getActorID()

        if let currentActor, let restoredActor, currentActor != restoredActor {
            throw YorkieError(
                code: .errActorMismatch,
                message: "persisted actor \"\(restoredActor)\" does not match the current actor " +
                    "\"\(currentActor)\"; the store was reused under a different client identity, " +
                    "restoring would diverge the CRDT"
            )
        }

        self.applyPersistedState(PersistedDocumentState(
            root: CRDTRoot(rootObject: decoded.root),
            presences: decoded.presences,
            checkpoint: decoded.checkpoint,
            changeID: decoded.changeID,
            localChanges: decoded.localChanges,
            epoch: decoded.epoch,
            docID: decoded.docID
        ))
    }

    /// Returns the current un-pushed local changes of this document.
    ///
    /// Upstream's `getPendingChangeStructs` exists only to feed its JSON `ChangeStruct`
    /// encoding of `toBytes`. iOS has no such struct layer — ``Change`` already serializes
    /// to protobuf directly via ``Converter/toChange(_:)`` — so this returns the ``Change``
    /// values themselves rather than an intermediate struct representation. Callers that
    /// need to surface or re-apply changes an offline-persistence layer could not reconcile
    /// can read their operations directly off the returned values.
    ///
    /// - Returns: The document's pending local changes, in application order.
    func getPendingChangeStructs() -> [Change] {
        self.persistenceSnapshot().localChanges
    }

    /// Drops all local state that was seeded from a stale persisted envelope so the document
    /// can be re-attached fresh. The server then re-anchors the client from the current
    /// snapshot.
    ///
    /// Used on the store-backed attach path when a resume is rejected for a stale epoch: the
    /// persisted checkpoint, epoch, change id and any un-pushed local changes are stale
    /// relative to the compacted document, so presenting them again would just be rejected.
    /// This mirrors constructing a brand-new ``Document`` instance without forcing the caller
    /// to swap the object reference it already holds.
    func resetForReanchor() {
        self.applyPersistedState(PersistedDocumentState(
            root: CRDTRoot(),
            presences: [:],
            checkpoint: .initial,
            changeID: .initial,
            localChanges: [],
            epoch: 0,
            docID: ""
        ))
    }
}

private extension Document {
    /// The decoded, not-yet-installed contents of a ``toBytes()`` envelope.
    typealias PersistedState = (
        root: CRDTObject,
        presences: [ActorID: StringValueTypeDictionary],
        checkpoint: Checkpoint,
        changeID: ChangeID,
        localChanges: [Change],
        epoch: Int64,
        docID: DocumentID
    )

    /// Decodes a ``toBytes()`` envelope into its constituent state, without installing it
    /// onto any document instance. Shared by ``fromBytes(key:bytes:opts:)`` and
    /// ``restoreFromBytes(_:)``.
    static func decodePersistedBytes(_ bytes: Data) throws -> PersistedState {
        let blobs = try Self.unpackBlobs(bytes)
        // Envelope invariant: the first four blobs are required; trailing blobs are optional.
        // An envelope written before a later field existed carries fewer (four before epoch,
        // five before docID) and each is defaulted below, while one written by a newer SDK
        // carries more and the extras are ignored. Tolerating both directions is deliberate:
        // a strict count would mean an app downgrade, or a share extension running an older
        // SDK than its host, discards the user's un-pushed offline edits. Any future field
        // MUST be appended as a new trailing blob and stay optional here.
        guard blobs.count >= 4 else {
            throw YorkieError(
                code: .errInvalidArgument,
                message: "corrupt envelope: expected at least 4 blobs, got \(blobs.count)"
            )
        }

        let (root, presences) = try Converter.bytesToSnapshot(bytes: blobs[0])

        let persistedCheckpoint: PersistedCheckpoint
        do {
            persistedCheckpoint = try JSONDecoder().decode(PersistedCheckpoint.self, from: blobs[1])
        } catch {
            throw YorkieError(code: .errInvalidArgument, message: "corrupt envelope: invalid checkpoint blob")
        }
        guard let serverSeq = Int64(persistedCheckpoint.serverSeq) else {
            throw YorkieError(
                code: .errInvalidArgument,
                message: "corrupt envelope: invalid checkpoint serverSeq \"\(persistedCheckpoint.serverSeq)\""
            )
        }
        let checkpoint = Checkpoint(serverSeq: serverSeq, clientSeq: persistedCheckpoint.clientSeq)

        let changeID = try Converter.fromChangeID(PbChangeID(serializedBytes: blobs[2]))

        let pbPendingChanges = try PbChangePack(serializedBytes: blobs[3])
        let localChanges = try Converter.fromChanges(pbPendingChanges.changes)

        // Absent in a pre-epoch envelope, in which case the document re-learns the epoch from
        // the next server response.
        let epoch: Int64
        if blobs.count > 4 {
            guard let epochString = String(data: blobs[4], encoding: .utf8), let parsed = Int64(epochString) else {
                throw YorkieError(code: .errInvalidArgument, message: "corrupt envelope: invalid epoch blob")
            }
            epoch = parsed
        } else {
            epoch = 0
        }

        // Absent in a pre-docID envelope. An empty id disables the purge guard for this
        // resume rather than failing it, and the next attach records the server's id.
        let docID: DocumentID
        if blobs.count > 5 {
            guard let parsed = String(data: blobs[5], encoding: .utf8) else {
                throw YorkieError(code: .errInvalidArgument, message: "corrupt envelope: invalid docID blob")
            }
            docID = parsed
        } else {
            docID = ""
        }

        return (root, presences, checkpoint, changeID, localChanges, epoch, docID)
    }

    /// Concatenates the given blobs into a single envelope: each blob is prefixed with its
    /// length as a 4-byte little-endian `UInt32`, matching yorkie-js-sdk's `packBlobs`
    /// framing exactly.
    static func packBlobs(_ blobs: [Data]) -> Data {
        var out = Data()
        for blob in blobs {
            let length = UInt32(blob.count)
            out.append(UInt8(length & 0xFF))
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8((length >> 16) & 0xFF))
            out.append(UInt8((length >> 24) & 0xFF))
            out.append(blob)
        }
        return out
    }

    /// Reverses ``packBlobs(_:)``: splits an envelope back into its ordered blobs.
    ///
    /// Every length prefix is bounds-checked against the remaining bytes before it is used
    /// to slice, so a corrupt or truncated envelope throws instead of trapping.
    ///
    /// - Throws: ``YorkieError`` with ``ErrorCode/errInvalidArgument`` when a length prefix
    ///   is truncated or claims more bytes than remain in the envelope.
    static func unpackBlobs(_ bytes: Data) throws -> [Data] {
        let bytes = [UInt8](bytes)
        let count = bytes.count

        var blobs = [Data]()
        var offset = 0
        while offset < count {
            guard offset + 4 <= count else {
                throw YorkieError(code: .errInvalidArgument, message: "corrupt envelope: truncated length prefix")
            }
            let length = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            offset += 4

            guard offset + Int(length) <= count else {
                throw YorkieError(
                    code: .errInvalidArgument,
                    message: "corrupt envelope: blob length exceeds remaining bytes"
                )
            }
            blobs.append(Data(bytes[offset ..< (offset + Int(length))]))
            offset += Int(length)
        }
        return blobs
    }
}
