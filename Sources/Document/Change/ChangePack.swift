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

import Foundation

/**
 * `ChangePack` is a unit for delivering changes in a document to the remote.
 */
struct ChangePack {
    /**
     * `documentKey` is the key of the document.
     */
    private let documentKey: String

    /**
     * `Checkpoint` is used to determine the client received changes.
     */
    private let checkpoint: Checkpoint

    private let changes: [Change]

    /**
     * `snapshot` is a byte array that encode the document.
     */
    private let snapshot: Data?

    /**
     * `minSyncedTicket` is the minimum logical time taken by clients who attach
     * the document. It used to collect garbage on the replica on the client.
     */
    private let minSyncedTicket: TimeTicket?

    init(key: String, checkpoint: Checkpoint, changes: [Change], snapshot: Data? = nil, minSyncedTicket: TimeTicket? = nil) {
        self.documentKey = key
        self.checkpoint = checkpoint
        self.changes = changes
        self.snapshot = snapshot
        self.minSyncedTicket = minSyncedTicket
    }

    /**
     * `getDocumentKey` returns the document key of this pack.
     */
    func getDocumentKey() -> String {
        return self.documentKey
    }

    /**
     * `getCheckpoint` returns the checkpoint of this pack.
     */
    func getCheckpoint() -> Checkpoint {
        return self.checkpoint
    }

    /**
     * `getChanges` returns the changes of this pack.
     */
    func getChanges() -> [Change] {
        return self.changes
    }

    /**
     * `hasChanges` returns the whether this pack has changes or not.
     */
    func hasChanges() -> Bool {
        return self.changes.isEmpty == false
    }

    /**
     * `getChangeSize` returns the size of changes this pack has.
     */
    func getChangeSize() -> Int {
        return self.changes.count
    }

    /**
     * `getSnapshot` returns the snapshot of this pack.
     */
    func getSnapshot() -> Data? {
        return self.snapshot
    }

    /**
     * `getMinSyncedTicket` returns the minimum synced ticket of this pack.
     */
    func getMinSyncedTicket() -> TimeTicket? {
        return self.minSyncedTicket
    }
}
