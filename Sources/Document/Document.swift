/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

import Combine
import Foundation

/**
 * `DocumentOptions` are the options to create a new document.
 *
 * @public
 */
public struct DocumentOptions {
    /**
     * `disableGC` disables garbage collection if true.
     */
    var disableGC: Bool

    /**
     * `enableDevtools` enables the devtools recorder if true. When enabled, the
     * document captures its replayable events into a bounded ring buffer that
     * can be exported in the yorkie-js-sdk devtools format for cross-platform
     * debugging. See ``DevtoolsRecorder``.
     */
    var enableDevtools: Bool

    /**
     * `disablePresence` declares that this document does not use presence.
     * When true, ``Document/update(_:_:)``'s `presence.set` calls are silently
     * dropped and the server strips any presence that nonetheless reaches it.
     * The option is server-fixated on first attach — once a document is created
     * presenceless, subsequent attaches observe `true` from the attach response
     * regardless of the local option value. Use for counter-only or other
     * presence-free workloads where the per-client presence map would otherwise
     * leak memory in long-lived documents.
     */
    var disablePresence: Bool

    public init(disableGC: Bool, enableDevtools: Bool = false, disablePresence: Bool = false) {
        self.disableGC = disableGC
        self.enableDevtools = enableDevtools
        self.disablePresence = disablePresence
    }
}

/**
 * `DocStatus` represents the status of the document.
 */
public enum DocStatus: String {
    /**
     * Detached means that the document is not attached to the client.
     * The actor of the ticket is created without being assigned.
     */
    case detached

    /**
     * Attached means that this document is attached to the client.
     * The actor of the ticket is created with being assigned by the client.
     */
    case attached

    /**
     * Removed means that this document is removed. If the document is removed,
     * it cannot be edited.
     */
    case removed
}

public typealias DocKey = String
public typealias DocumentID = String

public enum PresenceSubscriptionType: String {
    case presence
    case myPresence
    case others
}

/**
 * A CRDT-based data type. We can representing the model
 * of the application. And we can edit it even while offline.
 * It implements Attachable interface to be managed by Attachment.
 *
 */
@MainActor
public class Document: Attachable {
    public typealias SubscribeCallback = @MainActor (DocEvent, Document) -> Void

    private let key: DocKey
    private(set) var status: DocStatus = .detached
    /// The construction-time GC opt-out from ``DocumentOptions``. Gates whether
    /// ``garbageCollect(minSyncedVersionVector:)`` runs. Immutable — mirrors the JS
    /// `opts.disableGC`.
    private let optionDisableGC: Bool
    /// Whether this document uses the lamport-only sync path in ``applyChanges(_:source:)``.
    /// Starts `false` and is set authoritatively by the client on attach via
    /// ``setDisableGC(_:)`` — mirrors the JS `disableGC` field (distinct from `opts.disableGC`).
    private var disableGC: Bool = false
    /// Whether this document was attached presenceless. When true,
    /// ``update(_:_:)``'s presence changes are silently dropped. Seeded from
    /// ``DocumentOptions`` on construction and overwritten by the server-fixated
    /// value in the attach response via ``setDisablePresence(_:)``.
    private var disablePresence: Bool = false
    /// Ensures the presence-drop warning is emitted at most once per document,
    /// so long-lived presence-free documents do not spam the log.
    private var presenceDropWarned: Bool = false
    private let enableDevtools: Bool

    /// Records replayable events into a ring buffer when `enableDevtools` is set.
    /// Created lazily on the first published event, or eagerly via
    /// ``attachDevtoolsRecorder()`` when an inspector UI needs to observe it.
    public private(set) var devtoolsRecorder: DevtoolsRecorder?
    private(set) var changeID: ChangeID = .initial
    var checkpoint: Checkpoint = .initial
    private var localChanges = [Change]()
    private var maxSizeLimit: Int
    private var schemaRules: [Rule] = []

    /// The document's last-known compaction epoch. Learned from every server response
    /// pack in ``applyChangePack(_:)`` and presented back on the next attach/sync via
    /// ``createChangePack(_:)``. Persisted by ``toBytes()`` so a resumed offline session
    /// presents the epoch the document was last synced under; if the document was
    /// force-compacted while offline the server sees a stale epoch and rejects the
    /// resume, which should drive a store-backed re-anchor via ``resetForReanchor()``.
    private var epoch: Int64 = 0

    /// The server-assigned document id recorded after a successful attach via
    /// ``setDocID(_:)``. Persisted by ``toBytes()`` so a restored offline session can
    /// compare it against the id the server returns on re-attach: a mismatch means the
    /// server GC'd/deleted the document and minted a fresh one. Empty until the first
    /// attach records it.
    private var docID: DocumentID = ""

    /// Stores the undo/redo history of this document.
    private let internalHistory = History()
    /// Whether an `update` is in progress. Undo/redo is not allowed during an update.
    private var isUpdating = false

    private var root = CRDTRoot()
    private var clone: (root: CRDTRoot, presences: [ActorID: StringValueTypeDictionary])?

    private var defaultSubscribeCallback: SubscribeCallback?
    private var subscribeCallbacks = [String: SubscribeCallback]()
    private var presenceSubscribeCallback = [String: SubscribeCallback]()
    private var connectionSubscribeCallback: SubscribeCallback?
    private var statusSubscribeCallback: SubscribeCallback?
    private var syncSubscribeCallback: SubscribeCallback?
    private var authErrorSubscribeCallback: SubscribeCallback?
    private var epochMismatchSubscribeCallback: SubscribeCallback?

    /**
     * `onlineClients` is a set of client IDs that are currently online.
     */
    public var onlineClients = Set<ActorID>()

    /**
     * `presences` is a map of client IDs to their presence information.
     */
    private var presences = [ActorID: StringValueTypeDictionary]()

    public convenience nonisolated init(key: String) {
        self.init(key: key, opts: DocumentOptions(disableGC: false))
    }

    public nonisolated init(key: DocKey, opts: DocumentOptions) {
        self.key = key
        self.optionDisableGC = opts.disableGC
        // Seed from the local option so the gate already works before the first
        // attach response lands (e.g. a document constructed with
        // `disablePresence: true` that calls `update` before attaching).
        self.disablePresence = opts.disablePresence
        self.enableDevtools = opts.enableDevtools
        self.maxSizeLimit = 0
    }

