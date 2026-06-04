/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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

import Foundation

/// A document revision used for version management.
///
/// Stores a snapshot of document content at a specific point in time, enabling features such as
/// rollback, audit, and version history tracking. Returned by ``Client/createRevision(_:label:description:)``
/// and ``Client/listRevisions(_:pageSize:offset:isForward:)``.
public struct RevisionSummary: Sendable {
    /// The unique identifier of the revision.
    public let id: String
    /// A user-friendly name for this revision.
    public let label: String
    /// A detailed explanation of this revision.
    public let description: String
    /// The serialized document content in YSON format at this revision point.
    ///
    /// Use ``YSON/parse(_:)`` to convert this string into a typed Swift value.
    public let snapshot: String
    /// The time when this revision was created.
    public let createdAt: Date
}
