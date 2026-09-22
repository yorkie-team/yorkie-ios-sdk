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

/// One persisted local change, tagged with the `clientSeq` it carries.
///
/// The sequence is what lets a store drop changes a sync has already acknowledged, and
/// what lets a restore detect a hole rather than replaying a discontinuous run.
public struct StoredChange: Sendable, Equatable {
    /// The `clientSeq` this change carries.
    public let clientSeq: UInt32
    /// The serialized change.
    public let bytes: Data

    public init(clientSeq: UInt32, bytes: Data) {
        self.clientSeq = clientSeq
        self.bytes = bytes
    }
}

/// Everything a backend holds for one document: a base snapshot, the changes appended
/// since it, and a small mutable header.
public struct StoredDoc: Sendable, Equatable {
    /// A ``Document/toBytes()`` envelope.
    public let snapshot: Data

    /// Checkpoint and changeID as of the last sync. Absent until the first one.
    ///
    /// Held apart from the snapshot because a sync has to advance it constantly while
    /// the snapshot stays put.
    public let meta: Data?

    /// Changes appended since the snapshot, ascending by `clientSeq`.
    public let changes: [StoredChange]

    public init(snapshot: Data, meta: Data? = nil, changes: [StoredChange] = []) {
        self.snapshot = snapshot
        self.meta = meta
        self.changes = changes
    }
}

/// A pluggable persistence backend for offline document state.
///
/// It is deliberately a snapshot plus an append-only change log rather than one opaque
/// blob. Re-serializing the whole document on every edit costs time proportional to the
/// document -- hundreds of milliseconds on a large one -- and a document is at its
/// largest while it is being edited, which is exactly when the writes happen. Appending
/// costs the size of one change, which does not grow with the document at all.
///
/// The interface stays byte-oriented and async so a durable backend can implement it
/// without the client knowing which storage it talks to, and so a backend is free to
/// compress or encrypt what it is handed. The default ``MemoryDocStore`` keeps
/// everything in a process-local dictionary and carries no dependency.
public protocol DocStore: Sendable {
    /// Returns the persisted state for `docKey`, or `nil` when nothing has been stored.
    ///
    /// - Parameter docKey: The key of the document to load.
    /// - Returns: The stored state, whose `changes` must be ordered by ascending
    ///   `clientSeq`, or `nil` when the key is absent.
    /// - Throws: Any error the underlying storage raises.
    func load(docKey: String) async throws -> StoredDoc?

    /// Replaces the snapshot and atomically drops every appended change **and any
    /// stored meta**.
    ///
    /// This is compaction: the new snapshot already contains those changes, so keeping
    /// them would replay them twice, and it embeds a newer header than meta holds, so
    /// keeping that would regress the client's clocks.
    ///
    /// - Parameters:
    ///   - docKey: The key of the document to store.
    ///   - bytes: The serialized snapshot.
    /// - Throws: Any error the underlying storage raises.
    func saveSnapshot(docKey: String, bytes: Data) async throws

    /// Appends one local change.
    ///
    /// This is the hot path -- frequent and small -- so an implementation must not
    /// rewrite the whole entry to satisfy it.
    ///
    /// It is an **upsert keyed by `clientSeq`**: re-appending a change already stored
    /// replaces it rather than duplicating it, so a retried write is safe.
    ///
    /// - Parameters:
    ///   - docKey: The key of the document the change belongs to.
    ///   - change: The change to append.
    /// - Throws: Any error the underlying storage raises.
    func appendChange(docKey: String, change: StoredChange) async throws

    /// Records the post-sync header.
    ///
    /// It leaves the snapshot alone -- an online client syncs constantly, and
    /// re-snapshotting per sync would reintroduce the cost this interface exists to
    /// avoid -- and it leaves the **log** alone too.
    ///
    /// That second part is load-bearing. The log does two jobs: it holds un-pushed
    /// changes so they survive a reload, and it is the delta between the snapshot and
    /// the document's current content. Deleting acknowledged entries serves the first
    /// job and destroys the second, because nothing brings the snapshot forward on a
    /// push-ack -- the content would then exist in neither place while the persisted
    /// `serverSeq` claims the server has it. Only compaction trims the log, and it does
    /// so by folding the entries into a new snapshot first.
    ///
    /// The header itself carries the acknowledged `clientSeq`, so a restore reads it
    /// from there; the store needs no separate parameter for it.
    ///
    /// It is a no-op when nothing is stored for the key.
    ///
    /// - Parameters:
    ///   - docKey: The key of the document whose header is being recorded.
    ///   - bytes: The serialized header.
    /// - Throws: Any error the underlying storage raises.
    func saveMeta(docKey: String, bytes: Data) async throws

    /// Removes everything persisted for `docKey`.
    ///
    /// Removing an absent key succeeds.
    ///
    /// - Parameter docKey: The key of the document to remove.
    /// - Throws: Any error the underlying storage raises.
    func remove(docKey: String) async throws
}

/// A ``DocStore`` that keeps documents in memory for the lifetime of the process.
///
/// This is the default, and it is deliberately not persistent: it makes the resume path
/// exercisable without committing the SDK to a storage location. Supply your own
/// ``DocStore`` to survive process restarts.
///
/// `Data` is a value type, so the copy-in/copy-out the reference implementation makes
/// explicit happens here by assignment: neither a caller mutating what it wrote nor one
/// mutating what it read can corrupt the stored entry.
public actor MemoryDocStore: DocStore {
    private var store: [String: StoredDoc] = [:]

    public init() {}

    public func load(docKey: String) async throws -> StoredDoc? {
        return self.store[docKey]
    }

    public func saveSnapshot(docKey: String, bytes: Data) async throws {
        // The header is dropped, not carried forward. A snapshot envelope embeds its
        // own checkpoint and changeID, and they are newer than whatever meta held;
        // applying the old header over the new snapshot would regress `serverSeq` and
        // -- worse -- `lamport`, whose regression makes the next edit mint tickets that
        // collide with identities already in the restored root.
        self.store[docKey] = StoredDoc(snapshot: bytes, meta: nil, changes: [])
    }

    public func appendChange(docKey: String, change: StoredChange) async throws {
        guard let entry = self.store[docKey] else {
            return
        }

        // Upsert, not append: `clientSeq` identifies the change, and a re-append of one
        // already stored is a retry rather than a second change. A durable backend
        // keyed on (docKey, clientSeq) behaves this way implicitly; the two must not
        // disagree, because an app writes its backend against this contract.
        var changes = entry.changes
        if let existing = changes.firstIndex(where: { $0.clientSeq == change.clientSeq }) {
            changes[existing] = change
        } else {
            changes.append(change)
            changes.sort { $0.clientSeq < $1.clientSeq }
        }

        self.store[docKey] = StoredDoc(snapshot: entry.snapshot, meta: entry.meta, changes: changes)
    }

    public func saveMeta(docKey: String, bytes: Data) async throws {
        guard let entry = self.store[docKey] else {
            return
        }
        self.store[docKey] = StoredDoc(snapshot: entry.snapshot, meta: bytes, changes: entry.changes)
    }

    public func remove(docKey: String) async throws {
        self.store.removeValue(forKey: docKey)
    }
}