    /**
     * `update` executes the given updater to update this document.
     */
    public func update(
        _ updater: (_ root: JSONObject, _ presence: inout Presence) throws -> Void,
        _ message: String? = nil
    ) throws {
        guard self.status != .removed else {
            throw YorkieError(code: .errDocumentRemoved, message: "\(self) is removed.")
        }

        guard let actorID = self.actorID else {
            throw YorkieError(code: .errUnexpected, message: "actor ID is null.")
        }

        // 01. Update the clone object and create a change.
        let clone = self.cloned
        let context = ChangeContext(
            prevID: self.changeID,
            root: clone.root,
            message: message
        )

        let proxy = JSONObject(target: clone.root.object, context: context)

        if self.presences[actorID] == nil {
            self.clone?.presences[actorID] = [:]
        }

        var presence = Presence(changeContext: context, presence: self.clone?.presences[actorID] ?? [:])

        // NOTE: the updater must not call undo/redo; isUpdating guards against that.
        self.isUpdating = true
        do {
            try updater(proxy, &presence)
        } catch {
            // NOTE(hackerwins): If the updater fails, the cloneRoot and clone
            // presences have to go: the updater may already have mutated them
            // before throwing, and the change context carrying those mutations
            // is dropped here, so the clone would stay permanently ahead of the
            // root. That matters beyond "an invalid state to read" -- the clone
            // is what index-based local array edits resolve against and what
            // `maxSizeLimit` is measured on, so a stale one silently mistargets
            // later edits. `document.ts` clears it in the same place.
            self.clone = nil
            self.isUpdating = false
            throw error
        }
        self.isUpdating = false

        // Presence-free documents (disablePresence) silently drop any presence
        // change recorded by the updater: the server never stores or emits
        // presence for them, so dropping locally avoids a redundant presence-only
        // LocalChange and history entry. The warning fires at most once per
        // document instance. Only the context change is dropped — the clone's
        // presence seed is still written back below (mirroring yorkie-js-sdk,
        // which mutates the clone in place and only clears the context change),
        // so a later `disablePresence` flip diffs against the correct seed.
        if self.disablePresence, context.hasPresenceChange() {
            context.dropPresenceChange()
            if !self.presenceDropWarned {
                self.presenceDropWarned = true
                Logger.warning("[Document] \"\(self.key)\" was attached with disablePresence=true; presence updates from Document.update are silently dropped.")
            }
        }

        self.clone?.presences[actorID] = presence.presence

        let schemaRules = self.getSchemaRules()
        if !context.isPresenceOnlyChange, !schemaRules.isEmpty {
            let result = RulesetValidator.validateYorkieRuleset(
                data: self.clone?.root.object,
                ruleset: schemaRules
            )
            if !result.valid {
                self.clone = nil
                throw YorkieError(
                    code: .errDocumentSchemaValidationFailed,
                    message: "schema validation failed: \(result.errors.map { $0.message }.joined(separator: ", "))"
                )
            }
        }

        let size = self.getClone()?.root.getDocSize().totalDocSize ?? 0
        if !context.isPresenceOnlyChange, self.maxSizeLimit > 0, self.maxSizeLimit < size {
            self.clone = nil
            throw YorkieError(code: .errDocumentSizeExceedsLimit, message: "document size exceeded: \(size) > \(self.maxSizeLimit)")
        }

        // 02. Update the root object and presences from changes.
        if context.hasChange {
            Logger.trace("trying to update a local change: \(self.toJSON())")

            let prev = PrevPresenceState(
                hadPresence: self.presences[actorID] != nil,
                wasOnline: self.status == .attached,
                presence: self.presences[actorID]?.mapValues { $0.toJSONObject }
            )

            let change = context.toChange()
            let executionResult = try? change.execute(root: self.root, presences: &self.presences)
            let opInfos = executionResult?.opInfos ?? []

            // NOTE: in update(Set on array), the element is replaced with a new value.
            // The history stack may still reference the old element's createdAt, so reconcile.
            for op in change.operations {
                if let arraySet = op as? ArraySetOperation {
                    self.internalHistory.reconcileCreatedAt(
                        prevCreatedAt: arraySet.getCreatedAt(),
                        currCreatedAt: arraySet.getValue().createdAt
                    )
                }
            }

            self.localChanges.append(change)
            self.onLocalChange?()
            if let reverseOps = executionResult?.reverseOps, !reverseOps.isEmpty {
                self.internalHistory.pushUndo(reverseOps)
            }
            // NOTE: clear redo when a new local operation is applied.
            if !opInfos.isEmpty {
                self.internalHistory.clearRedo()
            }
            self.changeID = context.getNextID()

            // 03. Publish the document change event.
            // NOTE(chacha912): Check opInfos, which represent the actually executed operations.
            if !opInfos.isEmpty {
                let changeInfo = ChangeInfo(message: change.message ?? "",
                                            operations: opInfos,
                                            actorID: actorID,
                                            clientSeq: change.id.getClientSeq(),
                                            serverSeq: change.id.getServerSeq())
                let changeEvent = LocalChangeEvent(value: changeInfo)
                self.publish(changeEvent)
            }

            if change.presenceChange != nil {
                if let presenceEvent = self.reconcilePresence(actorID: actorID, prev: prev, source: .local) {
                    self.publish(presenceEvent)
                }
            }

            Logger.trace("after update a local change: \(self.toJSON())")
        }
    }

    /**
     * `canUndo` returns whether there are any operations to undo.
     */
    public var canUndo: Bool {
        self.internalHistory.hasUndo && !self.isUpdating
    }

    /**
     * `canRedo` returns whether there are any operations to redo.
     */
    public var canRedo: Bool {
        self.internalHistory.hasRedo && !self.isUpdating
    }

    /**
     * `undo` undoes the last change made to the document by the local client.
     */
    public func undo() throws {
        try self.executeUndoRedo(isUndo: true)
    }

    /**
     * `redo` redoes the last undone change made to the document by the local client.
     */
    public func redo() throws {
        try self.executeUndoRedo(isUndo: false)
    }

    /**
     * `getUndoStackForTest` returns the undo stack for testing.
     */
    func getUndoStackForTest() -> [[HistoryOperation]] {
        self.internalHistory.getUndoStackForTest()
    }

    /**
     * `getRedoStackForTest` returns the redo stack for testing.
     */
    func getRedoStackForTest() -> [[HistoryOperation]] {
        self.internalHistory.getRedoStackForTest()
    }

    /**
     * `pushUndoForTest` pushes operations onto the undo stack for testing.
     */
    func pushUndoForTest(_ ops: [HistoryOperation]) {
        self.internalHistory.pushUndo(ops)
    }

    /**
     * `clearHistory` flushes the undo and redo stacks.
     *
     * Used internally when a snapshot replaces local state, and exposed so callers can drop
     * one-time setup changes (e.g. initial document scaffolding) from the undo history.
     */
    public func clearHistory() {
        self.internalHistory.clearRedo()
        self.internalHistory.clearUndo()
    }

    /**
     * `executeUndoRedo` executes an undo or redo with the shared logic.
     */
    private func executeUndoRedo(isUndo: Bool) throws {
        if self.isUpdating {
            throw YorkieError(code: .errRefused, message: "\(isUndo ? "Undo" : "Redo") is not allowed during an update")
        }

        // NOTE: The refusal above must not drop the clone: an updater is holding
        // a proxy over it, and `update` reads it again after the updater returns.
        do {
            try self.executeUndoRedoInternal(isUndo: isUndo)
        } catch {
            // A partially executed undo/redo leaves the clone ahead of the root;
            // drop it so the next access rebuilds it from the root.
            self.clone = nil
            throw error
        }
    }

