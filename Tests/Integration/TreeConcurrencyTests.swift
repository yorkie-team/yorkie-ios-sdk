/*
 * Copyright 2024 The Yorkie Authors. All rights reserved.
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

func parseSimpleXML(_ string: String) -> [String] {
    var res: [String] = []
    var index = string.startIndex

    while index < string.endIndex {
        var now = ""

        if string[index] == "<" {
            while index < string.endIndex, string[index] != ">" {
                now.append(string[index])
                index = string.index(after: index)
            }
        }

        if index < string.endIndex {
            now.append(string[index])
            index = string.index(after: index)
        }

        res.append(now)
    }

    return res
}

struct TestResult {
    let before: (String, String)
    let after: (String, String)
}

enum RangeSelector {
    case rangeUnknown
    case rangeFront
    case rangeMiddle
    case rangeBack
    case rangeAll
    case rangeOneQuarter
    case rangeThreeQuarter
}

struct RangeType {
    let from: Int
    let to: Int
}

struct RangeWithMiddleType {
    let from: Int
    let mid: Int
    let to: Int
}

struct TwoRangesType {
    let ranges: (RangeWithMiddleType, RangeWithMiddleType)
    let desc: String
}

func getRange(_ ranges: TwoRangesType, _ selector: RangeSelector, _ user: Int) -> RangeType {
    let selectedRange = user == 0 ? ranges.ranges.0 : ranges.ranges.1

    let q1 = (selectedRange.from + selectedRange.mid + 1) >> 1 // Math.floor(x/2)
    let q3 = (selectedRange.mid + selectedRange.to) >> 1

    switch selector {
    case .rangeFront:
        return RangeType(from: selectedRange.from, to: selectedRange.from)
    case .rangeMiddle:
        return RangeType(from: selectedRange.mid, to: selectedRange.mid)
    case .rangeBack:
        return RangeType(from: selectedRange.to, to: selectedRange.to)
    case .rangeAll:
        return RangeType(from: selectedRange.from, to: selectedRange.to)
    case .rangeOneQuarter:
        return RangeType(from: q1, to: q1)
    case .rangeThreeQuarter:
        return RangeType(from: q3, to: q3)
    default:
        return RangeType(from: -1, to: -1)
    }
}

// swiftlint: disable function_parameter_count
func makeTwoRanges(_ from1: Int, _ mid1: Int, _ to1: Int, _ from2: Int, _ mid2: Int, _ to2: Int, _ desc: String) -> TwoRangesType {
    let range0 = RangeWithMiddleType(from: from1, mid: mid1, to: to1)
    let range1 = RangeWithMiddleType(from: from2, mid: mid2, to: to2)
    return TwoRangesType(ranges: (range0, range1), desc: desc)
}

// swiftlint: enable function_parameter_count

func getMergeRange(_ xml: String, _ interval: RangeType) -> RangeType {
    let content = parseSimpleXML(xml)
    var st = -1
    var ed = -1

    for index in (interval.from + 1) ... interval.to {
        if st == -1 && content[index].hasPrefix("</") {
            st = index - 1
        }
        if content[index].hasPrefix("<") && !content[index].hasPrefix("</") {
            ed = index
        }
    }

    return RangeType(from: st, to: ed)
}

enum StyleOpCode {
    case styleUndefined
    case styleRemove
    case styleSet
}

enum EditOpCode {
    case editUndefined
    case editUpdate
    case mergeUpdate
    case splitUpdate
}

protocol OperationInterface {
    func run(_ doc: Document, _ user: Int, _ ranges: TwoRangesType) async throws
    func getDesc() -> String
}

class StyleOperationType: OperationInterface {
    private let selector: RangeSelector
    private let op: StyleOpCode
    private let key: String
    private let value: String
    private let desc: String

    init(_ selector: RangeSelector, _ op: StyleOpCode, _ key: String, _ value: String, _ desc: String) {
        self.selector = selector
        self.op = op
        self.key = key
        self.value = value
        self.desc = desc
    }

    func getDesc() -> String {
        self.desc
    }

    func run(_ doc: Document, _ user: Int, _ ranges: TwoRangesType) async throws {
        let interval = getRange(ranges, self.selector, user)
        let from = interval.from
        let to = interval.to

        try await doc.update { root, _ in
            if self.op == .styleRemove {
                try (root.t as? JSONTree)?.removeStyle(from, to, [self.key])
            } else if self.op == .styleSet {
                try (root.t as? JSONTree)?.style(from, to, [key: self.value])
            }
        }
    }
}

class EditOperationType: OperationInterface {
    private let selector: RangeSelector
    private let op: EditOpCode
    private let content: (any JSONTreeNode)?
    private let splitLevel: Int32
    private let desc: String

    init(_ selector: RangeSelector, _ op: EditOpCode, _ content: (any JSONTreeNode)?, _ splitLevel: Int32, _ desc: String) {
        self.selector = selector
        self.op = op
        self.content = content
        self.splitLevel = splitLevel
        self.desc = desc
    }

    func getDesc() -> String {
        self.desc
    }

    func run(_ doc: Document, _ user: Int, _ ranges: TwoRangesType) async throws {
        let interval = getRange(ranges, self.selector, user)
        let from = interval.from
        let to = interval.to

        try await doc.update { root, _ in
            if self.op == .editUpdate {
                try (root.t as? JSONTree)?.edit(from, to, self.content, self.splitLevel)
            } else if self.op == .mergeUpdate {
                let xml = (root.t as? JSONTree)!.toXML()
                let mergeInterval = getMergeRange(xml, interval)
                let st = mergeInterval.from, ed = mergeInterval.to
                if st != -1 && ed != -1 && st < ed {
                    try (root.t as? JSONTree)?.edit(st, ed, self.content, self.splitLevel)
                }
            } else if self.op == .splitUpdate {
                XCTAssertNotEqual(0, self.splitLevel)
                XCTAssertEqual(from, to)
                try (root.t as? JSONTree)?.edit(from, to, self.content, self.splitLevel)
            }
        }
    }
}

final class TreeConcurrencyTests: XCTestCase {
    // swiftlint: disable function_parameter_count
    func runTest(initialState: JSONTree,
                 initialXML: String,
                 ranges: TwoRangesType,
                 op1: OperationInterface,
                 op2: OperationInterface,
                 desc: String) async throws -> TestResult
    {
        let rpcAddress = "http://localhost:8080"

        let docKey = "\(Date().description)-\(desc)".toDocKey

        let c1 = Client(rpcAddress)
        let c2 = Client(rpcAddress)

        try await c1.activate()
        try await c2.activate()

        let d1 = Document(key: docKey)
        let d2 = Document(key: docKey)

        try await c1.attach(d1, [:], .manual)
        try await c2.attach(d2, [:], .manual)

        try await d1.update { root, _ in
            root.t = initialState
        }
        try await c1.sync()
        try await c2.sync()
        print("====== \(desc) ====== ")
        let d1XML = await(d1.getRoot().t as? JSONTree)?.toXML()
        let d2XML = await(d2.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(d1XML, initialXML)
        XCTAssertEqual(d2XML, initialXML)

        try await op1.run(d1, 0, ranges)
        try await op2.run(d2, 0, ranges)

        let before1 = await(d1.getRoot().t as? JSONTree)?.toXML() ?? ""
        let before2 = await(d2.getRoot().t as? JSONTree)?.toXML() ?? ""

        // save own changes and get previous changes
        try await c1.sync()
        try await c2.sync()

        // get last client changes
        try await c1.sync()
        try await c2.sync()

        let after1 = await(d1.getRoot().t as? JSONTree)?.toXML() ?? ""
        let after2 = await(d2.getRoot().t as? JSONTree)?.toXML() ?? ""

        try await c1.detach(d1)
        try await c2.detach(d2)
        try await c1.deactivate()
        try await c2.deactivate()

        return TestResult(before: (before1, before2), after: (after1, after2))
    }

    func runTestConcurrency(_ testDesc: String,
                            _ initialState: JSONTree,
                            _ initialXML: String,
                            _ rangesArr: [TwoRangesType],
                            _ op1Arr: [OperationInterface],
                            _ op2Arr: [OperationInterface]) async throws -> Int
    {
        var testCount = 0

        for ranges in rangesArr {
            for op1 in op1Arr {
                var exps = [XCTestExpectation]()

                for op2 in op2Arr {
                    let desc = "\(testDesc)-[\(ranges.desc)](\(op1.getDesc()),\(op2.getDesc()))"
                    let exp = expectation(description: "\(desc)")

                    exps.append(exp)

                    DispatchQueue.global().async {
                        Task {
                            let result = try await self.runTest(initialState: initialState.deepcopy(), initialXML: initialXML, ranges: ranges, op1: op1, op2: op2, desc: desc)
                            print("====== before d1: \(result.before.0)")
                            print("====== before d2: \(result.before.1)")
                            print("====== after d1: \(result.after.0)")
                            print("====== after d2: \(result.after.1)")
                            XCTAssertEqual(result.after.0, result.after.1, desc)

                            exp.fulfill()
                        }
                    }
                    testCount += 1
                }
                await fulfillment(of: exps, timeout: 10)
            }
        }

        return testCount
    }

    // swiftlint: enable function_parameter_count

    // swiftlint: disable function_body_length
    func test_concurrently_edit_edit_test() async throws {
        let initialTree = JSONTree(initialRoot:
            JSONTreeElementNode(type: "r",
                                children: [
                                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abc")]),
                                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "def")]),
                                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ghi")])
                                ])
        )
        let initialXML = "<r><p>abc</p><p>def</p><p>ghi</p></r>"

        let textNode1 = JSONTreeTextNode(value: "A")
        let textNode2 = JSONTreeTextNode(value: "B")
        let elementNode1 = JSONTreeElementNode(type: "b")
        let elementNode2 = JSONTreeElementNode(type: "i")

        let rangesArr = [
            // intersect-element: <p>abc</p><p>def</p> - <p>def</p><p>ghi</p>
            makeTwoRanges(0, 5, 10, 5, 10, 15, "intersect-element"),
            // intersect-text: ab - bc
            makeTwoRanges(1, 2, 3, 2, 3, 4, "intersect-text"),
            // contain-element: <p>abc</p><p>def</p><p>ghi</p> - <p>def</p>
            makeTwoRanges(0, 5, 15, 5, 5, 10, "contain-element"),
            // contain-text: abc - b
            makeTwoRanges(1, 2, 4, 2, 2, 3, "contain-text"),
            // contain-mixed-type: <p>abc</p><p>def</p><p>ghi</p> - def
            makeTwoRanges(0, 5, 15, 6, 7, 9, "contain-mixed-type"),
            // side-by-side-element: <p>abc</p> - <p>def</p>
            makeTwoRanges(0, 5, 5, 5, 5, 10, "side-by-side-element"),
            // side-by-side-text: a - bc
            makeTwoRanges(1, 1, 2, 2, 3, 4, "side-by-side-text"),
            // equal-element: <p>abc</p><p>def</p> - <p>abc</p><p>def</p>
            makeTwoRanges(0, 5, 10, 0, 5, 10, "equal-element"),
            // equal-text: abc - abc
            makeTwoRanges(1, 2, 4, 1, 2, 4, "equal-text")
        ]

        let edit1Operations: [EditOperationType] = [
            EditOperationType(
                .rangeFront,
                .editUpdate,
                textNode1,
                0,
                "insertTextFront"
            ),
            EditOperationType(
                .rangeMiddle,
                .editUpdate,
                textNode1,
                0,
                "insertTextMiddle"
            ),
            EditOperationType(
                .rangeBack,
                .editUpdate,
                textNode1,
                0,
                "insertTextBack"
            ),
            EditOperationType(
                .rangeAll,
                .editUpdate,
                textNode1,
                0,
                "replaceText"
            ),
            EditOperationType(
                .rangeFront,
                .editUpdate,
                elementNode1,
                0,
                "insertElementFront"
            ),
            EditOperationType(
                .rangeMiddle,
                .editUpdate,
                elementNode1,
                0,
                "insertElementMiddle"
            ),
            EditOperationType(
                .rangeBack,
                .editUpdate,
                elementNode1,
                0,
                "insertElementBack"
            ),
            EditOperationType(
                .rangeAll,
                .editUpdate,
                elementNode1,
                0,
                "replaceElement"
            ),
            EditOperationType(
                .rangeAll,
                .editUpdate,
                nil,
                0,
                "delete"
            ),
            EditOperationType(
                .rangeAll,
                .mergeUpdate,
                nil,
                0,
                "merge"
            )
        ]

        let edit2Operations: [EditOperationType] = [
            EditOperationType(
                .rangeFront,
                .editUpdate,
                textNode2,
                0,
                "insertTextFront"
            ),
            EditOperationType(
                .rangeMiddle,
                .editUpdate,
                textNode2,
                0,
                "insertTextMiddle"
            ),
            EditOperationType(
                .rangeBack,
                .editUpdate,
                textNode2,
                0,
                "insertTextBack"
            ),
            EditOperationType(
                .rangeAll,
                .editUpdate,
                textNode2,
                0,
                "replaceText"
            ),
            EditOperationType(
                .rangeFront,
                .editUpdate,
                elementNode2,
                0,
                "insertElementFront"
            ),
            EditOperationType(
                .rangeMiddle,
                .editUpdate,
                elementNode2,
                0,
                "insertElementMiddle"
            ),
            EditOperationType(
                .rangeBack,
                .editUpdate,
                elementNode2,
                0,
                "insertElementBack"
            ),
            EditOperationType(
                .rangeAll,
                .editUpdate,
                elementNode2,
                0,
                "replaceElement"
            ),
            EditOperationType(
                .rangeAll,
                .editUpdate,
                nil,
                0,
                "delete"
            ),
            EditOperationType(
                .rangeAll,
                .mergeUpdate,
                nil,
                0,
                "merge"
            )
        ]

        let testCount = try await runTestConcurrency(
            "concurrently-edit-edit-test",
            initialTree,
            initialXML,
            rangesArr,
            edit1Operations,
            edit2Operations
        )

        print("\(self.description) Test Count: \(testCount)")
    }

    func test_concurrently_style_style_test() async throws {
        let initialTree = JSONTree(initialRoot:
            JSONTreeElementNode(type: "r",
                                children: [
                                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "a")]),
                                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "b")]),
                                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "c")])
                                ])
        )
        let initialXML = "<r><p>a</p><p>b</p><p>c</p></r>"

        let rangesArr = [
            // equal: <p>b</p> - <p>b</p>
            makeTwoRanges(3, -1, 6, 3, -1, 6, "equal"),
            // contain: <p>a</p><p>b</p><p>c</p> - <p>b</p>
            makeTwoRanges(0, -1, 9, 3, -1, 6, "contain"),
            // intersect: <p>a</p><p>b</p> - <p>b</p><p>c</p>
            makeTwoRanges(0, -1, 6, 3, -1, 9, "intersect"),
            // side-by-side: <p>a</p> - <p>b</p>
            makeTwoRanges(0, -1, 3, 3, -1, 6, "side-by-side")
        ]

        let styleOperations: [StyleOperationType] = [
            StyleOperationType(
                .rangeAll,
                .styleRemove,
                "bold",
                "",
                "remove-bold"
            ),
            StyleOperationType(
                .rangeAll,
                .styleSet,
                "bold",
                "aa",
                "set-bold-aa"
            ),
            StyleOperationType(
                .rangeAll,
                .styleSet,
                "bold",
                "bb",
                "set-bold-bb"
            ),
            StyleOperationType(
                .rangeAll,
                .styleRemove,
                "italic",
                "",
                "remove-italic"
            ),
            StyleOperationType(
                .rangeAll,
                .styleSet,
                "italic",
                "aa",
                "set-italic-aa"
            ),
            StyleOperationType(
                .rangeAll,
                .styleSet,
                "italic",
                "bb",
                "set-italic-bb"
            )
        ]

        // Define range & style operations
        let testCount = try await runTestConcurrency(
            "concurrently-style-style-test",
            initialTree,
            initialXML,
            rangesArr,
            styleOperations,
            styleOperations
        )

        print("\(self.description) Test Count: \(testCount)")
    }

    func test_concurrently_edit_style_test() async throws {
        let initialTree = JSONTree(initialRoot:
            JSONTreeElementNode(type: "r",
                                children: [
                                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "a")], attributes: ["color": "red"]),
                                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "b")], attributes: ["color": "red"]),
                                    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "c")], attributes: ["color": "red"])
                                ])
        )
        let initialXML = "<r><p color=\"red\">a</p><p color=\"red\">b</p><p color=\"red\">c</p></r>"

        let content = JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "d")], attributes: ["italic": true, "color": "blue"])

        let rangesArr = [
            // equal: <p>b</p> - <p>b</p>
            makeTwoRanges(3, 3, 6, 3, -1, 6, "equal"),
            // equal multiple: <p>a</p><p>b</p><p>c</p> - <p>a</p><p>b</p><p>c</p>
            makeTwoRanges(0, 3, 9, 0, 3, 9, "equal multiple"),
            // A contains B: <p>a</p><p>b</p><p>c</p> - <p>b</p>
            makeTwoRanges(0, 3, 9, 3, -1, 6, "A contains B"),
            // B contains A: <p>b</p> - <p>a</p><p>b</p><p>c</p>
            makeTwoRanges(3, 3, 6, 0, -1, 9, "B contains A"),
            // intersect: <p>a</p><p>b</p> - <p>b</p><p>c</p>
            makeTwoRanges(0, 3, 6, 3, -1, 9, "intersect"),
            // A -> B: <p>a</p> - <p>b</p>
            makeTwoRanges(0, 3, 3, 3, -1, 6, "A -> B"),
            // B -> A: <p>b</p> - <p>a</p>
            makeTwoRanges(3, 3, 6, 0, -1, 3, "B -> A")
        ]

        let editOperations: [EditOperationType] = [
            EditOperationType(
                .rangeFront,
                .editUpdate,
                content,
                0,
                "insertFront"
            ),
            EditOperationType(
                .rangeMiddle,
                .editUpdate,
                content,
                0,
                "insertMiddle"
            ),
            EditOperationType(
                .rangeBack,
                .editUpdate,
                content,
                0,
                "insertBack"
            ),
            EditOperationType(
                .rangeAll,
                .editUpdate,
                nil,
                0,
                "delete"
            ),
            EditOperationType(
                .rangeAll,
                .editUpdate,
                content,
                0,
                "replace"
            ),
            EditOperationType(
                .rangeAll,
                .mergeUpdate,
                nil,
                0,
                "merge"
            )
        ]

        let styleOperations: [StyleOperationType] = [
            StyleOperationType(
                .rangeAll,
                .styleRemove,
                "color",
                "",
                "remove-color"
            ),
            StyleOperationType(
                .rangeAll,
                .styleSet,
                "bold",
                "aa",
                "set-bold-aa"
            )
        ]

        let testCount = try await runTestConcurrency(
            "concurrently-edit-style-test",
            initialTree,
            initialXML,
            rangesArr,
            editOperations,
            styleOperations
        )
        print("\(self.description) Test Count: \(testCount)")
    }

    func skip_test_concurrently_split_split_test() async throws {
        let initialTree = JSONTree(initialRoot:
            JSONTreeElementNode(type: "r",
                                children: [
                                    JSONTreeElementNode(type: "p", children: [
                                        JSONTreeElementNode(type: "p", children: [
                                            JSONTreeElementNode(type: "p", children: [
                                                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcd")]),
                                                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcd")])
                                            ]),
                                            JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ijkl")])
                                        ])
                                    ])
                                ])
        )

        let initialXML = "<r><p><p><p><p>abcd</p><p>efgh</p></p><p>ijkl</p></p></p></r>"

        let rangesArr = [
            // equal-single-element: <p>abcd</p>
            makeTwoRanges(3, 6, 9, 3, 6, 9, "equal-single"),
            // equal-multiple-element: <p>abcd</p><p>efgh</p>
            makeTwoRanges(3, 9, 15, 3, 9, 15, "equal-multiple"),
            // A contains B same level: <p>abcd</p><p>efgh</p> - <p>efgh</p>
            makeTwoRanges(3, 9, 15, 9, 12, 15, "A contains B same level"),
            // A contains B multiple level: <p><p>abcd</p><p>efgh</p></p><p>ijkl</p> - <p>efgh</p>
            makeTwoRanges(2, 16, 22, 9, 12, 15, "A contains B multiple level"),
            // side by side
            makeTwoRanges(3, 6, 9, 9, 12, 15, "B is next to A")
        ]

        let splitOperations: [EditOperationType] = [
            EditOperationType(
                .rangeFront,
                .splitUpdate,
                nil,
                1,
                "split-front-1"
            ),
            EditOperationType(
                .rangeOneQuarter,
                .splitUpdate,
                nil,
                1,
                "split-one-quarter-1"
            ),
            EditOperationType(
                .rangeThreeQuarter,
                .splitUpdate,
                nil,
                1,
                "split-three-quarter-1"
            ),
            EditOperationType(
                .rangeBack,
                .splitUpdate,
                nil,
                1,
                "split-back-1"
            ),
            EditOperationType(
                .rangeFront,
                .splitUpdate,
                nil,
                2,
                "split-front-2"
            ),
            EditOperationType(
                .rangeOneQuarter,
                .splitUpdate,
                nil,
                2,
                "split-one-quarter-2"
            ),
            EditOperationType(
                .rangeThreeQuarter,
                .splitUpdate,
                nil,
                2,
                "split-three-quarter-2"
            ),
            EditOperationType(
                .rangeBack,
                .splitUpdate,
                nil,
                2,
                "split-back-2"
            )
        ]

        let testCount = try await runTestConcurrency(
            "concurrently-split-split-test",
            initialTree,
            initialXML,
            rangesArr,
            splitOperations,
            splitOperations
        )
        print("\(self.description) Test Count: \(testCount)")
    }

    func skip_test_concurrently_split_edit_test() async throws {
        let initialTree = JSONTree(initialRoot:
            JSONTreeElementNode(type: "r",
                                children: [
                                    JSONTreeElementNode(type: "p", children: [
                                        JSONTreeElementNode(type: "p", children: [
                                            JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcd")], attributes: ["italic": "a"]),
                                            JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abcd")], attributes: ["italic": "a"])
                                        ]),
                                        JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ijkl")], attributes: ["italic": "a"])
                                    ])
                                ])
        )

        let initialXML = "<r><p><p><p italic=\"a\">abcd</p><p italic=\"a\">efgh</p></p><p italic=\"a\">ijkl</p></p></r>"

        let content = JSONTreeElementNode(type: "i")

        let rangesArr = [
            // equal: <p>ab"cd</p>
            makeTwoRanges(2, 5, 8, 2, 5, 8, "equal"),
            // A contains B: <p>ab"cd</p> - bc
            makeTwoRanges(2, 5, 8, 4, 5, 6, "A contains B"),
            // B contains A: <p>ab"cd</p> - <p>abcd</p><p>efgh</p>
            makeTwoRanges(2, 5, 8, 2, 8, 14, "B contains A"),
            // left node(text): <p>ab"cd</p> - ab
            makeTwoRanges(2, 5, 8, 3, 4, 5, "left node(text)"),
            // right node(text): <p>ab"cd</p> - cd
            makeTwoRanges(2, 5, 8, 5, 6, 7, "right node(text)"),
            // left node(element): <p>abcd</p>"<p>efgh</p> - <p>abcd</p>
            makeTwoRanges(2, 8, 14, 2, 5, 8, "left node(element)"),
            // right node(element): <p>abcd</p>"<p>efgh</p> - <p>efgh</p>
            makeTwoRanges(2, 8, 14, 8, 11, 14, "right node(element)"),
            // A -> B: <p>ab"cd</p> - <p>efgh</p>
            makeTwoRanges(2, 5, 8, 8, 11, 14, "A -> B"),
            // B -> A: <p>ef"gh</p> - <p>abcd</p>
            makeTwoRanges(8, 11, 14, 2, 5, 8, "B -> A")
        ]

        let splitOperations: [EditOperationType] = [
            EditOperationType(
                .rangeMiddle,
                .splitUpdate,
                nil,
                1,
                "split-1"
            ),
            EditOperationType(
                .rangeMiddle,
                .splitUpdate,
                nil,
                2,
                "split-2"
            )
        ]

        let editOperations: [OperationInterface] = [
            EditOperationType(
                .rangeFront,
                .editUpdate,
                content,
                0,
                "insertFront"
            ),
            EditOperationType(
                .rangeMiddle,
                .editUpdate,
                content,
                0,
                "insertMiddle"
            ),
            EditOperationType(
                .rangeBack,
                .editUpdate,
                content,
                0,
                "insertBack"
            ),
            EditOperationType(
                .rangeAll,
                .editUpdate,
                content,
                0,
                "replace"
            ),
            EditOperationType(
                .rangeAll,
                .editUpdate,
                nil,
                0,
                "delete"
            ),
            EditOperationType(
                .rangeAll,
                .mergeUpdate,
                nil,
                0,
                "merge"
            ),
            StyleOperationType(
                .rangeAll,
                .styleSet,
                "bold",
                "aa",
                "style"
            ),
            StyleOperationType(
                .rangeAll,
                .styleRemove,
                "italic",
                "",
                "remove-style"
            )
        ]

        let testCount = try await runTestConcurrency(
            "concurrently-split-edit-test",
            initialTree,
            initialXML,
            rangesArr,
            splitOperations,
            editOperations
        )
        print("\(self.description) Test Count: \(testCount)")
    }
    // swiftlint: enable function_body_length
}
