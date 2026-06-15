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

/// `ContentExpr` is a parsed ProseMirror-compatible content expression.
///
/// Content expressions define what children a node can contain, using the grammar:
/// ```
/// expr       -> sequence ('|' sequence)*     // alternatives
/// sequence   -> element+                     // sequence
/// element    -> atom quantifier?             // element + quantifier
/// atom       -> name | '(' expr ')'          // node type or group
/// quantifier -> '+' | '*' | '?'              // 1+, 0+, 0-1
/// ```
indirect enum ContentExpr {
    case node(nodeType: String)
    case sequence([ContentExpr])
    case alternative([ContentExpr])
    /// A repetition of an expression. `max == Int.max` represents an unbounded (`*`/`+`) upper bound.
    case repeating(ContentExpr, min: Int, max: Int)
}

private enum Token: Equatable {
    case name(String)
    case plus
    case star
    case question
    case pipe
    case lparen
    case rparen

    var display: String {
        switch self {
        case .name(let value): return value
        case .plus: return "+"
        case .star: return "*"
        case .question: return "?"
        case .pipe: return "|"
        case .lparen: return "("
        case .rparen: return ")"
        }
    }
}

private extension Character {
    /// Matches the JS tokenizer's `[a-zA-Z0-9_]` (ASCII only).
    var isContentNameChar: Bool {
        self == "_" || (self.isASCII && (self.isLetter || self.isNumber))
    }
}

/// `tokenize` splits a content expression string into tokens.
private func tokenize(_ expr: String) throws -> [Token] {
    var tokens: [Token] = []
    let chars = Array(expr)
    var index = 0
    while index < chars.count {
        let char = chars[index]
        if char.isWhitespace {
            index += 1
            continue
        }
        switch char {
        case "+": tokens.append(.plus); index += 1
        case "*": tokens.append(.star); index += 1
        case "?": tokens.append(.question); index += 1
        case "|": tokens.append(.pipe); index += 1
        case "(": tokens.append(.lparen); index += 1
        case ")": tokens.append(.rparen); index += 1
        default:
            var name = ""
            while index < chars.count, chars[index].isContentNameChar {
                name.append(chars[index])
                index += 1
            }
            if name.isEmpty {
                throw YorkieError(code: .errInvalidArgument, message: "Unexpected character '\(char)' at position \(index) in content expression")
            }
            tokens.append(.name(name))
        }
    }
    return tokens
}

/// `parseAlternatives` parses alternatives separated by `|`.
private func parseAlternatives(_ tokens: [Token], _ pos: Int) throws -> (expr: ContentExpr, pos: Int) {
    var seqs: [ContentExpr] = []
    var result = try parseSequence(tokens, pos)
    seqs.append(result.expr)
    while result.pos < tokens.count, tokens[result.pos] == .pipe {
        result = try parseSequence(tokens, result.pos + 1)
        seqs.append(result.expr)
    }
    if seqs.count == 1 {
        return (seqs[0], result.pos)
    }
    return (.alternative(seqs), result.pos)
}

/// `parseSequence` parses a sequence of elements.
private func parseSequence(_ tokens: [Token], _ pos: Int) throws -> (expr: ContentExpr, pos: Int) {
    var pos = pos
    var elements: [ContentExpr] = []
    while pos < tokens.count, tokens[pos] != .pipe, tokens[pos] != .rparen {
        let result = try parseElement(tokens, pos)
        elements.append(result.expr)
        pos = result.pos
    }
    if elements.count == 1 {
        return (elements[0], pos)
    }
    return (.sequence(elements), pos)
}

/// `parseElement` parses an atom optionally followed by a quantifier.
private func parseElement(_ tokens: [Token], _ pos: Int) throws -> (expr: ContentExpr, pos: Int) {
    let result = try parseAtom(tokens, pos)
    var expr = result.expr
    var pos = result.pos
    if pos < tokens.count {
        switch tokens[pos] {
        case .plus:
            expr = .repeating(expr, min: 1, max: Int.max)
            pos += 1
        case .star:
            expr = .repeating(expr, min: 0, max: Int.max)
            pos += 1
        case .question:
            expr = .repeating(expr, min: 0, max: 1)
            pos += 1
        default:
            break
        }
    }
    return (expr, pos)
}

