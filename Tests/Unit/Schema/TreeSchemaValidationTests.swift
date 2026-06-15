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

import XCTest
@testable import Yorkie

// MARK: - Tree building helpers (file-private, used by both test classes below)

private func schemaTextNode(_ value: String, attrs: RHT? = nil) -> CRDTTreeNode {
    CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: value as NSString, attributes: attrs)
}

private func schemaElementNode(_ type: String, children: [CRDTTreeNode]) throws -> CRDTTreeNode {
    let node = CRDTTreeNode(id: posT(), type: type, children: [])
    try node.append(contentsOf: children)
    return node
}

private func objectWithTree(key: String, tree: CRDTTree) -> CRDTObject {
    let obj = CRDTObject(createdAt: timeT())
    obj.set(key: key, value: tree)
    return obj
}

// MARK: - Tree Schema Full-Pipeline Validation Tests

// Mirrors: tree_schema_integration_test.ts "Tree Schema Integration (full pipeline)"
// These tests exercise validateYorkieRuleset with CRDTTree constructed directly — no live server.

final class TreeSchemaValidationTests: XCTestCase {
    // Schema with: doc requires paragraph+; paragraph allows text* with marks "bold italic" in group block;
    // heading allows text* with marks "bold" in group block; text is a leaf.
    private let schemaRules: [Rule] = [
        .object(ObjectRule(path: "$", properties: ["content"], optional: nil)),
        .yorkie(YorkieTypeRule(
            path: "$.content",
            type: .yorkie(.tree),
            treeNodes: [
                TreeNodeRule(nodeType: "doc", content: "paragraph+", marks: nil, group: nil),
                TreeNodeRule(nodeType: "paragraph", content: "text*", marks: "bold italic", group: "block"),
                TreeNodeRule(nodeType: "heading", content: "text*", marks: "bold", group: "block"),
                TreeNodeRule(nodeType: "text", content: nil, marks: nil, group: nil)
            ]
        ))
    ]

    // MARK: valid tree structures through full pipeline

    func test_should_validate_doc_paragraph_text() throws {
        // given
        let text = schemaTextNode("hello")
        let para = try schemaElementNode("paragraph", children: [text])
        let root = try schemaElementNode("doc", children: [para])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: self.schemaRules)

        // then
        XCTAssertTrue(result.valid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func test_should_validate_doc_multiple_paragraphs_text() throws {
        // given
        let text1 = schemaTextNode("hello")
        let text2 = schemaTextNode("world")
        let para1 = try schemaElementNode("paragraph", children: [text1])
        let para2 = try schemaElementNode("paragraph", children: [text2])
        let root = try schemaElementNode("doc", children: [para1, para2])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: self.schemaRules)

        // then
        XCTAssertTrue(result.valid)
    }

    func test_should_validate_paragraph_with_no_text_children_star_allows_zero() throws {
        // given
        let para = try schemaElementNode("paragraph", children: [])
        let root = try schemaElementNode("doc", children: [para])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: self.schemaRules)

