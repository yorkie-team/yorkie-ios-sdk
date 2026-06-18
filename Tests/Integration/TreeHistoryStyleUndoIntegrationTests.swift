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
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

// MARK: - Helpers

/// Returns the XML of the `t` field in the document root.
///
/// Mirrors `xmlOf` from the JS test file. Defined as a file-private helper to
/// avoid collision with the identical private helper in other files in this
/// test target (each file has its own file-private scope).
@MainActor
private func styleTreeXML(_ doc: Document) -> String {
    (doc.getRoot().t as? JSONTree)?.toXML() ?? ""
}

/// Creates the initial tree used by the style undo/redo tests.
///
/// Mirrors `makeTree` in the JS test:
/// ```
/// <doc>
///   <p bold="true">AB</p>
///   <p>CD</p>
/// </doc>
/// ```
@MainActor
private func makeStyleTree(_ doc: Document) throws {
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot:
            JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(
                    type: "p",
                    children: [JSONTreeTextNode(value: "AB")],
                    attributes: ["bold": "true"]
                ),
                JSONTreeElementNode(
                    type: "p",
                    children: [JSONTreeTextNode(value: "CD")]
                )
            ])
        )
    }
}

/// Named style operations mirroring the JS `StyleOp` union.
private enum StyleOp: String, CaseIterable {
    case setBold = "set-bold"
    case setItalic = "set-italic"
    case setColor = "set-color"
    case removeBold = "remove-bold"
}

/// Applies a named style operation on the first (or second) element.
///
/// - set-bold  → `style(0, 1, {bold: "true"})`   (first <p>)
/// - set-italic → `style(0, 1, {italic: "true"})`  (first <p>)
/// - set-color → `style(3, 4, {color: "red"})`   (second <p>)
/// - remove-bold → `removeStyle(0, 1, ["bold"])`    (first <p>)
@MainActor
private func applyStyleOp(_ doc: Document, _ op: StyleOp) throws {
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        switch op {
        case .setBold:
            try tree.style(0, 1, ["bold": "true"])
        case .setItalic:
            try tree.style(0, 1, ["italic": "true"])
        case .setColor:
            try tree.style(3, 4, ["color": "red"])
        case .removeBold:
            try tree.removeStyle(0, 1, ["bold"])
        }
    }
}

// MARK: - 5a. Single-client style undo/redo

//
// Ports: "Tree History - tree style undo/redo" – 5a. Single-client style
// undo/redo (v0.7.5, lines 1506–1528).

final class TreeStyleUndoRedoSingleClientTests: XCTestCase {
    // Ports: "should undo/redo: set-bold"
    @MainActor
    func test_can_undo_redo_set_bold() throws {
        try self.runStyleUndoRedoTest(.setBold)
    }

    // Ports: "should undo/redo: set-italic"
    @MainActor
    func test_can_undo_redo_set_italic() throws {
        try self.runStyleUndoRedoTest(.setItalic)
    }

    // Ports: "should undo/redo: set-color"
    @MainActor
    func test_can_undo_redo_set_color() throws {
        try self.runStyleUndoRedoTest(.setColor)
    }

    // Ports: "should undo/redo: remove-bold"
    @MainActor
    func test_can_undo_redo_remove_bold() throws {
        try self.runStyleUndoRedoTest(.removeBold)
    }

    // MARK: - shared helper

    @MainActor
    private func runStyleUndoRedoTest(_ op: StyleOp) throws {
        // given
        let doc = Document(key: "style-undo-\(op.rawValue)".toDocKey)
        try makeStyleTree(doc)
        let s0 = styleTreeXML(doc)

        // when
        try applyStyleOp(doc, op)
        let s1 = styleTreeXML(doc)

        // then
        try doc.undo()
        XCTAssertEqual(styleTreeXML(doc), s0, "undo \(op.rawValue) failed")

        try doc.redo()
        XCTAssertEqual(styleTreeXML(doc), s1, "redo \(op.rawValue) failed")
    }
}

