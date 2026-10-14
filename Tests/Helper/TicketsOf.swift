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
import SwiftProtobuf
@testable import Yorkie

/// A `TimeTicket` as it travels on the wire: the hex actor and the lamport.
struct WireTicket: Equatable {
    let actor: String
    let lamport: Int64
}

/// Collects every `TimeTicket` reachable from a protobuf message, decoding the element bytes an
/// Object, Array or Tree `JSONElementSimple` carries.
///
/// A read-only `SwiftProtobuf.Visitor` over the generated types on purpose, so it shares no code with
/// the mutating walk under test in `Sources/API/Reissue.swift`: a field that walk forgets is a field
/// this one still sees.
private struct TicketCollector: SwiftProtobuf.Visitor {
    var tickets = [WireTicket]()

    mutating func visitSingularMessageField<M: SwiftProtobuf.Message>(value: M, fieldNumber: Int) throws {
        if let ticket = value as? PbTimeTicket {
            self.tickets.append(WireTicket(actor: ticket.actorID.toHexString, lamport: ticket.lamport))
            return
        }
        if let simple = value as? PbJSONElementSimple {
            switch simple.type {
            case .jsonObject, .jsonArray, .tree:
                if simple.value.isEmpty == false {
                    let nested = try PbJSONElement(serializedBytes: simple.value)
                    try nested.traverse(visitor: &self)
                }
            default:
                break
            }
        }
        try value.traverse(visitor: &self)
    }

    mutating func visitRepeatedMessageField<M: SwiftProtobuf.Message>(value: [M], fieldNumber: Int) throws {
        for item in value {
            try self.visitSingularMessageField(value: item, fieldNumber: fieldNumber)
        }
    }

    mutating func visitMapField<KeyType, ValueType>(
        fieldType: _ProtobufMessageMap<KeyType, ValueType>.Type,
        value: _ProtobufMessageMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {
        for item in value.values {
            try self.visitSingularMessageField(value: item, fieldNumber: fieldNumber)
        }
    }

    mutating func visitMapField<KeyType, ValueType: MapValueType>(
        fieldType: _ProtobufMap<KeyType, ValueType>.Type,
        value: _ProtobufMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {}

    mutating func visitMapField<KeyType, ValueType>(
        fieldType: _ProtobufEnumMap<KeyType, ValueType>.Type,
        value: _ProtobufEnumMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws where ValueType.RawValue == Int {}

    mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws {}
    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws {}
    mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws {}
    mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws {}
    mutating func visitSingularStringField(value: String, fieldNumber: Int) throws {}
    mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws {}
    mutating func visitSingularEnumField<E: SwiftProtobuf.Enum>(value: E, fieldNumber: Int) throws {}
    mutating func visitSingularGroupField<G: SwiftProtobuf.Message>(value: G, fieldNumber: Int) throws {}
    mutating func visitUnknown(bytes: Data) throws {}
}

/// Returns every `TimeTicket` reachable from the given protobuf messages as `(actor, lamport)`.
func ticketsOf(_ messages: [some SwiftProtobuf.Message]) -> [WireTicket] {
    var collector = TicketCollector()
    for message in messages {
        // A visitor error only comes from a malformed nested element, which the caller's own
        // assertions would then surface as a missing ticket.
        try? message.traverse(visitor: &collector)
    }
    return collector.tickets
}

/// Returns every `TimeTicket` reachable from the given protobuf message.
func ticketsOf(_ message: some SwiftProtobuf.Message) -> [WireTicket] {
    ticketsOf([message])
}

/// Counts, per actor, the given tickets whose lamport is not 0.
///
/// The lamport-0 ticket is the root's and every sentinel's identity, shared by all replicas.
func countActors(_ tickets: [WireTicket]) -> [String: Int] {
    var actors = [String: Int]()
    for ticket in tickets where ticket.lamport != 0 {
        actors[ticket.actor, default: 0] += 1
    }
    return actors
}