        // then
        XCTAssertTrue(result.valid)
    }

    func test_should_validate_text_with_allowed_mark_bold_on_paragraph() throws {
        // given
        let attrs = RHT()
        attrs.set(key: "bold", value: "\"true\"", executedAt: timeT())
        let text = schemaTextNode("hello", attrs: attrs)
        let para = try schemaElementNode("paragraph", children: [text])
        let root = try schemaElementNode("doc", children: [para])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: self.schemaRules)

        // then
        XCTAssertTrue(result.valid)
    }

    func test_should_validate_text_with_multiple_allowed_marks_bold_italic() throws {
        // given
        let attrs = RHT()
        attrs.set(key: "bold", value: "\"true\"", executedAt: timeT())
        attrs.set(key: "italic", value: "\"true\"", executedAt: timeT())
        let text = schemaTextNode("styled text", attrs: attrs)
        let para = try schemaElementNode("paragraph", children: [text])
        let root = try schemaElementNode("doc", children: [para])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: self.schemaRules)

        // then
        XCTAssertTrue(result.valid)
    }

    // MARK: invalid tree structures through full pipeline

    func test_should_reject_doc_with_no_children_paragraph_plus_requires_at_least_one() throws {
        // given
        let root = try schemaElementNode("doc", children: [])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: self.schemaRules)

        // then
        XCTAssertFalse(result.valid)
        XCTAssertGreaterThan(result.errors.count, 0)
        XCTAssertEqual(result.errors[0].path, "$.content")
        XCTAssertTrue(result.errors[0].message.contains("doc"))
    }

    func test_should_reject_unknown_node_types() throws {
        // given
        let text = schemaTextNode("hello")
        let div = try schemaElementNode("div", children: [text])
        let root = try schemaElementNode("doc", children: [div])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: self.schemaRules)

        // then
        XCTAssertFalse(result.valid)
        XCTAssertGreaterThan(result.errors.count, 0)
        XCTAssertTrue(result.errors[0].message.contains("Unknown node type"))
        XCTAssertTrue(result.errors[0].message.contains("div"))
    }

    func test_should_reject_wrong_child_type_heading_under_doc_requires_paragraph_plus() throws {
        // given — doc requires "paragraph+"; heading is not a paragraph
        let text = schemaTextNode("title")
        let heading = try schemaElementNode("heading", children: [text])
        let root = try schemaElementNode("doc", children: [heading])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: self.schemaRules)

        // then
        XCTAssertFalse(result.valid)
        XCTAssertGreaterThan(result.errors.count, 0)
        XCTAssertTrue(result.errors[0].message.contains("doc"))
    }

    func test_should_reject_disallowed_marks_on_text_children() throws {
        // given — paragraph allows "bold italic" → "underline" is not permitted
        let attrs = RHT()
        attrs.set(key: "underline", value: "\"true\"", executedAt: timeT())
        let text = schemaTextNode("hello", attrs: attrs)
        let para = try schemaElementNode("paragraph", children: [text])
        let root = try schemaElementNode("doc", children: [para])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: self.schemaRules)

        // then
        XCTAssertFalse(result.valid)
        XCTAssertGreaterThan(result.errors.count, 0)
        XCTAssertTrue(result.errors[0].message.contains("disallowed mark"))
        XCTAssertTrue(result.errors[0].message.contains("underline"))
    }

    // MARK: schema with groups through full pipeline

    func test_should_validate_mixed_block_types_paragraph_and_heading() throws {
        // given — doc content is "block+"; paragraph and heading belong to the "block" group
        let groupRules: [Rule] = [
            .object(ObjectRule(path: "$", properties: ["content"], optional: nil)),
            .yorkie(YorkieTypeRule(
                path: "$.content",
                type: .yorkie(.tree),
                treeNodes: [
                    TreeNodeRule(nodeType: "doc", content: "block+", marks: nil, group: nil),
                    TreeNodeRule(nodeType: "paragraph", content: "text*", marks: nil, group: "block"),
                    TreeNodeRule(nodeType: "heading", content: "text*", marks: nil, group: "block"),
                    TreeNodeRule(nodeType: "text", content: nil, marks: nil, group: nil)
                ]
            ))
        ]

        let text1 = schemaTextNode("hello")
        let text2 = schemaTextNode("title")
        let para = try schemaElementNode("paragraph", children: [text1])
        let heading = try schemaElementNode("heading", children: [text2])
        let root = try schemaElementNode("doc", children: [para, heading])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: groupRules)

        // then
        XCTAssertTrue(result.valid)
    }

    func test_should_reject_non_block_types_under_doc_expects_block_plus() throws {
        // given — text is not in the "block" group
        let groupRules: [Rule] = [
            .object(ObjectRule(path: "$", properties: ["content"], optional: nil)),
            .yorkie(YorkieTypeRule(
                path: "$.content",
                type: .yorkie(.tree),
                treeNodes: [
                    TreeNodeRule(nodeType: "doc", content: "block+", marks: nil, group: nil),
                    TreeNodeRule(nodeType: "paragraph", content: "text*", marks: nil, group: "block"),
                    TreeNodeRule(nodeType: "heading", content: "text*", marks: nil, group: "block"),
                    TreeNodeRule(nodeType: "text", content: nil, marks: nil, group: nil)
                ]
            ))
        ]

        let text = schemaTextNode("raw text")
        let root = try schemaElementNode("doc", children: [text])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: groupRules)

        // then
        XCTAssertFalse(result.valid)
        XCTAssertGreaterThan(result.errors.count, 0)
        XCTAssertTrue(result.errors[0].message.contains("doc"))
    }

    // MARK: deeply nested schema through full pipeline

    func test_should_validate_valid_deeply_nested_tree() throws {
        // given
        let nestedRules: [Rule] = [
            .object(ObjectRule(path: "$", properties: ["content"], optional: nil)),
            .yorkie(YorkieTypeRule(
                path: "$.content",
                type: .yorkie(.tree),
                treeNodes: [
                    TreeNodeRule(nodeType: "doc", content: "section+", marks: nil, group: nil),
                    TreeNodeRule(nodeType: "section", content: "paragraph+", marks: nil, group: nil),
                    TreeNodeRule(nodeType: "paragraph", content: "text*", marks: nil, group: nil),
                    TreeNodeRule(nodeType: "text", content: nil, marks: nil, group: nil)
                ]
            ))
        ]

        let text = schemaTextNode("hello")
        let para = try schemaElementNode("paragraph", children: [text])
        let section = try schemaElementNode("section", children: [para])
        let root = try schemaElementNode("doc", children: [section])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: nestedRules)

        // then
        XCTAssertTrue(result.valid)
    }

    func test_should_reject_errors_at_nested_level_section_with_no_paragraphs() throws {
        // given — section requires paragraph+ but has no children
        let nestedRules: [Rule] = [
            .object(ObjectRule(path: "$", properties: ["content"], optional: nil)),
            .yorkie(YorkieTypeRule(
                path: "$.content",
                type: .yorkie(.tree),
                treeNodes: [
                    TreeNodeRule(nodeType: "doc", content: "section+", marks: nil, group: nil),
                    TreeNodeRule(nodeType: "section", content: "paragraph+", marks: nil, group: nil),
                    TreeNodeRule(nodeType: "paragraph", content: "text*", marks: nil, group: nil),
                    TreeNodeRule(nodeType: "text", content: nil, marks: nil, group: nil)
                ]
            ))
        ]

        let section = try schemaElementNode("section", children: [])
        let root = try schemaElementNode("doc", children: [section])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: nestedRules)

        // then
        XCTAssertFalse(result.valid)
        XCTAssertGreaterThan(result.errors.count, 0)
        XCTAssertTrue(result.errors[0].message.contains("section"))
    }

    // MARK: alternative content expression through full pipeline

    func test_should_validate_mixed_paragraph_and_heading_under_doc() throws {
        // given
        let altRules: [Rule] = [
            .object(ObjectRule(path: "$", properties: ["content"], optional: nil)),
            .yorkie(YorkieTypeRule(
                path: "$.content",
                type: .yorkie(.tree),
                treeNodes: [
                    TreeNodeRule(nodeType: "doc", content: "(paragraph | heading)+", marks: nil, group: nil),
                    TreeNodeRule(nodeType: "paragraph", content: "text*", marks: nil, group: nil),
                    TreeNodeRule(nodeType: "heading", content: "text*", marks: nil, group: nil),
                    TreeNodeRule(nodeType: "text", content: nil, marks: nil, group: nil)
                ]
            ))
        ]

        let text1 = schemaTextNode("hello")
        let text2 = schemaTextNode("title")
        let text3 = schemaTextNode("more")
        let para1 = try schemaElementNode("paragraph", children: [text1])
        let heading = try schemaElementNode("heading", children: [text2])
        let para2 = try schemaElementNode("paragraph", children: [text3])
        let root = try schemaElementNode("doc", children: [para1, heading, para2])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: altRules)

        // then
        XCTAssertTrue(result.valid)
    }

    // MARK: non-tree type mismatch through full pipeline

    func test_should_reject_when_value_at_path_is_not_a_CRDTTree() {
        // given — "content" holds a nested CRDTObject instead of a CRDTTree
        let innerObj = CRDTObject(createdAt: timeT())
        let obj = CRDTObject(createdAt: timeT())
        obj.set(key: "content", value: innerObj)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: self.schemaRules)

        // then
        XCTAssertFalse(result.valid)
        XCTAssertGreaterThan(result.errors.count, 0)
        XCTAssertTrue(result.errors[0].message.contains("yorkie.Tree"))
    }

    // MARK: tree without treeNodes (no schema constraint) through full pipeline

    func test_should_pass_validation_for_yorkie_tree_rule_without_treeNodes() throws {
        // given — nil treeNodes means any tree structure is valid
        let noTreeNodesRules: [Rule] = [
            .object(ObjectRule(path: "$", properties: ["content"], optional: nil)),
            .yorkie(YorkieTypeRule(
                path: "$.content",
                type: .yorkie(.tree),
                treeNodes: nil
            ))
        ]

        let text = schemaTextNode("hello")
        let customNode = try schemaElementNode("anything", children: [text])
        let root = try schemaElementNode("root", children: [customNode])
        let tree = CRDTTree(root: root, createdAt: timeT())
        let obj = objectWithTree(key: "content", tree: tree)

        // when
        let result = RulesetValidator.validateYorkieRuleset(data: obj, ruleset: noTreeNodesRules)

        // then
        XCTAssertTrue(result.valid)
    }
}