    /**
     * `executeUndoRedoInternal` pops the history entry and applies it to the
     * clone and the root.
     */
    private func executeUndoRedoInternal(isUndo: Bool) throws {
        guard let ops = isUndo ? self.internalHistory.popUndo() : self.internalHistory.popRedo() else {
            return
        }

        guard let actorID = self.actorID else {
            throw YorkieError(code: .errUnexpected, message: "actor ID is null.")
        }

        let clone = self.cloned
        let context = ChangeContext(prevID: self.changeID, root: clone.root)

        // Apply the reverse operations into the context to generate a change.
        for historyOp in ops {
            // NOTE: presence reverse ops are not yet supported (deferred).
            guard case .operation(var op) = historyOp else {
                continue
            }

            let ticket = context.issueTimeTicket
            op.executedAt = ticket

            // A Set/Add/ArraySet reverse carries a deepcopy of the value it
            // restores, and that copy keeps the split-sibling links of the
            // tree it was taken from. Every other replica decodes this same
            // operation through `dropSplitLinksInElement`, so without this
            // the replica that ran the undo is the only one left holding the
            // links, and the two disagree from the next same-boundary split
            // on.
            if let setOp = op as? SetOperation {
                dropSplitLinksInElement(setOp.value)
            } else if let addOp = op as? AddOperation {
                dropSplitLinksInElement(addOp.value)
            } else if let arraySetOp = op as? ArraySetOperation {
                dropSplitLinksInElement(arraySetOp.getValue())
            }

            // NOTE: in undo/redo, both ArraySet and Add may act as updates that restore an
            // element, which receives a new createdAt. Reconcile the history accordingly.
            if let arraySet = op as? ArraySetOperation {
                let prev = arraySet.getCreatedAt()
                arraySet.getValue().setCreatedAt(ticket)
                self.internalHistory.reconcileCreatedAt(prevCreatedAt: prev, currCreatedAt: ticket)
            } else if let add = op as? AddOperation {
                let prev = add.value.createdAt
                add.value.setCreatedAt(ticket)
                self.internalHistory.reconcileCreatedAt(prevCreatedAt: prev, currCreatedAt: ticket)
            } else if let treeEdit = op as? TreeEditOperation {
                // A reverse that re-inserts a copy of removed nodes carries their original ids;
                // inserting them again would leave two nodes under one id. Restore-mode reverses
                // revive by identity and keep theirs.
                try treeEdit.reissueContentIDs { context.issueTimeTicket }

                // A split reverse — the undo of a merge, or the redo of a split — mints one
                // element per split level, and each needs a ticket this loop does not otherwise
                // issue: `op.executedAt` above is exactly one ticket per operation. Left without
                // them, `TreeEditOperation.execute` falls back to reconstructing them by counting
                // delimiters up from its own `executedAt`, which runs straight over the ticket the
                // NEXT operation in this same entry is about to be issued on the next loop
                // iteration — landing two LIVE elements under one id, on every replica and on the
                // server, since the change carries both operations. Issuing and recording them
                // here, before the loop moves on, is what stops any replica reconstructing them.
                //
                // One per level is an upper bound, not an exact count: the split stops early when
                // it reaches the root. A ticket nobody consumes only advances the delimiter, while
                // one short would silently reopen the fallback. Mirrors yorkie's `executeUndoRedo`.
                let level = treeEdit.splitLevel
                if level > 0 {
                    treeEdit.setSplitTickets((0 ..< level).map { _ in context.issueTimeTicket })
                }
            }

            context.push(operation: op)
        }

        let change = context.toChange()
        // Execute on the clone first, then on the real root.
        try change.execute(root: clone.root, presences: &self.clone!.presences, source: .undoRedo)
        let executionResult = try change.execute(root: self.root, presences: &self.presences, source: .undoRedo)
        let opInfos = executionResult.opInfos
        let executedOperations = executionResult.operations
        let reverseOps = executionResult.reverseOps

        if !reverseOps.isEmpty {
            if isUndo {
                self.internalHistory.pushRedo(reverseOps)
            } else {
                self.internalHistory.pushUndo(reverseOps)
            }
        }

        // NOTE: skip propagating the change when nothing was applied.
        //
        // The test is whether an operation RAN, not whether it produced an
        // `OperationInfo`. Those differ: a style may change CRDT state without
        // anything an editor could render, because `canStyle` admits a node
        // another client removed concurrently and a tombstone has no index to
        // report. Gating on `opInfos` dropped such a reverse style -- it mutated
        // this replica and never reached the others. `Change.execute` omits an
        // operation whose target was removed while the undo was pending, so that
        // case is still gated out.
        if change.presenceChange == nil, executedOperations.isEmpty {
            return
        }

        self.localChanges.append(change)
        self.changeID = context.getNextID()
        // After the change id advances, so a persist driven off this hook cannot serialize a
        // document whose pending change is present but whose id has not moved. Ordering rather
        // than a fix: `Document` is main-actor isolated and this method is synchronous, so the
        // task the hook starts cannot run until it returns. Not worth depending on.
        self.onLocalChange?()

        // Gated on the operations that RAN, not on the `OpInfo`s they
        // produced, for the same reason as the skip above: an undo can run
        // and show nothing (a reverse style on a node a peer removed, a Tree
        // restore whose nodes all land under a removed ancestor), and the
        // change is still queued above and still consumes a `clientSeq`. The
        // event still has to reach subscribers -- an editor binding that
        // counts changes, or offline persistence reading `localChanges` --
        // even when there is nothing in it to render.
        if !executedOperations.isEmpty {
            let changeInfo = ChangeInfo(message: change.message ?? "",
                                        operations: opInfos,
                                        actorID: actorID,
                                        clientSeq: change.id.getClientSeq(),
                                        serverSeq: change.id.getServerSeq())
            self.publish(LocalChangeEvent(value: changeInfo))
        }
    }

    /**
     * `subscribe` registers a callback to subscribe to events on the document.
     * The callback will be called when the targetPath or any of its nested values change.
     */
    public func subscribe(_ targetPath: String? = nil, _ callback: @escaping SubscribeCallback) {
        if let targetPath {
            self.subscribeCallbacks[targetPath] = callback
        } else {
            self.defaultSubscribeCallback = callback
        }
    }

    /**
     * `subscribePresence` registers a callback to subscribe to events on the document.
     * The callback will be called when the targetPath or any of its nested values change.
     */
    public func subscribePresence(_ type: PresenceSubscriptionType = .presence, _ callback: @escaping SubscribeCallback) {
        self.presenceSubscribeCallback[type.rawValue] = callback
    }

    /**
     * `subscribeConnection` registers a callback to subscribe to events on the document.
     * The callback will be called when the stream connection status changes.
     */
    public func subscribeConnection(_ callback: @escaping SubscribeCallback) {
        self.connectionSubscribeCallback = callback
    }

    /**
     * `subscribeStatus` registers a callback to subscribe to events on the document.
     * The callback will be called when the document status changes.
     */
    public func subscribeStatus(_ callback: @escaping SubscribeCallback) {
        self.statusSubscribeCallback = callback
    }

    /**
     * `subscribePresence` registers a callback to subscribe to events on the document.
     * The callback will be called when the targetPath or any of its nested values change.
     */
    public func subscribeSync(_ callback: @escaping SubscribeCallback) {
        self.syncSubscribeCallback = callback
    }

    /**
     * `subscribeAuthError` registers a callback to subscribe to events on the document.
     * The callback will be called when the authentification error occurs.
     */
    public func subscribeAuthError(_ callback: @escaping SubscribeCallback) {
        self.authErrorSubscribeCallback = callback
    }

    /**
     * `subscribeEpochMismatch` registers a callback to subscribe to events on the document.
     * The callback will be called when an epoch mismatch error occurs (the document was compacted
     * on the server); the client must detach and reattach the document to recover.
     */
    public func subscribeEpochMismatch(_ callback: @escaping SubscribeCallback) {
        self.epochMismatchSubscribeCallback = callback
    }

    /**
     * `unsubscribe` unregisters a callback to subscribe to events on the document.
     */
    public func unsubscribe(_ targetPath: String? = nil) {
        if let targetPath {
            self.subscribeCallbacks[targetPath] = nil
        } else {
            self.defaultSubscribeCallback = nil
        }
    }

    /**
     * `unsubscribePresence` unregisters a callback to subscribe to events on the document.
     */
    public func unsubscribePresence(_ type: PresenceSubscriptionType = .presence) {
        self.presenceSubscribeCallback.removeValue(forKey: type.rawValue)
    }

    /**
     * `unsubscribeConnection` unregisters a callback to subscribe to events on the document.
     */
    public func unsubscribeConnection() {
        self.connectionSubscribeCallback = nil
    }

    /**
     * `unsubscribeSync` unregisters a callback to subscribe to events on the document.
     */
    public func unsubscribeSync() {
        self.syncSubscribeCallback = nil
    }

    /**
     * `unsubscribeAuthError` unregisters a callback to subscribe to events on the document.
     */
    public func unsubscribeAuthError() {
        self.authErrorSubscribeCallback = nil
    }

    /**
     * `unsubscribeEpochMismatch` unregisters the epoch-mismatch callback.
     */
    public func unsubscribeEpochMismatch() {
        self.epochMismatchSubscribeCallback = nil
    }

