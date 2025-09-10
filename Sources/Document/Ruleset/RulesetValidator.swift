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

struct ValidationError {
    let path: String
    let message: String
}

struct ValidationResult {
    let valid: Bool
    let errors: [ValidationError]
}

enum RulesetValidator {
    static func validateYorkieRuleset(data: Any?, ruleset: [Rule]) -> ValidationResult {
        var errors: [ValidationError] = []
        for rule in ruleset {
            let value = self.getValueByPath(obj: data, path: rule.path)
            let result = self.validateValue(value: value, rule: rule)
            if !result.valid {
                errors.append(contentsOf: result.errors)
            }
        }
        return ValidationResult(valid: errors.isEmpty, errors: errors)
    }

    static func getValueByPath(obj: Any?, path: String) -> Any? {
        guard path.hasPrefix("$") else {
            return nil
        }
        let keys = path.split(separator: ".").map(String.init)
        var current = obj
        for key in keys.dropFirst() {
            if let dict = current as? CRDTObject {
                current = dict.get(key: key)
            } else {
                return nil
            }
        }
        return current
    }

    static func validateValue(value: Any?, rule: Rule) -> ValidationResult {
        switch rule.type {
        case .primitive:
            return self.validatePrimitiveValue(value: value, rule: rule.primitive!)
        case .object:
            if !(value is CRDTObject) {
                return ValidationResult(valid: false, errors: [
                    ValidationError(path: rule.path, message: "Expected object at path \(rule.path)")
                ])
            }
        case .array:
            if !(value is CRDTArray) {
                return ValidationResult(valid: false, errors: [
                    ValidationError(path: rule.path, message: "Expected array at path \(rule.path)")
                ])
            }
        case .yorkie(let type):
            switch type {
            case .text:
                if !(value is CRDTText) {
                    return ValidationResult(valid: false, errors: [
                        ValidationError(path: rule.path, message: "Expected yorkie.Text at path \(rule.path)")
                    ])
                }
            case .tree:
                if !(value is CRDTTree) {
                    return ValidationResult(valid: false, errors: [
                        ValidationError(path: rule.path, message: "Expected yorkie.Tree at path \(rule.path)")
                    ])
                }
            case .counter:
                // support Int32 and Int64 only
                if !(value is CRDTCounter<Int32>) && !(value is CRDTCounter<Int64>) {
                    return ValidationResult(valid: false, errors: [
                        ValidationError(path: rule.path, message: "Expected yorkie.Counter at path \(rule.path)")
                    ])
                }
            default:
                break
            }
        }
        return ValidationResult(valid: true, errors: [])
    }

    static func getPrimitiveType(_ type: String) throws -> PrimitiveType {
        switch type {
        case "null":
            return .null
        case "boolean":
            return .boolean
        case "integer":
            return .integer
        case "long":
            return .long
        case "double":
            return .double
        case "string":
            return .string
        case "bytes":
            return .bytes
        case "date":
            return .date
        default:
            throw NSError(domain: "UnknownPrimitiveType", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unknown primitive type: \(type)"])
        }
    }

    static func validatePrimitiveValue(value: Any?, rule: PrimitiveRule) -> ValidationResult {
        do {
            let expectedType = try getPrimitiveType(rule.type.description)
            if let primitive = value as? Primitive, primitive.value.getType == expectedType.rawValue {
                return ValidationResult(valid: true, errors: [])
            }
        } catch {
            return ValidationResult(valid: false, errors: [
                ValidationError(path: rule.path, message: error.localizedDescription)
            ])
        }
        return ValidationResult(valid: false, errors: [
            ValidationError(path: rule.path, message: "Expected \(rule.type) at path \(rule.path)")
        ])
    }
}

extension PrimitiveValue {
    var getType: String {
        switch self {
        case .null:
            return "null"
        case .boolean:
            return "boolean"
        case .integer:
            return "integer"
        case .long:
            return "long"
        case .double:
            return "double"
        case .string:
            return "string"
        case .bytes:
            return "bytes"
        case .date:
            return "date"
        }
    }
}
