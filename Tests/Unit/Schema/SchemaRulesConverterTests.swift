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

final class SchemaRulesConverterTests: XCTestCase {
    // Guards the proto→model boundary for tree node rules: `content` must keep its raw value
    // (including "" — which means "no children allowed"), while empty `marks`/`group` become nil
    // (treated as "no rule"). Non-empty values pass through unchanged.
    func test_fromSchemaRules_maps_tree_node_rule_empty_strings() {
        // given — a yorkie.Tree rule with two tree nodes: one all-empty, one fully populated
        var emptyNode = Yorkie_V1_TreeNodeRule()
        emptyNode.nodeType = "doc"
        emptyNode.content = ""
        emptyNode.marks = ""
        emptyNode.group = ""

        var filledNode = Yorkie_V1_TreeNodeRule()
        filledNode.nodeType = "paragraph"
        filledNode.content = "text*"
        filledNode.marks = "bold italic"
        filledNode.group = "block"

        var pbRule = Yorkie_V1_Rule()
        pbRule.path = "$.tree"
        pbRule.type = "yorkie.Tree"
        pbRule.treeNodes = [emptyNode, filledNode]

        // when
        let rules = Converter.fromSchemaRules([pbRule])

        // then
        XCTAssertEqual(rules.count, 1)
        guard let treeNodes = rules.first?.treeNodes else {
            return XCTFail("expected treeNodes on the yorkie.Tree rule")
        }
        XCTAssertEqual(treeNodes.count, 2)

        // content is retained even when empty ("" = no children allowed); marks/group → nil.
        XCTAssertEqual(treeNodes[0].nodeType, "doc")
        XCTAssertEqual(treeNodes[0].content, "")
        XCTAssertNil(treeNodes[0].marks)
        XCTAssertNil(treeNodes[0].group)

        // non-empty values pass through unchanged.
        XCTAssertEqual(treeNodes[1].nodeType, "paragraph")
        XCTAssertEqual(treeNodes[1].content, "text*")
        XCTAssertEqual(treeNodes[1].marks, "bold italic")
        XCTAssertEqual(treeNodes[1].group, "block")
    }

    func test_fromSchemaRules_tree_rule_without_tree_nodes_has_nil_treeNodes() {
        // given — a yorkie.Tree rule with no tree nodes
        var pbRule = Yorkie_V1_Rule()
        pbRule.path = "$.tree"
        pbRule.type = "yorkie.Tree"

        // when
        let rules = Converter.fromSchemaRules([pbRule])

        // then — treeNodes is nil (no tree-level schema), so validation is skipped
        XCTAssertEqual(rules.count, 1)
        XCTAssertNil(rules.first?.treeNodes)
    }
}