    /**
     * `applyChangePack` applies the given change pack into this document.
     * 1. Remove local changes applied to server.
     * 2. Update the checkpoint.
     * 3. Do Garbage collection.
     *
     * - Parameter pack: change pack
     */
    func applyChangePack(_ pack: ChangePack) throws {
        let hasSnapshot = pack.hasSnapshot()
        let clientSeq = Int64(pack.getCheckpoint().getClientSeq())

        // 01. Apply snapshot or changes to the root object.
        //
        // NOTE(yorkie-js-sdk#1403): the checkpoint below is only reached once this succeeds,
        // so a throw here leaves it where it was and the server redelivers this same pack on
        // every sync. Log that once, naming the checkpoint the document is stuck at, before
        // letting the error out -- otherwise the only signal is a sync that never makes
        // progress. This runs at the default log level and repeats on every redelivery, so
        // everything it interpolates must be metadata: the key, the checkpoint, and an error
        // that (per `Change.execute` / `applyChange`) names the change and the operation by
        // type and ticket only -- never an operation's payload.
        do {
            if hasSnapshot, let snapshot = pack.getSnapshot(), let versionVector = pack.getVersionVector() {
                try self.applySnapshot(pack.getCheckpoint().getServerSeq(), versionVector, snapshot, clientSeq)
            } else {
                try self.applyChanges(pack.getChanges(), source: .remote)

                // Remove local changes applied to server.
                self.removePushedLocalChanges(clientSeq: clientSeq)
            }
        } catch {
            Logger.error("[Document] \"\(self.key)\" cannot apply the pack at checkpoint \(self.checkpoint.toTestString); " +
                "the server will redeliver it until this is resolved: \(error)")
            throw error
        }

        // 02. Update the checkpoint.
        self.checkpoint.forward(other: pack.getCheckpoint())

        // 02-1. Learn the document's current compaction epoch from the server so a
        // subsequent attach/sync (and any persisted envelope) presents it back.
        self.epoch = pack.getEpoch()

        // 03. Do Garbage collection.
        if !hasSnapshot, let versionVector = pack.getVersionVector() {
            self.garbageCollect(minSyncedVersionVector: versionVector)
        }

        // 06. Update the status.
        if pack.isRemoved {
            self.applyStatus(.removed)
        }

        Logger.trace("\(self.root.toJSON())")
    }

    /**
     * `acknowledgePushedChanges` removes the local changes the server has confirmed, and
     * forwards only the client seq of the checkpoint. It is for a response pack dropped
     * without applying its remote state: the server seq must stay put so the skipped state
     * is pulled again later, while the confirmed changes must not be pushed again. The
     * server dedupes a re-pushed change when storing it, but a snapshot it builds for the
     * same request would apply that change a second time.
     *
     * The pack's metadata is not remote state, and is taken in full: the compaction epoch
     * and the removal flag describe the document itself, not the content being skipped, and
     * neither is re-sent by a later pull the way the skipped changes are.
     *
     * - Parameter pack: The change pack whose remote state (changes or snapshot) was dropped.
     */
    func acknowledgePushedChanges(_ pack: ChangePack) {
        let clientSeq = pack.getCheckpoint().getClientSeq()
        self.removePushedLocalChanges(clientSeq: Int64(clientSeq))
        self.checkpoint.forward(other: Checkpoint(serverSeq: self.checkpoint.getServerSeq(), clientSeq: clientSeq))

        // Dropping the epoch would leave the client presenting a superseded one on the next
        // request, which the server answers with an epoch mismatch -- a re-anchor that
        // discards exactly the un-pushed edits push-only mode exists to keep. A compaction is
        // also the shape that arrives as a snapshot, i.e. precisely the pack this path drops.
        self.epoch = pack.getEpoch()

        // A removal is terminal: there is no later pull to learn it from, because the server
        // row is gone. Skipping it leaves the document attached and its persisted envelope
        // pointing at a row that no longer exists.
        if pack.isRemoved {
            self.applyStatus(.removed)
        }
    }

    /**
     * `hasLocalChanges` returns whether this document has local changes or not.
     *
     */
    public func hasLocalChanges() async -> Bool {
        return self.localChanges.isEmpty == false
    }

    /**
     * `ensureClone` make a clone of root.
     */
    var cloned: (root: CRDTRoot, presences: [ActorID: PresenceData]) {
        if let clone = self.clone {
            return clone
        }

        self.clone = (self.root.deepcopy(), self.presences)

        return self.clone!
    }

    /**
     * `createChangePack` create change pack of the local changes to send to the
     * remote server.
     *
     */
    func createChangePack(_ forceToRemoved: Bool = false) -> ChangePack {
        let changes = self.localChanges
        let checkpoint = self.checkpoint.increasedClientSeq(by: UInt32(changes.count))
        return ChangePack(key: self.key,
                          checkpoint: checkpoint,
                          isRemoved: forceToRemoved ? true : self.status == .removed,
                          changes: changes,
                          versionVector: self.getVersionVector(),
                          epoch: self.epoch)
    }

    /**
     * `setActor` sets actor into this document. This is also applied in the local
     * changes the document has.
     *
     */
    public func setActor(_ actorID: ActorID) {
        let changes = self.localChanges.map {
            var new = $0
            new.setActor(actorID)
            return new
        }

        self.localChanges = changes

        self.changeID = self.changeID.setActor(actorID)

        // TODOs also apply into root.
    }

    var actorID: ActorID? {
        self.changeID.getActorID()
    }

    /**
     * `getKey` returns the key of this document.
     *
     */
    public nonisolated func getKey() -> String {
        return self.key
    }

    /// Returns the document's last-known compaction epoch.
    ///
    /// - Returns: The compaction epoch this document was last synced under.
    public func getEpoch() -> Int64 {
        return self.epoch
    }

    /// Returns the server-assigned document id recorded on attach.
    ///
    /// - Returns: The document id, or an empty string before the first attach (or for a
    ///   restored envelope that predates docID persistence).
    public func getDocID() -> DocumentID {
        return self.docID
    }

    /// Records the server-assigned document id so the next ``toBytes()`` envelope
    /// carries it for the silent-purge guard in ``restoreFromBytes(_:)``.
    ///
    /// - Parameter docID: The document id returned by the server on attach.
    public func setDocID(_ docID: DocumentID) {
        self.docID = docID
    }

    /**
     * `getStatus` returns the status of this document.
     */
    public func getStatus() -> ResourceStatus {
        switch self.status {
        case .detached:
            return .detached
        case .attached:
            return .attached
        case .removed:
            return .removed
        }
    }

    /**
     * `getCloneRoot` return clone object.
     */
    func getCloneRoot() -> CRDTObject? {
        return self.clone?.root.object
    }

    /**
     * `getRoot` returns a new proxy of cloned root.
     */
    public func getRoot() -> JSONObject {
        let clone = self.cloned
        let context = ChangeContext(prevID: self.changeID.next(), root: clone.root)

        return JSONObject(target: clone.root.object, context: context)
    }

    /**
     * `getDocSize` returns the size of this document.
     */
    public func getDocSize() -> DocSize {
        self.root.getDocSize()
    }

    /**
     * `getMaxSizePerDocument` gets the maximum size of this document.
     */
    public func getMaxSizePerDocument() -> Int {
        return self.maxSizeLimit
    }

    /**
     * `setMaxSizePerDocument` sets the maximum size of this document.
     */
    public func setMaxSizePerDocument(_ size: Int) {
        self.maxSizeLimit = size
    }

    /// Gets the schema rules of this document.
    func getSchemaRules() -> [Rule] {
        return self.schemaRules
    }

    /// Sets the schema rules of this document.
    func setSchemaRules(_ rules: [Rule]) {
        self.schemaRules = rules
    }

    /**
     * `setDisableGC` records whether this document should use the lamport-only
     * sync path in `applyChanges`. The client calls this on attach. This is
     * distinct from `optionDisableGC`, which independently gates local
     * `garbageCollect` — setting this flag does NOT disable garbage collection.
     */
    func setDisableGC(_ disableGC: Bool) {
        self.disableGC = disableGC
    }

