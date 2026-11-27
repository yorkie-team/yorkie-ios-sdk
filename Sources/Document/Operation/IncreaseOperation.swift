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
 * `IncreaseOperation` represents an operation that increments a numeric value to Counter.
 * Among Primitives, numeric types Integer, Long, and Double are used as values.
 * For dedup counters the `actor` field identifies the unique actor being recorded.
 */
struct IncreaseOperation: Operation {
    var parentCreatedAt: TimeTicket
    var executedAt: TimeTicket

    let value: CRDTElement

    /// The actor identifier used by dedup counters; empty string for regular counters.
    let actor: String

    init(parentCreatedAt: TimeTicket, value: CRDTElement, executedAt: TimeTicket, actor: String = "") {
        self.parentCreatedAt = parentCreatedAt
        self.executedAt = executedAt
        self.value = value
        self.actor = actor
    }

    var effectedCreatedAt: TimeTicket {
        self.parentCreatedAt
    }

    var toTestString: String {
        "\(self.parentCreatedAt.toTestString).INCREASE"
    }

    /// Returns the actor identifier; empty string for regular counters.
    func getActor() -> String {
        return self.actor
    }

    /**
     * `execute` executes this operation on the given document(`root`).
     *
     * Dedup counters use ``CRDTCounter/increaseDedup(_:actor:)`` and produce
     * no undo operation (HLL state cannot be reversed). Regular counters use
     * the standard ``CRDTCounter/increase(_:)`` path.
     */
    @discardableResult
    func execute(
        root: CRDTRoot,
        versionVector: VersionVector? = nil,
        source: OpSource = .local
    ) throws -> ExecutionResult? {
        guard let opInfos = try self.executeOpInfos(root: root, versionVector: versionVector, source: source) else {
            return nil
        }
        return ExecutionResult(opInfos: opInfos)
    }

    /// Reports a delta that cannot be applied to the caller of a local `update` or an undo/redo, and
    /// skips it with a warning on the pull path, as Go does (`pkg/document/operations/increase.go`,
    /// `skipUnlessLocal`).
    ///
    /// A stored change that throws comes back on every pull -- the checkpoint does not advance past
    /// it -- so a value that is not a primitive, a delta the counter refuses or a dedup increase
    /// without an actor would wedge the document. Dropping the delta is the same on every replica,
    /// so they still converge.
    private func skipUnlessLocal(source: OpSource, cause: Error) throws -> [any OperationInfo]? {
        guard source == .remote else {
            throw cause
        }
        Logger.warning("[Increase] skipped a remote increase that cannot apply: \(cause)")
        return nil
    }

    /// Applies the increase and returns its operation infos, or `nil` when the increase is skipped
    /// or changes nothing.
    private func executeOpInfos(
        root: CRDTRoot,
        versionVector: VersionVector? = nil,
        source: OpSource
    ) throws -> [any OperationInfo]? {
        guard let parentObject = root.find(createdAt: self.parentCreatedAt) else {
            let log = "fail to find \(self.parentCreatedAt)"
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        // NOTE: the target must be a counter for every source: Go returns `ErrNotApplicableDataType`
        // whatever the source, and so does JS. Only a fault of the delta itself is skipped below.
        guard parentObject is CRDTCounter<Int32> || parentObject is CRDTCounter<Int64> else {
            let log = "fail to execute, only Counter can execute increase"
            throw YorkieError(code: .errInvalidArgument, message: log)
        }

        // NOTE: the wire format does not restrict the value, so it can be anything an element can be.
        guard let primitive = self.value.deepcopy() as? Primitive else {
            return try self.skipUnlessLocal(
                source: source,
                cause: YorkieError(
                    code: .errInvalidArgument,
                    message: "fail to execute, only Primitive can be increased"
                )
            )
        }

        do {
            if let counter = parentObject as? CRDTCounter<Int32>, counter.isDedup {
                guard !self.actor.isEmpty else {
                    throw YorkieError(code: .errInvalidArgument, message: "dedup counter requires actor")
                }
                try counter.increaseDedup(primitive, actor: self.actor)
            } else if let counter = parentObject as? CRDTCounter<Int32> {
                try counter.increase(primitive)
            } else if let counter = parentObject as? CRDTCounter<Int64> {
                try counter.increase(primitive)
            }
        } catch {
            return try self.skipUnlessLocal(source: source, cause: error)
        }

        let path = try root.createPath(createdAt: self.parentCreatedAt)

        guard let value = Self.opInfoValue(of: primitive) else {
            // A NaN or infinite Double delta leaves the counter untouched: nothing to report.
            return nil
        }

        return [IncreaseOpInfo(path: path, value: value)]
    }

    /// Returns the delta an increase reports in its ``IncreaseOpInfo``.
    ///
    /// The public `IncreaseOpInfo.value` is an `Int`, so a `Double` delta is reported as the delta
    /// truncated toward zero (`-2.7` gives `-2`; JS reports the raw double) and wrapped to 64 bits.
    /// It is the delta, not the change in the counter's value: for an `Int32` counter given a delta
    /// outside the int32 range the counter wraps at 32 bits, so read the counter for its value.
    /// Returns `nil` for a delta that changes nothing (NaN or an infinity) or that is not numeric.
    private static func opInfoValue(of primitive: Primitive) -> Int? {
        switch primitive.value {
        case .integer(let value):
            return Int(value)
        case .long(let value):
            return Int(truncatingIfNeeded: value)
        case .double(let value):
            return value.isFinite ? Int(truncatingIfNeeded: Int64(wrapping: value)) : nil
        default:
            return nil
        }
    }
}
