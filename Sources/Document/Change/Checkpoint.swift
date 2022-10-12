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
 * `Checkpoint` is used to determine the changes sent and received by the
 * client. This is immutable.
 *
 * @internal
 **/
struct Checkpoint: Equatable {
    /**
     * `InitialCheckpoint` is the initial value of the checkpoint.
     */
    static let initial = Checkpoint(serverSeq: 0, clientSeq: 0)
    private var serverSeq: Int64
    private var clientSeq: Int

    init(serverSeq: Int64, clientSeq: Int) {
        self.serverSeq = serverSeq
        self.clientSeq = clientSeq
    }

    /**
     * `increaseClientSeq` creates a new instance with increased client sequence.
     */
    func increaseClientSeq(_ value: Int) -> Checkpoint {
        if value == 0 {
            return self
        }

        return Checkpoint(serverSeq: self.serverSeq, clientSeq: self.clientSeq + value)
    }

    /**
     * `forward` updates the given checkpoint with those values when it is greater
     * than the values of internal properties.
     */
    mutating func forward(other: Checkpoint) {
        if self == other {
            return
        }

        self.serverSeq = self.serverSeq > other.serverSeq ? self.serverSeq : other.serverSeq
        self.clientSeq = max(self.clientSeq, other.clientSeq)
    }

    /**
     * `getServerSeqAsString` returns the server seq of this checkpoint as a
     * string.
     */
    func getServerSeqAsString() -> String {
        return "\(self.serverSeq)"
    }

    /**
     * `getClientSeq` returns the client seq of this checkpoint.
     */
    func getClientSeq() -> Int {
        return self.clientSeq
    }

    /**
     * `getServerSeq` returns the server seq of this checkpoint.
     */
    func getServerSeq() -> Int64 {
        return self.serverSeq
    }

    /**
     * `getStructureAsString` returns a string containing the meta data of this
     * checkpoint.
     */
    func getStructureAsString() -> String {
        return "serverSeq=\(self.serverSeq), clientSeq=\(self.clientSeq)"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.clientSeq == rhs.clientSeq && lhs.serverSeq == rhs.serverSeq
    }
}