// MARK: - 5b. Single-client chained style ops

//
// Ports: "Tree History - tree style undo/redo" – 5b. Chained style ops
// (v0.7.5, lines 1529–1554).
//
// The JS test skips the (remove-bold, remove-bold) combo because the second
// remove is a no-op and does not push an entry onto the undo stack. We match
// that behaviour by omitting the same case.

final class TreeHistoryStyleUndoRedoChainedTests: XCTestCase {
    // All valid (op1, op2) pairs except (remove-bold, remove-bold).

    @MainActor func test_can_undo_chain_setBold_setItalic() throws { try self.runChain(.setBold, .setItalic) }
    @MainActor func test_can_undo_chain_setBold_setColor() throws { try self.runChain(.setBold, .setColor) }
    @MainActor func test_can_undo_chain_setBold_removeBold() throws { try self.runChain(.setBold, .removeBold) }
    @MainActor func test_can_undo_chain_setBold_setBold() throws { try self.runChain(.setBold, .setBold) }

    @MainActor func test_can_undo_chain_setItalic_setBold() throws { try self.runChain(.setItalic, .setBold) }
    @MainActor func test_can_undo_chain_setItalic_setItalic() throws { try self.runChain(.setItalic, .setItalic) }
    @MainActor func test_can_undo_chain_setItalic_setColor() throws { try self.runChain(.setItalic, .setColor) }
    @MainActor func test_can_undo_chain_setItalic_removeBold() throws { try self.runChain(.setItalic, .removeBold) }

    @MainActor func test_can_undo_chain_setColor_setBold() throws { try self.runChain(.setColor, .setBold) }
    @MainActor func test_can_undo_chain_setColor_setItalic() throws { try self.runChain(.setColor, .setItalic) }
    @MainActor func test_can_undo_chain_setColor_setColor() throws { try self.runChain(.setColor, .setColor) }
    @MainActor func test_can_undo_chain_setColor_removeBold() throws { try self.runChain(.setColor, .removeBold) }

    @MainActor func test_can_undo_chain_removeBold_setBold() throws { try self.runChain(.removeBold, .setBold) }
    @MainActor func test_can_undo_chain_removeBold_setItalic() throws { try self.runChain(.removeBold, .setItalic) }
    @MainActor func test_can_undo_chain_removeBold_setColor() throws { try self.runChain(.removeBold, .setColor) }
    // (removeBold, removeBold) is intentionally skipped — matches JS test.

    // MARK: - shared helper

    @MainActor
    private func runChain(_ op1: StyleOp, _ op2: StyleOp) throws {
        // given
        let doc = Document(key: "style-chain-\(op1.rawValue)-\(op2.rawValue)".toDocKey)
        try makeStyleTree(doc)

        let s0 = styleTreeXML(doc)
        try applyStyleOp(doc, op1)
        let s1 = styleTreeXML(doc)
        try applyStyleOp(doc, op2)
        let s2 = styleTreeXML(doc)

        // when
        try doc.undo()
        XCTAssertEqual(styleTreeXML(doc), s1, "undo \(op2) failed")
        try doc.undo()
        XCTAssertEqual(styleTreeXML(doc), s0, "undo \(op1) failed")

        // then
        try doc.redo()
        XCTAssertEqual(styleTreeXML(doc), s1, "redo \(op1) failed")
        try doc.redo()
        XCTAssertEqual(styleTreeXML(doc), s2, "redo \(op2) failed")
    }
}

// MARK: - 5c. Single-client style + edit mixed chains

//
// Ports: "Tree History - tree style undo/redo" – 5c. Style + edit mixed
// chains (v0.7.5, lines 1556–1604).