    /**
     * `setDisablePresence` records the server-fixated presence-disabled state of
     * this document. The client calls this on attach (before `applyChangePack`)
     * so any subsequent ``update(_:_:)`` invocation sees the gating state already
     * settled. Flipping the flag at runtime is supported: the next `update`
     * honours the new value.
     */
    func setDisablePresence(_ disablePresence: Bool) {
        self.disablePresence = disablePresence
    }

    /**
     * `isPresenceDisabled` returns whether this document was attached
     * presenceless (see ``DocumentOptions/disablePresence``).
     */
    func isPresenceDisabled() -> Bool {
        return self.disablePresence
    }

    /**
     * `garbageCollect` purges elements that were removed before the given time.
     *
     */
    @discardableResult
    func garbageCollect(minSyncedVersionVector: VersionVector) -> Int {
        if self.optionDisableGC {
            return 0
        }

        if let clone = self.clone {
            clone.root.garbageCollect(minSyncedVersionVector: minSyncedVersionVector)
        }
        return self.root.garbageCollect(minSyncedVersionVector: minSyncedVersionVector)
    }

    /**
     * `getRootObject` returns root object.
     *
     */
    func getRootObject() -> CRDTObject {
        return self.root.object
    }

    /**
     * `getGarbageLength` returns the length of elements should be purged.
     *
     */
    func getGarbageLength() -> Int {
        return self.root.garbageLength
    }

    /**
     * `getGarbageLengthFromClone` returns the length of elements should be purged from clone.
     */
    func getGarbageLengthFromClone() -> Int {
        return self.clone?.root.garbageLength ?? 0
    }

    /**
     * `toJSON` returns the JSON encoding of this array.
     */
    public func toJSON() -> String {
        return self.root.toJSON()
    }

    /**
     * `toSortedJSON` returns the sorted JSON encoding of this array.
     */
    public func toSortedJSON() -> String {
        return self.root.toSortedJSON()
    }

    /*
     * `getStats` returns the statistics of this document.
     */
    public func getStats() -> RootStats {
        return self.root.getStats()
    }

    /**
     * `isEnableDevtools` returns whether the devtools recorder is enabled for
     * this document.
     */
    public func isEnableDevtools() -> Bool {
        return self.enableDevtools
    }

    /**
     * `dumpDevtools` returns the recorded devtools event log encoded as JSON in
     * the yorkie-js-sdk devtools format.
     *
     * The result is `Array<DocEventsForReplay>`, directly comparable against a
     * JS recording of the same session. Returns `nil` when devtools is disabled
     * or no events have been recorded yet.
     *
     * - Parameter pretty: Pretty-prints with sorted keys when `true`.
     */
    public func dumpDevtools(pretty: Bool = true) -> Data? {
        return self.devtoolsRecorder?.exportJSON(pretty: pretty)
    }

    /**
     * `attachDevtoolsRecorder` eagerly creates the devtools recorder (if not
     * already present) and returns it, so an inspector UI can observe events
     * live via ``DevtoolsRecorder/addObserver(_:)``.
     *
     * - Returns: The recorder, or `nil` when devtools is disabled for this
     *   document.
     */
    @discardableResult
    public func attachDevtoolsRecorder() -> DevtoolsRecorder? {
        guard self.enableDevtools else {
            return nil
        }
        if self.devtoolsRecorder == nil {
            self.devtoolsRecorder = DevtoolsRecorder(docKey: self.key)
        }
        return self.devtoolsRecorder
    }

    /**
     * `exportDevtools` writes the recorded devtools event log to `url` as JSON.
     *
     * - Parameter url: The destination file URL.
     * - Throws: A ``YorkieError`` when devtools is disabled, plus any error
     *   raised while serialising or writing.
     */
    public func exportDevtools(to url: URL) throws {
        guard let recorder = self.devtoolsRecorder else {
            throw YorkieError(code: .errNotReady, message: "Devtools is not enabled or has not recorded any events for \(self.key).")
        }
        try recorder.export(to: url)
    }

    /**
     * `getClone` returns this clone.
     */
    func getClone() -> (root: CRDTRoot, presences: [ActorID: StringValueTypeDictionary])? {
        return self.clone
    }

    /**
     * `applySnapshot` applies the given snapshot into this document.
     */
    public func applySnapshot(_ serverSeq: Int64,
                              _ snapshotVector: VersionVector,
                              _ snapshot: Data,
                              _ clientSeq: Int64 = -1) throws
    {
        let (root, presences) = try Converter.bytesToSnapshot(bytes: snapshot)
        self.root = CRDTRoot(rootObject: root)
        self.presences = presences
        self.changeID = self.changeID.setClocks(
            with: snapshotVector.maxLamport(),
            vector: snapshotVector
        )

        // drop clone because it is contaminated.
        self.clone = nil

        self.removePushedLocalChanges(clientSeq: clientSeq)

        // NOTE(hackerwins): If the document has local changes, we need to apply
        // them after applying the snapshot, as local changes are not included in the snapshot data.
        // Afterward, we should publish a snapshot event with the latest
        // version of the document to ensure the user receives the most up-to-date snapshot.
        try self.applyChanges(self.localChanges, source: .local)
        self.clearHistory()

        let hexSnapshotVector = try Converter.versionVectorToHex(vector: snapshotVector)
        let snapshotInfo = SnapshotInfo(serverSeq: serverSeq,
                                        snapshot: snapshot,
                                        snapshotVector: hexSnapshotVector)
        let snapshotEvent = SnapshotEvent(value: snapshotInfo)
        self.publish(snapshotEvent)
    }

    /**
     * `applyChanges` applies the given changes into this document.
     */
    public func applyChanges(_ changes: [Change], source: OpSource) throws {
        Logger.debug(
            """
            trying to apply \(changes.count) \(source) changes.
            elements:\(self.root.elementMapSize),
            removeds:\(self.root.garbageElementSetSize)
            """)

        Logger.trace(changes.map { "\($0.id.toTestString)\t\($0.toTestString)" }.joined(separator: "\n"))

        for change in changes {
            try self.applyChange(change, source: source)
        }

        Logger.debug(
            """
            after appling \(changes.count) \(source) changes.
            elements:\(self.root.elementMapSize),
            removeds:\(self.root.garbageElementSetSize)
            """
        )
    }

    /**
     * `applyChange` applies the given change into this document.
     */
    private func applyChange(_ change: Change, source: OpSource) throws {
        do {
            try self.applyChangeInternal(change, source: source)
        } catch {
            // NOTE: `Change.execute` does not roll back, so a change that fails
            // partway leaves the clone and the root holding different prefixes of
            // it. Drop the clone so the next access rebuilds it from the root, the
            // way `update` does on failure.
            self.clone = nil

            // NOTE(yorkie-js-sdk#1403): only a remote change is named -- see
            // `Change.execute`'s matching gate. The document key is only known here, so it
            // is added as the error passes through: an already-named `errChangeApplyFailed`
            // (naming the operation) gets the key folded into its message, and any other
            // failure on this path (e.g. a precondition unrelated to a single operation) is
            // named fresh with the change id and the document key.
            guard source == .remote else {
                throw error
            }

            if let yorkieError = error as? YorkieError, yorkieError.code == .errChangeApplyFailed {
                throw YorkieError(code: .errChangeApplyFailed, message: "document \"\(self.key)\" \(yorkieError.message)")
            }

            throw YorkieError(
                code: .errChangeApplyFailed,
                message: "document \"\(self.key)\" failed to apply change \(change.id.toTestString): \(error)"
            )
        }
    }

