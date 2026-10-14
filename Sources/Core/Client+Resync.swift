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

/// The presence a document is attached with: values to encode, or values already encoded.
///
/// The encoded form lets a recovery re-attach with the presence the document already holds
/// without a lossy decode/encode round trip through `Any`.
enum InitialPresence {
    case values(PresenceData)
    case encoded(StringValueTypeDictionary)

    /// Applies this presence to a document's presence inside an `update`.
    func apply(to presence: Presence) {
        switch self {
        case .values(let values):
            presence.set(values)
        case .encoded(let encoded):
            presence.setEncoded(encoded)
        }
    }
}

/// Recovery of a document whose writes the server refused (yorkie-js-sdk#1463).
extension Client {
    /// Recovers a document whose local writes the server has refused, without dropping the
    /// client and the ``Document``.
    ///
    /// An auth webhook that starts denying writes mid-session (a locked document, a member
    /// downgraded to read-only, a revoked share link) leaves the refused changes in the queue.
    /// Push and pull share one RPC, so every later sync re-sends them, is denied again, and the
    /// client stops receiving other peers' changes too. The refused changes cannot be undone in
    /// place either: they are already applied to the root and there is no server-confirmed copy
    /// to fall back on. Recovery therefore re-anchors the same ``Document`` instance on the
    /// server state:
    ///
    /// 1. Wait out any in-flight sync, then drop offline persistence and take the un-pushed
    ///    changes out of the queue.
    /// 2. Detach without the presence-clear change a detach normally mints, so the pack carries
    ///    no changes a webhook could refuse and the `clientSeq` counter never has to be rewound.
    /// 3. Reset the document for re-anchoring and attach it again under the sync mode, garbage
    ///    collection option and poll interval it had, with the presence it held.
    /// 4. Restart the sync loop that the denial stopped.
    ///
    /// Keeping the instance is the point: the app's subscriptions and the editor bound to the
    /// document survive. Between the discard and the re-anchor the queue has a `clientSeq` hole
    /// no new change may be minted over, so the discard suspends minting: ``Document/update(_:_:)``,
    /// ``Document/undo()`` and ``Document/redo()`` throw ``YorkieError/Code/errRefused`` and
    /// ``Document/isMintable`` is `false` until the re-anchor. An edit made before the discard is
    /// part of the discarded set and is reported with the rest.
    ///
    /// A detach the server refuses restores the queue and leaves the document attached as it was,
    /// so the call can be retried. Past the detach the changes are gone for good and are published
    /// as a ``LocalChangesDroppedEvent`` with reason ``LocalChangesDroppedValue/Reason/writeDenied``,
    /// before the re-attach, which can still fail.
    ///
    /// The whole recovery runs under the client's sync semaphore, so no sync can start or be in
    /// flight while the queue is touched.
    ///
    /// Automatic recovery on attach denials and watch denials is not part of this call.
    ///
    /// - Parameters:
    ///   - doc: The attached document to recover.
    ///   - discardLocalChanges: Must be `true`. The un-pushed changes are taken out of the queue
    ///     and returned instead of being sent again; there is no non-discarding form, and the
    ///     argument keeps the data loss visible at the call site.
    ///   - initialPresence: The presence to re-attach with. Defaults to the document's current
    ///     presence, so the user keeps their cursor: presence is not what the server refused.
    /// - Returns: The discarded changes, so the app can report them. Re-applying them is
    ///   deliberately not the default.
    /// - Throws: ``YorkieError/Code/errClientNotActivated`` when the client is not active,
    ///   ``YorkieError/Code/errNotAttached`` when the document is not attached,
    ///   ``YorkieError/Code/errInvalidArgument`` when `discardLocalChanges` is `false`, or the
    ///   error of the detach or the re-attach.
    @discardableResult
    public func resync(_ doc: Document,
                       discardLocalChanges: Bool,
                       initialPresence: PresenceData? = nil) async throws -> [DroppedChange]
    {
        guard self.isActive else {
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }

        // Only the discarding form exists. Requiring it explicitly keeps the data loss at the
        // call site rather than in the default.
        guard discardLocalChanges else {
            throw YorkieError(code: .errInvalidArgument, message: "resync requires discardLocalChanges: true")
        }

        // A cheap early refusal, so a document that is not attached does not queue for the lock.
        // The attachment itself is read again below, under the lock.
        guard self.getDocumentAttachment(doc.getKey()) != nil else {
            throw YorkieError(code: .errNotAttached, message: "\(doc.getKey()) is not attached when \(#function).")
        }

        // The barrier: a sync pass takes this semaphore, so holding it waits out an in-flight
        // sync and keeps a fresh one from starting in any await gap below. `attach` and `detach`
        // never take it themselves, so they run safely inside. It is released before the sync
        // loop restarts, because a loop tick takes the same semaphore.
        await self.syncSemaphore.wait()

        // The target is read only now. Waiting for the lock can take a whole sync round trip,
        // and a resync ahead in the queue replaces the attachment (a re-attach builds a new
        // one), while the app may change the sync mode or the poll interval. What was read
        // before the wait would be stale: the recovery would act on an attachment no longer in
        // the map and re-attach with options the document no longer has.
        guard self.isActive else {
            self.syncSemaphore.signal()
            throw YorkieError(code: .errClientNotActivated, message: "\(self.key) is not active")
        }
        guard let attachment = self.getDocumentAttachment(doc.getKey()) else {
            self.syncSemaphore.signal()
            throw YorkieError(code: .errNotAttached, message: "\(doc.getKey()) is not attached when \(#function).")
        }

        // Preserve how the document was attached, so recovery is invisible to the app beyond the
        // re-anchor itself. Presence is carried over as stored: the cursor the user is still
        // holding is not part of what the server refused.
        let options = ReattachOptions(
            syncMode: attachment.syncMode ?? .realtime,
            disableGC: attachment.disableGC,
            pollInterval: attachment.pollIntervalPinned ? attachment.pollInterval : nil,
            presence: initialPresence.map { .values($0) } ?? .encoded(doc.getMyEncodedPresence() ?? [:])
        )

        let dropped: [DroppedChange]
        do {
            dropped = try await self.recoverInPlace(doc, attachment: attachment, options: options)
        } catch {
            self.syncSemaphore.signal()
            throw error
        }
        self.syncSemaphore.signal()

        // The `ErrPermissionDenied` that led here stopped the sync loop (it is not retryable),
        // and re-attaching alone does not revive it. Without this a recovered document would sit
        // attached and never sync again.
        if !self.getCondition(.syncLoop) {
            self.setCondition(.syncLoop, value: true)
            Task { await self.runSyncLoop() }
        }

        return dropped
    }