final class TreeHistoryStyleUndoRedoMixedTests: XCTestCase {
    // Ports: "should undo style after edit"
    @MainActor
    func test_can_undo_style_after_edit() throws {
        // given
        let doc = Document(key: "style-after-edit".toDocKey)
        try makeStyleTree(doc)
        let s0 = styleTreeXML(doc)

        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "X"))
        }
        let s1 = styleTreeXML(doc)

        try applyStyleOp(doc, .setItalic)
        let s2 = styleTreeXML(doc)

        // when
        try doc.undo()
        XCTAssertEqual(styleTreeXML(doc), s1, "undo style failed")
        try doc.undo()
        XCTAssertEqual(styleTreeXML(doc), s0, "undo edit failed")

        // then
        try doc.redo()
        XCTAssertEqual(styleTreeXML(doc), s1, "redo edit failed")
        try doc.redo()
        XCTAssertEqual(styleTreeXML(doc), s2, "redo style failed")
    }

    // Ports: "should undo edit after style"
    @MainActor
    func test_can_undo_edit_after_style() throws {
        // given
        let doc = Document(key: "edit-after-style".toDocKey)
        try makeStyleTree(doc)
        let s0 = styleTreeXML(doc)

        try applyStyleOp(doc, .setItalic)
        let s1 = styleTreeXML(doc)

        try doc.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "X"))
        }
        let s2 = styleTreeXML(doc)

        // when
        try doc.undo()
        XCTAssertEqual(styleTreeXML(doc), s1, "undo edit failed")
        try doc.undo()
        XCTAssertEqual(styleTreeXML(doc), s0, "undo style failed")

        // then
        try doc.redo()
        XCTAssertEqual(styleTreeXML(doc), s1, "redo style failed")
        try doc.redo()
        XCTAssertEqual(styleTreeXML(doc), s2, "redo edit failed")
    }
}

// MARK: - 6. Multi-client Style Undo Convergence (table-driven)

//
// Ports: "Tree History - multi client style undo convergence" (v0.7.5, lines 1606–1707).
// Requires a live 0.7.5 yorkie server.

private enum LocalStyleOp: String, CaseIterable {
    case setBold = "set-bold"
    case setItalic = "set-italic"
    case removeBold = "remove-bold"
}

private enum RemoteStyleOp: String, CaseIterable {
    case setColor = "set-color"
    case setBold = "set-bold"
    case removeBold = "remove-bold"
}

private enum StyleTarget: String, CaseIterable {
    case sameElement = "same-element"
    case differentElement = "different-element"
}

@MainActor
private func applyLocalStyleOp(_ doc: Document, _ op: LocalStyleOp) throws {
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        switch op {
        case .setBold:
            try tree.style(0, 1, ["bold": "true"])
        case .setItalic:
            try tree.style(0, 1, ["italic": "true"])
        case .removeBold:
            try tree.removeStyle(0, 1, ["bold"])
        }
    }
}

@MainActor
private func applyRemoteStyleOp(_ doc: Document, _ op: RemoteStyleOp, target: StyleTarget) throws {
    let idx = target == .sameElement ? 0 : 3
    let toIdx = target == .sameElement ? 1 : 4
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        switch op {
        case .setColor:
            try tree.style(idx, toIdx, ["color": "red"])
        case .setBold:
            try tree.style(idx, toIdx, ["bold": "true"])
        case .removeBold:
            try tree.removeStyle(idx, toIdx, ["bold"])
        }
    }
}

final class TreeStyleMultiClientConvergenceTests: XCTestCase {
    // 9 combinations: 3 local × 3 remote × 2 targets = 18 test cases.

    // --- set-bold local ---
    @MainActor func test_converge_local_setBold_remote_setColor_sameElem() async throws {
        try await self.runStyleConvergenceTest(.setBold, .setColor, .sameElement)
    }

    @MainActor func test_converge_local_setBold_remote_setColor_diffElem() async throws {
        try await self.runStyleConvergenceTest(.setBold, .setColor, .differentElement)
    }

    @MainActor func test_converge_local_setBold_remote_setBold_sameElem() async throws {
        try await self.runStyleConvergenceTest(.setBold, .setBold, .sameElement)
    }

