/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

extension UInt64 {
    func toString() -> String {
        return String(self)
    }
}

/**
 * `TimeTicket` is a timestamp of the logical clock. Ticket is immutable.
 * It is created by `ChangeID`.
 */
class TimeTicket {
    private enum InitialValue {
        static let initialDelimiter = 0
        static let maxDelemiter = 4_294_967_295
        static let maxLamport = UInt64("18446744073709551615") ?? 0
    }

    static let initialTimeTicket = TimeTicket(lamport: 0, delimiter: InitialValue.initialDelimiter, actorID: ActorIds.initialActorID)
    static let maxTimeTicket = TimeTicket(lamport: InitialValue.maxLamport, delimiter: InitialValue.maxDelemiter, actorID: ActorIds.maxActorID)

    private var lamport: UInt64
    private var delimiter: Int
    private var actorID: ActorID?

    /** @hideconstructor */
    init(lamport: UInt64, delimiter: Int, actorID: ActorID?) {
        self.lamport = lamport
        self.delimiter = delimiter
        self.actorID = actorID
    }

    /**
     * `of` creates an instance of Ticket.
     */
    public static func of(lamport: UInt64, delimiter: Int, actorID: ActorID?) -> TimeTicket {
        return TimeTicket(lamport: lamport, delimiter: delimiter, actorID: actorID)
    }

    /**
     * `toIDString` returns the lamport string for this Ticket.
     */
    func toIDString() -> String {
        if self.actorID == nil {
            return "\(self.lamport.toString()):nil:\(self.delimiter)"
        }
        return "\(self.lamport.toString()):\(String(describing: self.actorID)):\(self.delimiter)"
    }

    /**
     * `getAnnotatedString` returns a string containing the meta data of the ticket
     * for debugging purpose.
     */
    func getAnnotatedString() -> String {
        if self.actorID == nil {
            return "\(self.lamport.toString()):nil:\(self.delimiter)"
        }
        return "\(self.lamport.toString()):\(self.actorID ?? "nil"):\(self.delimiter)"
    }

    /**
     * `setActor` creates a new instance of Ticket with the given actorID.
     */
    func setActor(actorID: ActorID) -> TimeTicket {
        return TimeTicket(lamport: self.lamport, delimiter: self.delimiter, actorID: actorID)
    }

    /**
     * `getLamportAsString` returns the lamport string.
     */
    func getLamportAsString() -> String {
        return self.lamport.toString()
    }

    /**
     * `getDelimiter` returns delimiter.
     */
    func getDelimiter() -> Int {
        return self.delimiter
    }

    /**
     * `getActorID` returns actorID.
     */
    func getActorID() -> String? {
        return self.actorID
    }

    /**
     * `after` returns whether the given ticket was created later.
     */
    func after(_ other: TimeTicket) -> Bool {
        return self.compare(other) == .orderedDescending
    }

    /**
     * `equals` returns whether the given ticket was created.
     */
    func equals(other: TimeTicket) -> Bool {
        return self.compare(other) == .orderedSame
    }

    /**
     * `compare` returns an integer comparing two Ticket.
     *  The result will be 0 if id==other, -1 if `id < other`, and +1 if `id > other`.
     *  If the receiver or argument is nil, it would panic at runtime.
     */
    func compare(_ other: TimeTicket) -> ComparisonResult {
        if self.lamport > other.lamport {
            return .orderedDescending
        } else if self.lamport < other.lamport {
            return .orderedAscending
        }

        if let actorID = actorID, let otherActorID = other.actorID {
            let compare = actorID.localizedCompare(otherActorID)
            if compare != .orderedSame {
                return compare
            }
        }

        if self.delimiter > other.delimiter {
            return .orderedDescending
        } else if other.delimiter > self.delimiter {
            return .orderedAscending
        }

        return .orderedSame
    }
}
