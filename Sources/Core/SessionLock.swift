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

/// A held session lease, released when the attachment ends.
public protocol SessionLockHandle: Sendable {
    /// Releases the lease.
    ///
    /// Releasing twice is harmless.
    func release() async
}

/// Guards a store-backed document against being resumed by two sessions at once.
///
/// A lease is taken per attachment, keyed by the API key, client key and document key,
/// and held for the attachment's lifetime. It matters only when a persistent
/// ``DocStore`` is shared by more than one process: two sessions resuming the same
/// persisted document would both re-push the same un-acknowledged local changes.
///
/// ## Platform note
///
/// Upstream's default is built on the browser's Web Locks API to keep two tabs apart,
/// and is documented there as a no-op outside a browser. iOS has no tabs, and an app is
/// a single process, so ``NoopSessionLock`` is the default here and matches upstream's
/// own non-browser behaviour.
///
/// The hazard is still reachable on Apple platforms when a **persistent** store is
/// shared across processes — an app and its share extension or widget writing to the
/// same App Group container. A caller who does that should supply an implementation
/// backed by cross-process coordination, such as `NSFileCoordinator` or a lock file.
public protocol SessionLock: Sendable {
    /// Acquires the lease named `name`, or reports that another session holds it.
    ///
    /// Implementations must not block: report the contended case instead of waiting,
    /// so an attach fails fast rather than hanging behind another session.
    ///
    /// - Parameter name: The lease name, derived from the API key, client key and document key.
    /// - Returns: A handle to release, or `nil` when another session holds the lease.
    func acquire(name: String) async -> SessionLockHandle?
}

/// A ``SessionLock`` that grants every lease.
///
/// The default. It imposes no coordination, which is correct for the single-process case
/// and mirrors how upstream's Web Locks default behaves outside a browser. Supply your
/// own ``SessionLock`` when a persistent ``DocStore`` is shared across processes.
public struct NoopSessionLock: SessionLock {
    /// A handle whose release does nothing.
    private struct Handle: SessionLockHandle {
        func release() async {}
    }

    /// Creates the lock.
    public init() {}

    public func acquire(name: String) async -> SessionLockHandle? {
        Handle()
    }
}
