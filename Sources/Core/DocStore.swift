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

/// Persists a serialized document between sessions.
///
/// A store is keyed by document key and holds whatever ``Document/toBytes()`` produced,
/// so a later session can restore the document and re-push the local changes that were
/// never acknowledged. Implementations decide where the bytes live; the SDK only
/// requires that a `save` is visible to a subsequent `load` for the same key.
///
/// The SDK never inspects the stored bytes, so an implementation is free to encrypt or
/// compress them as long as it returns exactly what it was given.
public protocol DocStore: Sendable {
    /// Returns the bytes stored for `docKey`, or `nil` when nothing is stored.
    ///
    /// - Parameter docKey: The key of the document to load.
    /// - Returns: The stored bytes, or `nil` when the key is absent.
    /// - Throws: Any error the underlying storage raises.
    func load(docKey: String) async throws -> Data?

    /// Stores `bytes` under `docKey`, replacing anything already there.
    ///
    /// - Parameters:
    ///   - docKey: The key of the document to store.
    ///   - bytes: The serialized document.
    /// - Throws: Any error the underlying storage raises.
    func save(docKey: String, bytes: Data) async throws

    /// Removes anything stored under `docKey`.
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
public actor MemoryDocStore: DocStore {
    private var store: [String: Data] = [:]

    /// Creates an empty store.
    public init() {}

    public func load(docKey: String) async throws -> Data? {
        self.store[docKey]
    }

    public func save(docKey: String, bytes: Data) async throws {
        self.store[docKey] = bytes
    }

    public func remove(docKey: String) async throws {
        self.store.removeValue(forKey: docKey)
    }
}