    /**
     * `applyChangeInternal` applies the given change into the clone and the root.
     */
    private func applyChangeInternal(_ change: Change, source: OpSource) throws {
        let clone = self.cloned
        try change.execute(root: clone.root, presences: &self.clone!.presences, source: source)

        var changeInfo: ChangeInfo?

        guard let actorID = change.id.getActorID() else {
            throw YorkieError(code: .errUnexpected, message: "ActorID is null")
        }

        // Capture prev state before execute updates this.presences.
        let prev: PrevPresenceState? = change.presenceChange != nil ? PrevPresenceState(
            hadPresence: self.presences[actorID] != nil,
            wasOnline: self.onlineClients.contains(actorID),
            presence: self.presences[actorID]?.mapValues { $0.toJSONObject }
        ) : nil

        let executionResult = try change.execute(root: self.root, presences: &self.presences, source: source)
        let opInfos = executionResult.opInfos

        // NOTE: when a text edit is applied, reconcile the ranges of any edit operations
        // sitting on the undo/redo stacks so later undo/redo lands at the correct position.
        for op in executionResult.operations {
            if let edit = op as? EditOperation {
                let (from, to) = try edit.normalizePos(self.root)
                self.internalHistory.reconcileTextEdit(
                    parentCreatedAt: edit.parentCreatedAt,
                    rangeFrom: from,
                    rangeTo: to,
                    contentLength: (edit.content as NSString).length
                )
            }
            if let treeEdit = op as? TreeEditOperation {
                // One reconciliation per range the op actually changed, in the
                // order it changed them: an identity-preserving
                // restore/retombstone revives or re-removes several nodes at
                // positions its stored indices never describe, and each
                // measurement is relative to the one before it.
                for (from, to, contentSize) in treeEdit.getExecutedRanges() {
                    self.internalHistory.reconcileTreeEdit(
                        parentCreatedAt: treeEdit.parentCreatedAt,
                        rangeFrom: from,
                        rangeTo: to,
                        contentSize: contentSize
                    )
                }
            }
        }

        // Opt-out (disableGC) documents advance only the lamport clock and do
        // not merge remote actors' version vectors, keeping each subsequent
        // local Change's VV at O(1). See ``setDisableGC(_:)``.
        self.changeID = self.disableGC
            ? self.changeID.syncLamport(with: change.id)
            : self.changeID.syncClocks(with: change.id)

        if change.hasOperations {
            changeInfo = ChangeInfo(message: change.message ?? "",
                                    operations: opInfos,
                                    actorID: actorID,
                                    clientSeq: change.id.getClientSeq(),
                                    serverSeq: change.id.getServerSeq())
        }

        // DocEvent should be emitted synchronously with applying changes.
        // This is because 3rd party model should be synced with the Document
        // after RemoteChange event is emitted. If the event is emitted
        // asynchronously, the model can be changed and breaking consistency.
        if let info = changeInfo {
            let remoteChangeEvent = RemoteChangeEvent(value: info)
            self.publish(remoteChangeEvent)
        }

        if let prev, change.presenceChange != nil {
            // Remove the client from onlineClients when presence is cleared,
            // mirroring the JS handling of PresenceChangeType.Clear.
            if case .clear = change.presenceChange {
                self.removeOnlineClient(actorID)
            }
            if let presenceEvent = self.reconcilePresence(actorID: actorID, prev: prev, source: source) {
                self.publish(presenceEvent)
            }
        }
    }

    /**
     * `getValueByPath` returns the JSONElement corresponding to the given path.
     */
    public func getValueByPath(_ path: String) throws -> Any? {
        guard path.starts(with: JSONObject.rootKey) else {
            throw YorkieError(code: .errInvalidArgument, message: "The path must start with \(JSONObject.rootKey)")
        }

        let rootObject = self.getRoot()

        if path == JSONObject.rootKey {
            return rootObject
        }

        var subPath = path
        subPath.removeFirst(JSONObject.rootKey.count) // remove root path("$")

        let keySeparator = JSONObject.keySeparator

        guard subPath.starts(with: keySeparator) else {
            throw YorkieError(code: .errUnexpected, message: "Invalid path.")
        }

        subPath.removeFirst(keySeparator.count)

        return rootObject.get(keyPath: subPath)
    }

    /**
     * `applyStatus` applies the document status into this document.
     */
    func applyStatus(_ status: DocStatus) {
        guard let actorID = self.actorID else { return }

        let prev = PrevPresenceState(
            hadPresence: self.presences[actorID] != nil,
            wasOnline: self.status == .attached,
            presence: self.presences[actorID]?.mapValues { $0.toJSONObject }
        )

        self.status = status

        if status == .detached {
            self.setActor(ActorIDs.initial)
        }

        if let presenceEvent = self.reconcilePresence(actorID: actorID, prev: prev, source: .local) {
            self.publish(presenceEvent)
        }

        let statusEvent = StatusChangedEvent(source: status == .removed ? .remote : .local,
                                             value: StatusInfo(status: status, actorID: status == .attached ? self.actorID : nil))
        self.publish(statusEvent)
    }

    public nonisolated var debugDescription: String {
        "[\(self.key)]"
    }

    func publishPresenceEvent(_ eventType: DocEventType, _ peerActorID: ActorID? = nil, _ presence: [String: Any]? = nil) {
        switch eventType {
        case .initialized:
            self.publish(InitializedEvent(value: self.getPresences()))
        case .watched:
            if let peerActorID, let presence = presence {
                self.publish(WatchedEvent(value: (peerActorID, presence)))
            }
        case .unwatched:
            if let peerActorID, let presence = presence {
                self.publish(UnwatchedEvent(value: (peerActorID, presence)))
            }
        default:
            assertionFailure("Not presence Event type. \(eventType)")
        }
    }

    func publishConnectionEvent(_ status: StreamConnectionStatus) {
        self.publish(ConnectionChangedEvent(value: status))
    }

    func publishSyncEvent(_ status: DocSyncStatus) {
        self.publish(SyncStatusChangedEvent(value: status))
    }

    func publishInitializedEvent() {
        self.publish(InitializedEvent(value: self.getPresences()))
    }

    func publishAuthErrorEvent(reason: String, method: AuthErrorValue.Method) {
        let authErrorEvent = AuthErrorEvent(value: AuthErrorValue(reason: reason, method: method))
        self.publish(authErrorEvent)
    }

    /// Invoked after a local change is appended, when offline persistence is enabled.
    ///
    /// Separate from ``subscribe(_:_:)`` deliberately: that is a single-slot, app-facing
    /// callback, and the client registering there would displace the app's own subscription.
    var onLocalChange: (() -> Void)?

    func publishEpochMismatchEvent(method: String) {
        self.publish(EpochMismatchEvent(value: EpochMismatchValue(method: method)))
    }

    /// Publishes the changes an offline resume had to discard.
    ///
    /// - Parameters:
    ///   - reason: Why the changes could not be reconciled with the server.
    ///   - changes: The discarded changes, in the order they were made.
    func publishLocalChangesDroppedEvent(reason: LocalChangesDroppedValue.Reason, changes: [Change]) {
        let dropped = changes.map { DroppedChange($0) }
        self.publish(LocalChangesDroppedEvent(value: LocalChangesDroppedValue(reason: reason, changes: dropped)))
    }

    /**
     * `publish` triggers an event in this document, which can be received by
     * callback functions from document.subscribe().
     */
    /// Forwards an event to the devtools recorder, lazily creating it when
    /// devtools is enabled. Kept separate from ``publish(_:)`` so it does not
    /// add to that method's cyclomatic complexity.
    private func recordForDevtools(_ event: DocEvent) {
        guard self.enableDevtools else {
            return
        }
        if self.devtoolsRecorder == nil {
            self.devtoolsRecorder = DevtoolsRecorder(docKey: self.key)
        }
        self.devtoolsRecorder?.record(event)
    }

