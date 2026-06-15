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

final class ContentExpressionTests: XCTestCase {
    // A resolver that treats every name as exactly that one type (no group expansion).
    private let identity: (String) -> [String] = { [$0] }
}

// MARK: - Content Expression Parser

extension ContentExpressionTests {
    func test_should_match_simple_type() throws {
        // given
        let expr = try parseContentExpression("paragraph")

        // then
        XCTAssertTrue(matchContentExpression(expr, ["paragraph"], self.identity).valid)
        XCTAssertFalse(matchContentExpression(expr, ["heading"], self.identity).valid)
        XCTAssertFalse(matchContentExpression(expr, [], self.identity).valid)
    }

    func test_should_match_plus_quantifier_one_or_more() throws {
        // given
        let expr = try parseContentExpression("paragraph+")

        // then
        XCTAssertTrue(matchContentExpression(expr, ["paragraph"], self.identity).valid)
        XCTAssertTrue(matchContentExpression(expr, ["paragraph", "paragraph"], self.identity).valid)
        XCTAssertFalse(matchContentExpression(expr, [], self.identity).valid)
    }

    func test_should_match_star_quantifier_zero_or_more() throws {
        // given
        let expr = try parseContentExpression("text*")

        // then
        XCTAssertTrue(matchContentExpression(expr, [], self.identity).valid)
        XCTAssertTrue(matchContentExpression(expr, ["text", "text"], self.identity).valid)
        XCTAssertFalse(matchContentExpression(expr, ["paragraph"], self.identity).valid)
    }

    // Regression: the ambiguous `a* a` is the reason the matcher tracks a set of reachable
    // positions (backtracking) rather than a single position. `a*` must be able to consume zero
    // repetitions so the trailing `a` can match.
    func test_should_match_ambiguous_star_followed_by_same_type() throws {
        // given
        let expr = try parseContentExpression("a* a")

        // then
        XCTAssertTrue(matchContentExpression(expr, ["a"], self.identity).valid)
        XCTAssertTrue(matchContentExpression(expr, ["a", "a"], self.identity).valid)
        XCTAssertTrue(matchContentExpression(expr, ["a", "a", "a"], self.identity).valid)
        XCTAssertFalse(matchContentExpression(expr, [], self.identity).valid)
        XCTAssertFalse(matchContentExpression(expr, ["b"], self.identity).valid)
    }

    func test_should_match_question_quantifier_zero_or_one() throws {
        // given
        let expr = try parseContentExpression("title?")

        // then
        XCTAssertTrue(matchContentExpression(expr, [], self.identity).valid)
        XCTAssertTrue(matchContentExpression(expr, ["title"], self.identity).valid)
        XCTAssertFalse(matchContentExpression(expr, ["title", "title"], self.identity).valid)
    }

    func test_should_match_sequence() throws {
        // given
        let expr = try parseContentExpression("heading paragraph+")

        // then
        XCTAssertTrue(matchContentExpression(expr, ["heading", "paragraph"], self.identity).valid)
        XCTAssertTrue(matchContentExpression(expr, ["heading", "paragraph", "paragraph"], self.identity).valid)
        XCTAssertFalse(matchContentExpression(expr, ["paragraph"], self.identity).valid)
    }

    func test_should_match_alternatives() throws {
        // given
        let expr = try parseContentExpression("paragraph | heading")

        // then
        XCTAssertTrue(matchContentExpression(expr, ["paragraph"], self.identity).valid)
        XCTAssertTrue(matchContentExpression(expr, ["heading"], self.identity).valid)
        XCTAssertFalse(matchContentExpression(expr, ["blockquote"], self.identity).valid)
    }

    func test_should_match_grouped_alternatives_with_quantifier() throws {
        // given
        let expr = try parseContentExpression("(paragraph | heading)+")

        // then
        XCTAssertTrue(matchContentExpression(expr, ["paragraph", "heading", "paragraph"], self.identity).valid)
        XCTAssertFalse(matchContentExpression(expr, [], self.identity).valid)
    }

    func test_should_resolve_groups() throws {
        // given
        let resolver: (String) -> [String] = { name in
            name == "block" ? ["paragraph", "heading", "blockquote"] : [name]
        }
        let expr = try parseContentExpression("block+")

        // then
        XCTAssertTrue(matchContentExpression(expr, ["paragraph", "heading"], resolver).valid)
        XCTAssertFalse(matchContentExpression(expr, ["inline"], resolver).valid)
    }
}