/// `parseAtom` parses a name or a parenthesized sub-expression.
private func parseAtom(_ tokens: [Token], _ pos: Int) throws -> (expr: ContentExpr, pos: Int) {
    guard pos < tokens.count else {
        throw YorkieError(code: .errInvalidArgument, message: "Unexpected end of content expression")
    }
    if tokens[pos] == .lparen {
        let result = try parseAlternatives(tokens, pos + 1)
        guard result.pos < tokens.count, tokens[result.pos] == .rparen else {
            throw YorkieError(code: .errInvalidArgument, message: "Unmatched parenthesis in content expression")
        }
        return (result.expr, result.pos + 1)
    }
    guard case .name(let name) = tokens[pos] else {
        throw YorkieError(code: .errInvalidArgument, message: "Expected node type name but got '\(tokens[pos].display)' in content expression")
    }
    return (.node(nodeType: name), pos + 1)
}

/// `parseContentExpression` parses a ProseMirror-compatible content expression string into a
/// ``ContentExpr``.
///
/// Examples:
/// - `"paragraph+"` → 1+ paragraphs
/// - `"text*"` → 0+ text nodes
/// - `"heading paragraph+"` → one heading then 1+ paragraphs
/// - `"paragraph | heading"` → one paragraph or one heading
/// - `"(paragraph | heading)+"` → 1+ of paragraph or heading
/// - `"block+"` → 1+ nodes from the "block" group (resolved via the group resolver)
///
/// - Parameter expr: The content expression string.
/// - Returns: The parsed expression tree.
/// - Throws: ``YorkieError`` when the expression is malformed.
func parseContentExpression(_ expr: String) throws -> ContentExpr {
    let trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return .sequence([])
    }
    let tokens = try tokenize(trimmed)
    let result = try parseAlternatives(tokens, 0)
    if result.pos < tokens.count {
        throw YorkieError(code: .errInvalidArgument, message: "Unexpected token '\(tokens[result.pos].display)' at position \(result.pos) in content expression")
    }
    return result.expr
}

/// `matchExpr` attempts to match child types starting at any of the given positions against the
/// expression, returning the set of all reachable positions after matching (enabling backtracking
/// for ambiguous expressions such as `a* a`).
private func matchExpr(
    _ expr: ContentExpr,
    _ types: [String],
    _ positions: Set<Int>,
    _ resolver: (String) -> [String]
) -> Set<Int> {
    switch expr {
    case .node(let nodeType):
        let allowed = resolver(nodeType)
        var result = Set<Int>()
        for pos in positions where pos < types.count && allowed.contains(types[pos]) {
            result.insert(pos + 1)
        }
        return result
    case .sequence(let children):
        var current = positions
        for child in children {
            current = matchExpr(child, types, current, resolver)
            if current.isEmpty {
                return current
            }
        }
        return current
    case .alternative(let children):
        var result = Set<Int>()
        for child in children {
            for pos in matchExpr(child, types, positions, resolver) {
                result.insert(pos)
            }
        }
        return result
    case .repeating(let child, let min, let max):
        var current = positions
        var reachable = Set<Int>()
        if min == 0 {
            for pos in current {
                reachable.insert(pos)
            }
        }
        var count = 1
        while count <= max {
            let next = matchExpr(child, types, current, resolver)
            // Drop positions already seen (unless still below `min`) to avoid infinite loops.
            var newPositions = Set<Int>()
            for pos in next where !reachable.contains(pos) || count < min {
                newPositions.insert(pos)
            }
            if newPositions.isEmpty {
                break
            }
            current = newPositions
            if count >= min {
                for pos in current {
                    reachable.insert(pos)
                }
            }
            count += 1
        }
        return reachable
    }
}

/// `matchContentExpression` matches an array of child type names against a parsed content
/// expression, using `groupResolver` to resolve group names (like "block") to concrete node types.
///
/// - Parameters:
///   - expr: The parsed content expression.
///   - childTypes: The ordered child node type names.
///   - groupResolver: Resolves a name to the node types in that group (or `[name]` if not a group).
/// - Returns: `(valid: true, error: nil)` if the children match, otherwise a descriptive error.
func matchContentExpression(
    _ expr: ContentExpr,
    _ childTypes: [String],
    _ groupResolver: (String) -> [String]
) -> (valid: Bool, error: String?) {
    let positions = matchExpr(expr, childTypes, Set([0]), groupResolver)
    if positions.contains(childTypes.count) {
        return (true, nil)
    }
    if positions.isEmpty {
        return (false, "Children do not match content expression")
    }
    return (false, "Unexpected child at position \(positions.max() ?? 0)")
}