    @MainActor func test_converge_local_setBold_remote_setBold_diffElem() async throws {
        try await self.runStyleConvergenceTest(.setBold, .setBold, .differentElement)
    }

    @MainActor func test_converge_local_setBold_remote_removeBold_sameElem() async throws {
        try await self.runStyleConvergenceTest(.setBold, .removeBold, .sameElement)
    }

    @MainActor func test_converge_local_setBold_remote_removeBold_diffElem() async throws {
        try await self.runStyleConvergenceTest(.setBold, .removeBold, .differentElement)
    }

    // --- set-italic local ---
    @MainActor func test_converge_local_setItalic_remote_setColor_sameElem() async throws {
        try await self.runStyleConvergenceTest(.setItalic, .setColor, .sameElement)
    }

    @MainActor func test_converge_local_setItalic_remote_setColor_diffElem() async throws {
        try await self.runStyleConvergenceTest(.setItalic, .setColor, .differentElement)
    }

    @MainActor func test_converge_local_setItalic_remote_setBold_sameElem() async throws {
        try await self.runStyleConvergenceTest(.setItalic, .setBold, .sameElement)
    }

    @MainActor func test_converge_local_setItalic_remote_setBold_diffElem() async throws {
        try await self.runStyleConvergenceTest(.setItalic, .setBold, .differentElement)
    }

    @MainActor func test_converge_local_setItalic_remote_removeBold_sameElem() async throws {
        try await self.runStyleConvergenceTest(.setItalic, .removeBold, .sameElement)
    }

    @MainActor func test_converge_local_setItalic_remote_removeBold_diffElem() async throws {
        try await self.runStyleConvergenceTest(.setItalic, .removeBold, .differentElement)
    }

    // --- remove-bold local ---
    @MainActor func test_converge_local_removeBold_remote_setColor_sameElem() async throws {
        try await self.runStyleConvergenceTest(.removeBold, .setColor, .sameElement)
    }

    @MainActor func test_converge_local_removeBold_remote_setColor_diffElem() async throws {
        try await self.runStyleConvergenceTest(.removeBold, .setColor, .differentElement)
    }

    @MainActor func test_converge_local_removeBold_remote_setBold_sameElem() async throws {
        try await self.runStyleConvergenceTest(.removeBold, .setBold, .sameElement)
    }

    @MainActor func test_converge_local_removeBold_remote_setBold_diffElem() async throws {
        try await self.runStyleConvergenceTest(.removeBold, .setBold, .differentElement)
    }

    @MainActor func test_converge_local_removeBold_remote_removeBold_sameElem() async throws {
        try await self.runStyleConvergenceTest(.removeBold, .removeBold, .sameElement)
    }

    @MainActor func test_converge_local_removeBold_remote_removeBold_diffElem() async throws {
        try await self.runStyleConvergenceTest(.removeBold, .removeBold, .differentElement)
    }

    // MARK: - shared helper

    @MainActor
    private func runStyleConvergenceTest(
        _ localOp: LocalStyleOp,
        _ remoteOp: RemoteStyleOp,
        _ target: StyleTarget
    ) async throws {
        let title = "\(self.description)-\(localOp.rawValue)-\(remoteOp.rawValue)-\(target.rawValue)"
        try await withTwoClientsAndDocuments(title) { c1, d1, c2, d2 in
            // given — initial tree: <doc><p bold="true">AB</p><p>CD</p></doc>
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(
                            type: "p",
                            children: [JSONTreeTextNode(value: "AB")],
                            attributes: ["bold": "true"]
                        ),
                        JSONTreeElementNode(
                            type: "p",
                            children: [JSONTreeTextNode(value: "CD")]
                        )
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            // when — d1: local style op; d2: remote style op (concurrent)
            try applyLocalStyleOp(d1, localOp)
            try applyRemoteStyleOp(d2, remoteOp, target: target)

            // sync
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // d1 undoes its local style
            try d1.undo()

            // sync again
            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            // then — both documents must converge
            XCTAssertEqual(
                styleTreeXML(d1),
                styleTreeXML(d2),
                "divergence: \(localOp.rawValue) + \(remoteOp.rawValue) on \(target.rawValue)"
            )
        }
    }
}

