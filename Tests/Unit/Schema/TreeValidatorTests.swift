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

// MARK: - Tree building helpers

/// Creates a `CRDTTreeNode` of type `"text"` with the given string value and optional attributes.
private func makeTextNode(_ value: String, attrs: RHT? = nil) -> CRDTTreeNode {
    CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: value as NSString, attributes: attrs)
}

/// Creates a `CRDTTreeNode` element of the given type and appends `children` into it.
private func makeElementNode(_ type: String, children: [CRDTTreeNode]) throws -> CRDTTreeNode {
    let node = CRDTTreeNode(id: posT(), type: type, children: [])
    try node.append(contentsOf: children)
    return node
}

// MARK: - buildGroupResolver tests

final class BuildGroupResolverTests: XCTestCase {
    func test_should_resolve_group_names_to_node_types() {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "paragraph", content: "text*", marks: "", group: "block"),
            TreeNodeRule(nodeType: "heading", content: "text*", marks: "", group: "block"),
            TreeNodeRule(nodeType: "blockquote", content: "block+", marks: "", group: "block")
        ]

        // when
        let resolver = buildGroupResolver(rules)

        // then
        let resolved = resolver("block").sorted()
        XCTAssertEqual(resolved, ["blockquote", "heading", "paragraph"])
    }

    func test_should_return_the_name_itself_if_not_a_group() {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "paragraph", content: "text*", marks: "", group: "block")
        ]

        // when
        let resolver = buildGroupResolver(rules)

        // then
        XCTAssertEqual(resolver("paragraph"), ["paragraph"])
        XCTAssertEqual(resolver("unknown"), ["unknown"])
    }

    func test_should_handle_nodes_with_multiple_groups() {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "paragraph", content: "text*", marks: "", group: "block flow")
        ]

        // when
        let resolver = buildGroupResolver(rules)

        // then
        XCTAssertEqual(resolver("block"), ["paragraph"])
        XCTAssertEqual(resolver("flow"), ["paragraph"])
    }

    func test_should_handle_empty_group() {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "paragraph", content: "text*", marks: "", group: "")
        ]

        // when
        let resolver = buildGroupResolver(rules)

        // then
        XCTAssertEqual(resolver("paragraph"), ["paragraph"])
    }
}

// MARK: - validateTreeAgainstSchema tests

final class ValidateTreeAgainstSchemaTests: XCTestCase {
    private let docRules: [TreeNodeRule] = [
        TreeNodeRule(nodeType: "doc", content: "paragraph+", marks: "", group: ""),
        TreeNodeRule(nodeType: "paragraph", content: "text*", marks: "", group: "")
    ]

    func test_should_validate_a_valid_tree_doc_paragraph_text() throws {
        // given
        let text = makeTextNode("hello")
        let para = try makeElementNode("paragraph", children: [text])
        let root = try makeElementNode("doc", children: [para])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, docRules)

