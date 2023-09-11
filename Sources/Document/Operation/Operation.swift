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
 * `OperationInfoType` is operation info types
 */
public enum OperationInfoType: String {
    case add
    case move
    case set
    case remove
    case increase
    case edit
    case style
    case select
    case treeEdit
    case treeStyle
}

/**
 * `OperationInfo` represents the information of an operation.
 * It is used to inform to the user what kind of operation was executed.
 */
public protocol OperationInfo: Equatable {
    var type: OperationInfoType { get }
    var path: String { get }
}

public struct AddOpInfo: OperationInfo {
    public let type: OperationInfoType = .add
    public let path: String
    public let index: Int
}

public struct MoveOpInfo: OperationInfo {
    public let type: OperationInfoType = .move
    public let path: String
    public let previousIndex: Int
    public let index: Int
}

public struct SetOpInfo: OperationInfo {
    public let type: OperationInfoType = .set
    public let path: String
    public let key: String
}

public struct RemoveOpInfo: OperationInfo {
    public let type: OperationInfoType = .remove
    public let path: String
    public let key: String?
    public let index: Int?
}

public struct IncreaseOpInfo: OperationInfo {
    public let type: OperationInfoType = .increase
    public let path: String
    public let value: Int
}

public struct EditOpInfo: OperationInfo {
    public let type: OperationInfoType = .edit
    public let path: String
    public let from: Int
    public let to: Int
    public let attributes: [String: Any]?
    public let content: String?

    public static func == (lhs: EditOpInfo, rhs: EditOpInfo) -> Bool {
        if lhs.type != rhs.type ||
            lhs.path != rhs.path ||
            lhs.from != rhs.from ||
            lhs.to != rhs.to ||
            lhs.content != rhs.content
        {
            return false
        }

        if let leftAttrs = lhs.attributes, let rightAttrs = rhs.attributes {
            return NSDictionary(dictionary: leftAttrs).isEqual(to: rightAttrs)
        } else if lhs.attributes == nil, rhs.attributes == nil {
            return true
        }

        return false
    }
}

public struct StyleOpInfo: OperationInfo {
    public let type: OperationInfoType = .style
    public let path: String
    public let from: Int
    public let to: Int
    public let attributes: [String: Any]?

    public static func == (lhs: StyleOpInfo, rhs: StyleOpInfo) -> Bool {
        if lhs.type != rhs.type ||
            lhs.path != rhs.path ||
            lhs.from != rhs.from ||
            lhs.to != rhs.to
        {
            return false
        }

        if let leftAttrs = lhs.attributes, let rightAttrs = rhs.attributes {
            return NSDictionary(dictionary: leftAttrs).isEqual(to: rightAttrs)
        } else if lhs.attributes == nil, rhs.attributes == nil {
            return true
        }

        return false
    }
}

public struct TreeEditOpInfo: OperationInfo {
    public let type: OperationInfoType = .treeEdit
    public let path: String
    public let from: Int
    public let to: Int
    public let fromPath: [Int]
    public let toPath: [Int]
    public let value: [TreeNode]
}

public struct TreeStyleOpInfo: OperationInfo {
    public let type: OperationInfoType = .treeStyle
    public let path: String
    public let from: Int
    public let to: Int
    public let fromPath: [Int]
    public let value: [String: Codable]

    public static func == (lhs: TreeStyleOpInfo, rhs: TreeStyleOpInfo) -> Bool {
        if lhs.type != lhs.type {
            return false
        }
        if lhs.path != lhs.path {
            return false
        }
        if lhs.from != lhs.from {
            return false
        }
        if lhs.to != lhs.to {
            return false
        }
        if lhs.fromPath != lhs.fromPath {
            return false
        }

        if !(lhs.value == rhs.value) {
            return false
        }

        return true
    }
}

/**
 * `Operation` represents an operation to be executed on a document.
 *  Types confiming ``Operation`` must be struct to avoid data racing.
 */
protocol Operation {
    /// `parentCreatedAt` returns the creation time of the target element to
    var parentCreatedAt: TimeTicket { get }
    /// `executedAt` returns execution time of this operation.
    var executedAt: TimeTicket { get set }

    /**
     * `effectedCreatedAt` returns the creation time of the effected element.
     */
    var effectedCreatedAt: TimeTicket { get }

    /**
     * `toTestString` returns a string containing the meta data.
     */
    var toTestString: String { get }

    /**
     * `execute` executes this operation on the given document(`root`).
     */
    func execute(root: CRDTRoot) throws -> [any OperationInfo]
}

extension Operation {
    /**
     * `setActor` sets the given actor to this operation.
     */
    mutating func setActor(_ actorID: ActorID) {
        self.executedAt.setActor(actorID)
    }
}
