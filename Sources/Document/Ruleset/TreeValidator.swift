/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
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

/// `TreeValidationResult` is the result of validating a tree against its schema rules.
struct TreeValidationResult {
    let valid: Bool
    let error: String?
}

/// `buildGroupResolver` builds a resolver that maps a name to the list of node types belonging to
/// that group. If the name is not a group, it returns `[name]` (treating it as a concrete node type).
func buildGroupResolver(_ treeNodes: [TreeNodeRule]) -> (String) -> [String] {
    var groupMap: [String: [String]] = [:]
    for node in treeNodes {
        guard let group = node.group else {
            continue
        }
        for groupName in group.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            groupMap[groupName, default: []].append(node.nodeType)
        }
    }
    return { name in groupMap[name] ?? [name] }
}

/// `validateTreeAgainstSchema` validates a ``CRDTTree``'s structure against the given tree node
/// rules. It checks that each node's type exists in the rules, that children match the content
/// expression (for non-text nodes), and that text-node marks are allowed by the parent's marks rule.
///
/// - Parameters:
///   - tree: The tree to validate.
///   - treeNodes: The tree node rules from the document schema.
/// - Returns: A ``TreeValidationResult`` describing the first violation, if any.
func validateTreeAgainstSchema(_ tree: CRDTTree, _ treeNodes: [TreeNodeRule]) -> TreeValidationResult {
    var ruleMap: [String: TreeNodeRule] = [:]
    for node in treeNodes {
        ruleMap[node.nodeType] = node
    }
    let resolver = buildGroupResolver(treeNodes)
    return validateNode(tree.root, ruleMap, resolver)
}

/// `validateNode` recursively validates a ``CRDTTreeNode`` against the rules.
private func validateNode(
    _ node: CRDTTreeNode,
    _ ruleMap: [String: TreeNodeRule],
    _ resolver: (String) -> [String]
) -> TreeValidationResult {
    // The node type must exist in the rules.
    guard let rule = ruleMap[node.type] else {
        return TreeValidationResult(valid: false, error: "Unknown node type: \"\(node.type)\"")
    }

    // Text nodes are leaves, validated by their parent's marks rule.
    if node.isText {
        return TreeValidationResult(valid: true, error: nil)
    }

    // Non-removed children.
    let children = node.children

    // All non-text children must have known types.
    for child in children where !child.isText && ruleMap[child.type] == nil {
        return TreeValidationResult(valid: false, error: "Unknown node type: \"\(child.type)\"")
    }

    // Validate the content expression (empty string means no children allowed).
    if let content = rule.content {
        let childTypes = children.map { $0.type }
        do {
            let expr = try parseContentExpression(content)
            let result = matchContentExpression(expr, childTypes, resolver)
            if !result.valid {
                return TreeValidationResult(valid: false, error: "Node \"\(node.type)\": \(result.error ?? "")")
            }
        } catch {
            let message = (error as? YorkieError)?.message ?? "\(error)"
            return TreeValidationResult(valid: false, error: "Node \"\(node.type)\": \(message)")
        }
    }

    // Validate marks on text children if the rule specifies allowed marks. An empty `marks` string
    // is treated as "no marks rule" (matching the JS truthy check), not "allow no marks".
    if let marks = rule.marks, !marks.isEmpty {
        let allowedMarks = marks.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let markResult = validateChildMarks(node, children, allowedMarks)
        if !markResult.valid {
            return markResult
        }
    }

    // Recurse into non-text children.
    for child in children where !child.isText {
        let result = validateNode(child, ruleMap, resolver)
        if !result.valid {
            return result
        }
    }

    return TreeValidationResult(valid: true, error: nil)
}

/// `validateChildMarks` checks that text children of a node only carry marks listed in
/// `allowedMarks`.
private func validateChildMarks(
    _ parent: CRDTTreeNode,
    _ children: [CRDTTreeNode],
    _ allowedMarks: [String]
) -> TreeValidationResult {
    for child in children {
        if !child.isText {
            continue
        }
        guard let attrs = child.attrs else {
            continue
        }
        for rhtNode in attrs {
            if rhtNode.isRemoved {
                continue
            }
            let markName = rhtNode.key
            if !allowedMarks.contains(markName) {
                return TreeValidationResult(
                    valid: false,
                    error: "Node \"\(parent.type)\": text child has disallowed mark \"\(markName)\". Allowed marks: \(allowedMarks.joined(separator: ", "))"
                )
            }
        }
    }
    return TreeValidationResult(valid: true, error: nil)
}