    /// How the document was attached, restated on the re-attach.
    private struct ReattachOptions {
        let syncMode: SyncMode
        let disableGC: Bool
        let pollInterval: TimeInterval?
        let presence: InitialPresence
    }

    /// The critical section of ``resync(_:discardLocalChanges:initialPresence:)``; the caller
    /// holds the sync semaphore.
    private func recoverInPlace(_ doc: Document,
                                attachment: Attachment<Document>,
                                options: ReattachOptions) async throws -> [DroppedChange]
    {
        // Take offline persistence out of the picture before the queue is emptied. Its log is
        // keyed by `clientSeq` and its watermark only moves forward, so a log left holding the
        // discarded changes would survive the re-anchor and be replayed into a document the
        // server has already refused them for.
        await self.discardPersistedState(for: doc)

        let discarded = doc.discardLocalChanges()
        Logger.info("[RS] c:\"\(self.key)\" resync d:\"\(doc.getKey())\", discarded:\(discarded.count)")

        do {
            // The queue is empty and the counter is past the acked checkpoint, so any change
            // minted here would present a `clientSeq` hole. The presence clear is skipped for
            // that reason; the server drops this client's presence on detach anyway.
            _ = try await self.detachDocument(doc, skipPresenceClear: true)
        } catch {
            // The detach did not happen: hand the refused changes back so the document is left
            // as it was found, attached, queue intact, counter untouched.
            doc.restoreLocalChanges(discarded)
            if self.getDocumentAttachment(doc.getKey()) === attachment {
                self.installOfflinePersistence(on: attachment,
                                               doc: doc,
                                               lease: attachment.sessionLockHandle,
                                               persist: attachment.persistsToStore)
            }
            Logger.error("[RS] c:\"\(self.key)\" resync d:\"\(doc.getKey())\" detach failed; local changes restored", error: error)
            throw error
        }

        // Past here the changes are gone for good, so report them before the step that can still
        // fail: an app listening for the data-loss event gets them even if the re-attach throws.
        doc.publishLocalChangesDroppedEvent(reason: .writeDenied, changes: discarded)

        self.reanchor(doc)
        _ = try await self.attachInternal(doc,
                                          presence: options.presence,
                                          syncMode: options.syncMode,
                                          documentPollInterval: options.pollInterval,
                                          disableGC: options.disableGC)

        return discarded.map { DroppedChange($0) }
    }
}
