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

// MARK: - Rule Types

enum PrimitiveType: String, Codable {
    case null, boolean, integer, double, long, string, date, bytes
}

enum YorkieType: String, Codable {
    case text = "yorkie.Text"
    case tree = "yorkie.Tree"
    case counter = "yorkie.Counter"
    case object = "yorkie.Object"
    case array = "yorkie.Array"
}

enum RuleType: Codable {
    case object
    case array
    case primitive(PrimitiveType)
    case yorkie(YorkieType)

    var description: String {
        switch self {
        case .object:
            return "object"
        case .array:
            return "array"
        case .primitive(let primitiveType):
            return primitiveType.rawValue
        case .yorkie(let yorkieType):
            return yorkieType.rawValue
        }
    }
}

enum Rule {
    case object(ObjectRule)
    case array(ArrayRule)
    case primitive(PrimitiveRule)
    case yorkie(YorkieTypeRule)

    var path: String {
        switch self {
        case .object(let objectRule):
            return objectRule.path
        case .array(let arrayRule):
            return arrayRule.path
        case .primitive(let primitiveRule):
            return primitiveRule.path
        case .yorkie(let yorkieTypeRule):
            return yorkieTypeRule.path
        }
    }

    var type: RuleType {
        switch self {
        case .object(let objectRule):
            return objectRule.type
        case .array(let arrayRule):
            return arrayRule.type
        case .primitive(let primitiveRule):
            return primitiveRule.type
        case .yorkie(let yorkieTypeRule):
            return yorkieTypeRule.type
        }
    }

    var primitive: PrimitiveRule? {
        switch self {
        case .primitive(let primitiveRule):
            return primitiveRule
        default: return nil
        }
    }
}

protocol RuleProtocol {
    var path: String { get }
    var type: RuleType { get }
}

struct PrimitiveRule: RuleProtocol {
    let path: String
    let type: RuleType

    func getType() -> String? {
        if case .primitive(let type) = type {
            return type.rawValue
        }
        return nil
    }
}

struct ObjectRule: RuleProtocol {
    let path: String
    let type: RuleType = .object
    var properties: [String]
    var optional: [String]?
}

struct ArrayRule: RuleProtocol {
    let path: String
    let type: RuleType = .array
}

struct YorkieTypeRule: RuleProtocol {
    let path: String
    let type: RuleType
}