// MARK: - 7. Multi-client Style vs Edit/Split convergence (table-driven)

//
// Ports: "Tree History - multi client style vs edit/split convergence"
// (v0.7.5, lines 1709–1892).
// Requires a live 0.7.5 yorkie server.
//
// Covers two sub-scenarios for each (localStyleOp, remoteEditOp) pair:
// a. local style + remote edit, d1 undoes style.
// b. local edit + remote style, d1 undoes edit.

private enum RemoteEditOp: String, CaseIterable {
    case insertText = "insert-text"
    case deleteText = "delete-text"
    case insertElement = "insert-element"
    case splitL1 = "split-l1"
}

@MainActor
private func applyStyleVsEditRemoteEditOp(_ doc: Document, _ op: RemoteEditOp) throws {
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        switch op {
        case .insertText:
            try tree.edit(1, 1, JSONTreeTextNode(value: "X"))
        case .deleteText:
            try tree.edit(1, 2)
        case .insertElement:
            try tree.edit(6, 6, JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "NEW")]))
        case .splitL1:
            try tree.edit(3, 3, nil, 1)
        }
    }
}

final class TreeStyleVsEditConvergenceTests: XCTestCase {
    // 3 local × 4 remote × 2 directions = 24 test cases.

    // --- set-bold local vs remote edit ---
    @MainActor func test_converge_style_setBold_plus_edit_insertText() async throws {
        try await self.runStyleVsEditTest(.setBold, .insertText)
    }

    @MainActor func test_converge_style_setBold_plus_edit_deleteText() async throws {
        try await self.runStyleVsEditTest(.setBold, .deleteText)
    }

    @MainActor func test_converge_style_setBold_plus_edit_insertElement() async throws {
        try await self.runStyleVsEditTest(.setBold, .insertElement)
    }

    @MainActor func test_converge_style_setBold_plus_edit_splitL1() async throws {
        try await self.runStyleVsEditTest(.setBold, .splitL1)
    }

    // --- set-italic local vs remote edit ---
    @MainActor func test_converge_style_setItalic_plus_edit_insertText() async throws {
        try await self.runStyleVsEditTest(.setItalic, .insertText)
    }

    @MainActor func test_converge_style_setItalic_plus_edit_deleteText() async throws {
        try await self.runStyleVsEditTest(.setItalic, .deleteText)
    }

    @MainActor func test_converge_style_setItalic_plus_edit_insertElement() async throws {
        try await self.runStyleVsEditTest(.setItalic, .insertElement)
    }

    @MainActor func test_converge_style_setItalic_plus_edit_splitL1() async throws {
        try await self.runStyleVsEditTest(.setItalic, .splitL1)
    }

    // --- remove-bold local vs remote edit ---
    @MainActor func test_converge_style_removeBold_plus_edit_insertText() async throws {
        try await self.runStyleVsEditTest(.removeBold, .insertText)
    }

    @MainActor func test_converge_style_removeBold_plus_edit_deleteText() async throws {
        try await self.runStyleVsEditTest(.removeBold, .deleteText)
    }

    @MainActor func test_converge_style_removeBold_plus_edit_insertElement() async throws {
        try await self.runStyleVsEditTest(.removeBold, .insertElement)
    }

    @MainActor func test_converge_style_removeBold_plus_edit_splitL1() async throws {
        try await self.runStyleVsEditTest(.removeBold, .splitL1)
    }

    // --- reverse direction: local edit + remote style, undo edit ---

    @MainActor func test_converge_edit_insertText_plus_style_setBold() async throws {
        try await self.runEditVsStyleTest(.insertText, .setBold)
    }

    @MainActor func test_converge_edit_deleteText_plus_style_setBold() async throws {
        try await self.runEditVsStyleTest(.deleteText, .setBold)
    }