    func publish(_ event: DocEvent) {
        self.recordForDevtools(event)

        let presenceEvents: [DocEventType] = [.initialized, .watched, .unwatched, .presenceChanged]

        if presenceEvents.contains(event.type) {
            if let callback = self.presenceSubscribeCallback[PresenceSubscriptionType.presence.rawValue] {
                callback(event, self)
            }

            if let id = self.actorID {
                var isMine = false
                var isOthers = false

                if event is InitializedEvent {
                    isMine = true
                } else if event is WatchedEvent {
                    isOthers = true
                } else if event is UnwatchedEvent {
                    isOthers = true
                } else if let event = event as? PresenceChangedEvent {
                    if event.value.clientID == id {
                        isMine = true
                    } else {
                        isOthers = true
                    }
                }

                if isMine {
                    if let callback = self.presenceSubscribeCallback[PresenceSubscriptionType.myPresence.rawValue] {
                        callback(event, self)
                    }
                }

                if isOthers {
                    if let callback = self.presenceSubscribeCallback[PresenceSubscriptionType.others.rawValue] {
                        callback(event, self)
                    }
                }
            }
        } else if event.type == .connectionChanged {
            self.connectionSubscribeCallback?(event, self)
        } else if event.type == .statusChanged {
            self.statusSubscribeCallback?(event, self)
        } else if event.type == .syncStatusChanged {
            self.syncSubscribeCallback?(event, self)
        } else if event.type == .snapshot {
            self.subscribeCallbacks["$"]?(event, self)
        } else if let authErrorEvent = event as? AuthErrorEvent {
            self.authErrorSubscribeCallback?(authErrorEvent, self)
        } else if let epochMismatchEvent = event as? EpochMismatchEvent {
            self.epochMismatchSubscribeCallback?(epochMismatchEvent, self)
        } else if let event = event as? ChangeEvent {
            var operations = [String: [any OperationInfo]]()

            for operationInfo in event.value.operations {
                for targetPath in self.subscribeCallbacks.keys where self.isSameElementOrChildOf(operationInfo.path, targetPath) {
                    if operations[targetPath] == nil {
                        operations[targetPath] = [any OperationInfo]()
                    }
                    operations[targetPath]?.append(operationInfo)
                }
            }

            for (key, value) in operations {
                let info = ChangeInfo(message: event.value.message,
                                      operations: value,
                                      actorID: event.value.actorID,
                                      clientSeq: event.value.clientSeq,
                                      serverSeq: event.value.serverSeq)

                if let callback = self.subscribeCallbacks[key], key != "$" {
                    callback(event.type == .localChange ? LocalChangeEvent(value: info) : RemoteChangeEvent(value: info), self)
                }
            }

            self.subscribeCallbacks["$"]?(event, self)
        }

        self.defaultSubscribeCallback?(event, self)
    }

    private func isSameElementOrChildOf(_ elem: String, _ parent: String) -> Bool {
        if parent == elem {
            return true
        }

        let nodePath = elem.components(separatedBy: ".")
        let targetPath = parent.components(separatedBy: ".")

        var result = true

        for (index, path) in targetPath.enumerated() where path != nodePath[safe: index] {
            result = false
        }

        return result
    }

    /**
     * `removePushedLocalChanges` removes local changes that have been applied to
     * the server from the local changes.
     *
     * @param clientSeq - client sequence number to remove local changes before it
     */
    private func removePushedLocalChanges(clientSeq: Int64) {
        while !self.localChanges.isEmpty {
            guard let change = self.localChanges.first, change.id.getClientSeq() <= clientSeq else {
                return
            }
            self.localChanges.removeFirst()
        }
    }

    /**
     * `setOnlineClients` sets the given online client set.
     */
    func setOnlineClients(_ onlineClients: Set<ActorID>) {
        self.onlineClients = onlineClients
    }

    /**
     * `resetOnlineClients` resets the online client set.
     *
     */
    func resetOnlineClients() {
        self.onlineClients = Set<ActorID>()
    }

    /**
     * `addOnlineClient` adds the given clientID into the online client set.
     */
    func addOnlineClient(_ clientID: ActorID) {
        self.onlineClients.insert(clientID)
    }

    /**
     * `removeOnlineClient` removes the clientID from the online client set.
     */
    func removeOnlineClient(_ clientID: ActorID) {
        self.onlineClients.remove(clientID)
    }

    // NOTE: stale presences for clients no longer in the online set are intentionally NOT pruned.
    // The presences map retains them, but `getPresence`/`getPresences`/`getOthersPresences` already
    // filter by `onlineClients`, so stale data is never exposed. Keeping them allows correct
    // recovery when a client's watch stream reconnects: the server sends a `watched` event and,
    // because the old presence is still in the map, the peer becomes visible again instead of being
    // silently dropped.

    /**
     * `removePresence` removes the stored presence of the given client.
     */
    func removePresence(_ clientID: ActorID) {
        self.presences[clientID] = nil
    }

    // MARK: - Presence reconciliation

    /// Snapshot of a client's presence/online state captured before a mutation.
    private struct PrevPresenceState {
        let hadPresence: Bool
        let wasOnline: Bool
        let presence: [String: Any]?
    }

    /// Compares the previous and current presence/online state of a client and returns
    /// the appropriate event to emit, or `nil` when no event is warranted.
    ///
    /// For remote clients "online" means the client is in `onlineClients`.
    /// For self "online" means the document status is `attached`.
    ///
    /// State transition table:
    /// - `(!hadP || !wasOn) → (hasP && isOn)` : `watched` (remote) or `presenceChanged` (self)
    /// - `(hadP && wasOn)   → (hasP && isOn)` : `presenceChanged`
    /// - `(hadP && wasOn)   → (!hasP || !isOn)`: `unwatched` (remote only)
    /// - otherwise: `nil` (waiting for both presence and online to be established)
    private func reconcilePresence(actorID: ActorID, prev: PrevPresenceState, source: OpSource) -> DocEvent? {
        let isSelf = actorID == self.changeID.getActorID()
        let hasPresence = self.presences[actorID] != nil
        let isOnline = isSelf ? self.status == .attached : self.onlineClients.contains(actorID)

        if !hasPresence || !isOnline {
            // Transitioned from ready → not ready: unwatched (remote only).
            if prev.hadPresence, prev.wasOnline, !isSelf {
                let presence = prev.presence ?? [:]
                return UnwatchedEvent(value: (actorID, presence))
            }
            return nil
        }

        let presence = self.presences[actorID]?.mapValues { $0.toJSONObject } ?? [:]

        if !prev.hadPresence || !prev.wasOnline {
            // Transitioned from not-ready → ready.
            if isSelf {
                return PresenceChangedEvent(value: (actorID, presence))
            }
            return WatchedEvent(value: (actorID, presence))
        }

        // Both were ready and still are: presence value changed.
        return PresenceChangedEvent(value: (actorID, presence))
    }

    /**
     * `hasPresence` returns whether the given clientID has a presence or not.
     */
    public func hasPresence(_ clientID: ActorID) -> Bool {
        self.presences[clientID] != nil
    }

    /**
     * `getMyPresence` returns the presence of the current client.
     */
    public func getMyPresence() -> [String: Any]? {
        guard self.status == .attached, let id = self.actorID else {
            return nil
        }

        return self.presences[id]?.mapValues { $0.toJSONObject }
    }

    /// Returns the presences of all other clients (excluding the current client)
    /// - Returns: Array of tuples containing client IDs and their presence information
    public func getOthersPresences() -> [(clientID: ActorID, presence: Any)] {
        var others: [(clientID: ActorID, presence: Any)] = []
        let myClientID = self.changeID.getActorID()

        for clientID in self.onlineClients {
            if clientID != myClientID, self.presences.keys.contains(clientID) {
                guard let preseneces = self.presences[clientID] else { continue }
                others.append((
                    clientID: clientID,
                    presence: preseneces.mapValues { $0.toJSONObject }
                )
                )
            }
        }

        return others
    }