        // then
        XCTAssertTrue(result.valid)
        XCTAssertNil(result.error)
    }

    func test_should_validate_a_tree_with_multiple_paragraphs() throws {
        // given
        let text1 = makeTextNode("hello")
        let text2 = makeTextNode("world")
        let para1 = try makeElementNode("paragraph", children: [text1])
        let para2 = try makeElementNode("paragraph", children: [text2])
        let root = try makeElementNode("doc", children: [para1, para2])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, docRules)

        // then
        XCTAssertTrue(result.valid)
    }

    func test_should_reject_unknown_node_type() throws {
        // given
        let text = makeTextNode("hello")
        let div = try makeElementNode("div", children: [text])
        let root = try makeElementNode("doc", children: [div])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, docRules)

        // then
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.error?.contains("Unknown node type") ?? false)
        XCTAssertTrue(result.error?.contains("div") ?? false)
    }

    func test_should_reject_content_expression_violation_doc_requires_paragraph_plus_but_has_none() throws {
        // given
        let root = try makeElementNode("doc", children: [])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, docRules)

        // then
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.error?.contains("doc") ?? false)
    }

    func test_should_reject_content_expression_violation_wrong_child_type() throws {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "doc", content: "paragraph+", marks: "", group: ""),
            TreeNodeRule(nodeType: "paragraph", content: "text*", marks: "", group: ""),
            TreeNodeRule(nodeType: "heading", content: "text*", marks: "", group: "")
        ]
        let text = makeTextNode("hello")
        let heading = try makeElementNode("heading", children: [text])
        let root = try makeElementNode("doc", children: [heading])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, rules)

        // then
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.error?.contains("doc") ?? false)
    }

    func test_should_validate_with_group_resolver() throws {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "doc", content: "block+", marks: "", group: ""),
            TreeNodeRule(nodeType: "paragraph", content: "text*", marks: "", group: "block"),
            TreeNodeRule(nodeType: "heading", content: "text*", marks: "", group: "block")
        ]
        let text1 = makeTextNode("hello")
        let text2 = makeTextNode("world")
        let para = try makeElementNode("paragraph", children: [text1])
        let heading = try makeElementNode("heading", children: [text2])
        let root = try makeElementNode("doc", children: [para, heading])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, rules)

        // then
        XCTAssertTrue(result.valid)
    }

    func test_should_validate_an_empty_content_expression_no_children_required() throws {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "doc", content: "paragraph+", marks: "", group: ""),
            TreeNodeRule(nodeType: "paragraph", content: "", marks: "", group: "")
        ]
        let para = try makeElementNode("paragraph", children: [])
        let root = try makeElementNode("doc", children: [para])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, rules)

        // then
        XCTAssertTrue(result.valid)
    }

    func test_should_validate_marks_on_text_children() throws {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "doc", content: "heading+", marks: "", group: ""),
            TreeNodeRule(nodeType: "heading", content: "text*", marks: "bold", group: "")
        ]
        let boldAttr = RHT()
        boldAttr.set(key: "bold", value: "\"true\"", executedAt: timeT())
        let text = makeTextNode("hello", attrs: boldAttr)
        let heading = try makeElementNode("heading", children: [text])
        let root = try makeElementNode("doc", children: [heading])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, rules)

        // then
        XCTAssertTrue(result.valid)
    }

    func test_should_reject_disallowed_marks_on_text_children() throws {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "doc", content: "heading+", marks: "", group: ""),
            TreeNodeRule(nodeType: "heading", content: "text*", marks: "bold", group: "")
        ]
        let italicAttr = RHT()
        italicAttr.set(key: "italic", value: "\"true\"", executedAt: timeT())
        let text = makeTextNode("hello", attrs: italicAttr)
        let heading = try makeElementNode("heading", children: [text])
        let root = try makeElementNode("doc", children: [heading])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, rules)

        // then
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.error?.contains("disallowed mark") ?? false)
        XCTAssertTrue(result.error?.contains("italic") ?? false)
    }

    func test_should_allow_multiple_valid_marks() throws {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "doc", content: "paragraph+", marks: "", group: ""),
            TreeNodeRule(nodeType: "paragraph", content: "text*", marks: "bold italic underline", group: "")
        ]
        let attrs = RHT()
        attrs.set(key: "bold", value: "\"true\"", executedAt: timeT())
        attrs.set(key: "italic", value: "\"true\"", executedAt: timeT())
        let text = makeTextNode("hello", attrs: attrs)
        let para = try makeElementNode("paragraph", children: [text])
        let root = try makeElementNode("doc", children: [para])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, rules)

        // then
        XCTAssertTrue(result.valid)
    }

    func test_should_validate_deeply_nested_trees() throws {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "doc", content: "section+", marks: "", group: ""),
            TreeNodeRule(nodeType: "section", content: "paragraph+", marks: "", group: ""),
            TreeNodeRule(nodeType: "paragraph", content: "text*", marks: "", group: "")
        ]
        let text = makeTextNode("hello")
        let para = try makeElementNode("paragraph", children: [text])
        let section = try makeElementNode("section", children: [para])
        let root = try makeElementNode("doc", children: [section])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, rules)

        // then
        XCTAssertTrue(result.valid)
    }

    func test_should_detect_errors_in_nested_children() throws {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "doc", content: "section+", marks: "", group: ""),
            TreeNodeRule(nodeType: "section", content: "paragraph+", marks: "", group: ""),
            TreeNodeRule(nodeType: "paragraph", content: "text*", marks: "", group: "")
        ]
        // section with no children (requires paragraph+)
        let section = try makeElementNode("section", children: [])
        let root = try makeElementNode("doc", children: [section])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, rules)

        // then
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.error?.contains("section") ?? false)
    }

    // Mirrors JS: "should skip mark validation when marks rule is empty".
    // An empty `marks` string is treated as "no marks rule" (the validator skips it, matching the
    // JS truthy check), so a text child with any mark passes.
    func test_should_skip_mark_validation_when_marks_rule_is_empty() throws {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "doc", content: "paragraph+", marks: "", group: ""),
            TreeNodeRule(nodeType: "paragraph", content: "text*", marks: "", group: "")
        ]
        // Text node with marks but paragraph has marks: "" — validation is skipped, so it passes.
        let attrs = RHT()
        attrs.set(key: "bold", value: "\"true\"", executedAt: timeT())
        let text = makeTextNode("hello", attrs: attrs)
        let para = try makeElementNode("paragraph", children: [text])
        let root = try makeElementNode("doc", children: [para])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, rules)

        // then
        XCTAssertTrue(result.valid)
    }

    func test_should_handle_alternative_content_expressions() throws {
        // given
        let rules: [TreeNodeRule] = [
            TreeNodeRule(nodeType: "doc", content: "(paragraph | heading)+", marks: "", group: ""),
            TreeNodeRule(nodeType: "paragraph", content: "text*", marks: "", group: ""),
            TreeNodeRule(nodeType: "heading", content: "text*", marks: "", group: "")
        ]
        let text1 = makeTextNode("hello")
        let text2 = makeTextNode("title")
        let para = try makeElementNode("paragraph", children: [text1])
        let heading = try makeElementNode("heading", children: [text2])
        let root = try makeElementNode("doc", children: [para, heading])
        let tree = CRDTTree(root: root, createdAt: timeT())

        // when
        let result = validateTreeAgainstSchema(tree, rules)

        // then
        XCTAssertTrue(result.valid)
    }
}
