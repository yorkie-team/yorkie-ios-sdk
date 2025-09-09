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

class RulesetBuilder {
    private var currentPath: [String] = ["$"]
    private var ruleMap: [String: Rule] = [:]

    func enterTypeAliasDeclaration(typeName: String) {
        if typeName == "Document" {
            self.currentPath = ["$"]
            self.ruleMap["$"] = .object(ObjectRule(path: "$", properties: [], optional: nil))
        }
    }

    func enterPrimitiveType(type: PrimitiveType) {
        let path = self.buildPath()
        let rule = PrimitiveRule(path: path, type: .primitive(type))
        self.ruleMap[path] = .primitive(rule)
    }

    func exitPrimitiveType() {
        _ = self.currentPath.popLast()
    }

    func enterObjectType() {
        let path = self.buildPath()
        self.ruleMap[path] = .object(ObjectRule(path: path, properties: [], optional: nil))
    }

    func enterPropertySignature(propName: String, isOptional: Bool) {
        let parentPath = self.buildPath()
        if case .object(var parentRule) = ruleMap[parentPath] {
            parentRule.properties.append(propName)
            if isOptional {
                if parentRule.optional == nil {
                    parentRule.optional = []
                }
                parentRule.optional?.append(propName)
            }
            self.ruleMap[parentPath] = .object(parentRule)
        }
        self.currentPath.append(propName)
    }

    func enterYorkieType(type: YorkieType) {
        let path = self.buildPath()
        let rule = YorkieTypeRule(path: path, type: .yorkie(type))
        self.ruleMap[path] = .yorkie(rule)
    }

    func exitYorkieType() {
        _ = self.currentPath.popLast()
    }

    private func buildPath() -> String {
        return self.currentPath.joined(separator: ".")
    }

    func build() -> [Rule] {
        return Array(self.ruleMap.values)
    }
}