    /**
     * `getPresence` returns the presence of the given clientID.
     */
    public func getPresence(_ clientID: ActorID) -> [String: Any]? {
        if clientID == self.actorID {
            return self.getMyPresence()
        }

        guard self.onlineClients.contains(clientID) else {
            return nil
        }

        return self.presences[clientID]?.mapValues { $0.toJSONObject }
    }

    /**
     * `getPresenceForTest` returns the presence of the given clientID.
     */
    public func getPresenceForTest(_ clientID: ActorID) -> [String: Any]? {
        self.presences[clientID]?.mapValues { $0.toJSONObject }
    }

    /**
     * `setPresenceForTest` injects a stored presence for the given client. Test only.
     */
    func setPresenceForTest(_ clientID: ActorID, _ presence: StringValueTypeDictionary) {
        self.presences[clientID] = presence
    }

    /**
     * `getPresences` returns the presences of online clients.
     */
    public func getPresences(_ excludeMyself: Bool = false) -> [PeerElement] {
        var presences = [PeerElement]()

        if !excludeMyself, let actorID, let presence = getMyPresence() {
            presences.append(PeerElement(actorID, presence))
        }

        for clientID in self.onlineClients {
            if let presence = getPresence(clientID) {
                presences.append((clientID, presence))
            }
        }

        return presences
    }

    /**
     * `getVersionVector` returns the version vector of document
     */
    public func getVersionVector() -> VersionVector {
        return self.changeID.getVersionVector()
    }

    /// Reads the private state ``toBytes()`` needs to serialize, in one pass.
    ///
    /// A bridge for ``Document/Document+Persistence.swift``: `root`, `presences`,
    /// `localChanges` and the `changeID` setter are `private` to this file, so the
    /// persistence extension — kept in its own file to avoid growing this type's body —
    /// reads them through this internal accessor instead of widening their access level.
    ///
    /// - Returns: The root object, presences, checkpoint, change id and pending local
    ///   changes of this document.
    func persistenceSnapshot() -> (
        root: CRDTObject,
        presences: [ActorID: StringValueTypeDictionary],
        checkpoint: Checkpoint,
        changeID: ChangeID,
        localChanges: [Change]
    ) {
        (self.root.object, self.presences, self.checkpoint, self.changeID, self.localChanges)
    }

    /// Moves this document's `clientSeq` counter forward to the given sequence, and never
    /// backward.
    ///
    /// Exists for one caller: the offline-persistence log-discontinuity repair, which has to
    /// undo a persisted header without undoing the counter inside it. ``restoreFromBytes(_:)``
    /// returns checkpoint, epoch and change id to what the snapshot carries, which is right for
    /// a header the appended log cannot back -- except for the counter. A counter is not a
    /// claim about content the way a checkpoint is: it records which `clientSeq` values this
    /// client has already minted, and the server has taken some of them. Rewinding it to the
    /// snapshot's counter mints those sequences a second time; the server skips them as
    /// duplicates and the next ack, whose `clientSeq` covers them, drops them from the pending
    /// queue as pushed. The edits are lost with no event.
    ///
    /// The position to hand over is the acked checkpoint, not the header's counter. The server
    /// validates continuity from the position it holds, so the next change must be its
    /// `clientSeq` plus one; the counter can lead that, and resuming there would mint past the
    /// server and wedge every later push on `ErrInvalidClientSeq`.
    ///
    /// The counter only ever rises, so the guard is the whole contract: a caller that hands over
    /// a stale position cannot pull the document back into reusing sequence numbers.
    ///
    /// - Parameter clientSeq: The sequence to advance to.
    func advanceClientSeqTo(_ clientSeq: UInt32) {
        if clientSeq > self.changeID.getClientSeq() {
            self.changeID = self.changeID.setClientSeq(clientSeq)
        }
    }

    /// Overwrites the clocks a sync advances, leaving the root and pending changes alone.
    ///
    /// The write-side counterpart of ``metaToBytes()``. The snapshot stays put while a sync
    /// advances the header constantly, which is why the two are stored apart.
    ///
    /// - Parameters:
    ///   - checkpoint: The checkpoint as of the last sync.
    ///   - changeID: The change id as of the last sync.
    ///   - epoch: The epoch, when the header carried one.
    ///   - docID: The document id, when the header carried one.
    func applyRestoredMeta(checkpoint: Checkpoint, changeID: ChangeID?, epoch: Int64?, docID: DocumentID?) {
        self.checkpoint = checkpoint
        if let changeID {
            self.changeID = changeID
        }
        // Trailing fields stay optional, the same rule the `toBytes` envelope follows, so
        // meta written before they existed still decodes.
        if let epoch {
            self.epoch = epoch
        }
        if let docID {
            self.docID = docID
        }

        // Drop what the header says the server already has.
        //
        // A sync records the header without rewriting the snapshot, so the snapshot keeps
        // carrying a change the sync went on to acknowledge. `createChangePack` pushes
        // `localChanges` wholesale and derives the pushed checkpoint from their count, so
        // leaving an acked change queued re-presents a `clientSeq` the server has already
        // taken while claiming a checkpoint beyond it.
        //
        // Stricter than `document.ts`, which filters only the appended log against this same
        // watermark and leaves the snapshot's own queue alone. Applying the one rule to both
        // is what keeps the two consistent.
        self.localChanges.removeAll { $0.id.getClientSeq() <= checkpoint.getClientSeq() }
    }

    /// Replays a run of persisted changes onto this document and re-queues the un-acked
    /// ones.
    ///
    /// - Parameters:
    ///   - changes: The appended changes, ascending by `clientSeq`.
    ///   - ackedClientSeq: The `clientSeq` the server has already acknowledged.
    /// - Throws: Whatever ``applyChanges(_:source:)`` throws.
    func appendRestoredChanges(_ changes: [Change], ackedClientSeq: UInt32) throws {
        // Every entry is applied -- the log is the delta between the snapshot and current
        // content, so skipping an acked one would leave the root behind. Only the un-acked
        // ones are queued: re-pushing what the server has already taken presents a
        // `clientSeq` it will skip.
        try self.applyChanges(changes, source: .local)
        self.localChanges.append(contentsOf: changes.filter { $0.id.getClientSeq() > ackedClientSeq })

        // Adopt the last replayed change's ID as the document's own counter.
        //
        // `applyChanges` only syncs clocks, which leaves `clientSeq` behind and over-advances
        // `lamport` (it bumps per change, on top of a snapshot that predates them). Both
        // matter. `createChangePack` derives the pushed checkpoint from `clientSeq`, so a
        // counter left behind mints a sequence the server has already seen and silently drops
        // the next edit; and a lamport that ran ahead mis-stamps every later ticket.
        //
        // Guarded: an all-acked replay must not pull the clock back below what the meta
        // header already established.
        if let lastID = changes.last?.id, lastID.getClientSeq() >= self.changeID.getClientSeq() {
            self.changeID = lastID
        }

        // The clone predates the replay, and the history's reverse-ops reference the
        // pre-replay state -- the same reasoning ``restoreFromBytes(_:)`` applies.
        self.clone = nil
        self.clearHistory()
    }

    /// Overwrites this document's restorable state in place.
    ///
    /// The counterpart write-side of ``persistenceSnapshot()``, used by
    /// ``restoreFromBytes(_:)`` and ``resetForReanchor()``. Drops the stale clone so the
    /// next `update` re-clones from the new root/presences, and clears the undo/redo
    /// history, whose reverse-ops reference the state that was just replaced. Takes a single
    /// ``PersistedDocumentState`` rather than one parameter per field, to stay within this
    /// project's `function_parameter_count` lint budget.
    ///
    /// - Parameter state: The restorable state to install.
    func applyPersistedState(_ state: PersistedDocumentState) {
        self.root = state.root
        self.presences = state.presences
        self.checkpoint = state.checkpoint
        self.changeID = state.changeID
        self.localChanges = state.localChanges
        self.epoch = state.epoch
        self.docID = state.docID
        self.clone = nil
        self.clearHistory()
    }
}