    @MainActor func test_converge_edit_insertElement_plus_style_setBold() async throws {
        try await self.runEditVsStyleTest(.insertElement, .setBold)
    }

    @MainActor func test_converge_edit_splitL1_plus_style_setBold() async throws {
        try await self.runEditVsStyleTest(.splitL1, .setBold)
    }

    @MainActor func test_converge_edit_insertText_plus_style_setItalic() async throws {
        try await self.runEditVsStyleTest(.insertText, .setItalic)
    }

    @MainActor func test_converge_edit_deleteText_plus_style_setItalic() async throws {
        try await self.runEditVsStyleTest(.deleteText, .setItalic)
    }

    @MainActor func test_converge_edit_insertElement_plus_style_setItalic() async throws {
        try await self.runEditVsStyleTest(.insertElement, .setItalic)
    }

    @MainActor func test_converge_edit_splitL1_plus_style_setItalic() async throws {
        try await self.runEditVsStyleTest(.splitL1, .setItalic)
    }

    @MainActor func test_converge_edit_insertText_plus_style_removeBold() async throws {
        try await self.runEditVsStyleTest(.insertText, .removeBold)
    }

    @MainActor func test_converge_edit_deleteText_plus_style_removeBold() async throws {
        try await self.runEditVsStyleTest(.deleteText, .removeBold)
    }

    @MainActor func test_converge_edit_insertElement_plus_style_removeBold() async throws {
        try await self.runEditVsStyleTest(.insertElement, .removeBold)
    }

    @MainActor func test_converge_edit_splitL1_plus_style_removeBold() async throws {
        try await self.runEditVsStyleTest(.splitL1, .removeBold)
    }

    // MARK: - shared helpers

    /// d1 applies a style op; d2 applies a concurrent edit op. d1 then undoes its style.
    @MainActor
    private func runStyleVsEditTest(_ localOp: LocalStyleOp, _ remoteOp: RemoteEditOp) async throws {
        let title = "\(self.description)-style-\(localOp.rawValue)-edit-\(remoteOp.rawValue)"
        try await withTwoClientsAndDocuments(title) { c1, d1, c2, d2 in
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(
                            type: "p",
                            children: [JSONTreeTextNode(value: "ABCD")],
                            attributes: ["bold": "true"]
                        ),
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "EFGH")])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            try applyLocalStyleOp(d1, localOp)
            try applyStyleVsEditRemoteEditOp(d2, remoteOp)

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            try d1.undo()

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            XCTAssertEqual(
                styleTreeXML(d1),
                styleTreeXML(d2),
                "divergence: style(\(localOp.rawValue)) + edit(\(remoteOp.rawValue))"
            )
        }
    }

    /// d1 applies an edit op; d2 applies a concurrent style op. d1 then undoes its edit.
    @MainActor
    private func runEditVsStyleTest(_ localEditOp: RemoteEditOp, _ remoteStyleOp: LocalStyleOp) async throws {
        let title = "\(self.description)-edit-\(localEditOp.rawValue)-style-\(remoteStyleOp.rawValue)"
        try await withTwoClientsAndDocuments(title) { c1, d1, c2, d2 in
            try d1.update { root, _ in
                root.t = JSONTree(initialRoot:
                    JSONTreeElementNode(type: "doc", children: [
                        JSONTreeElementNode(
                            type: "p",
                            children: [JSONTreeTextNode(value: "ABCD")],
                            attributes: ["bold": "true"]
                        ),
                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "EFGH")])
                    ])
                )
            }
            try await c1.sync()
            try await c2.sync()

            try applyStyleVsEditRemoteEditOp(d1, localEditOp)
            try applyLocalStyleOp(d2, remoteStyleOp)

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            try d1.undo()

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            XCTAssertEqual(
                styleTreeXML(d1),
                styleTreeXML(d2),
                "divergence: edit(\(localEditOp.rawValue)) + style(\(remoteStyleOp.rawValue))"
            )
        }
    }
}
