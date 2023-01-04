//
//  RGATreeSplitTests.swift
//  YorkieTests
//
//  Created by Jung gyun Ahn on 2023/01/03.
//

import XCTest
@testable import Yorkie

// swiftlint: disable force_try
final class RGATreeSplitTests: XCTestCase {
    var target = RGATreeSplit<String>()

    func test_should_handle_edit_operations_with_case1() throws {
        var range = RGATreeSplitNodeRange(try! self.target.findNodePos(0), try! self.target.findNodePos(0))
        try self.target.edit(range, TimeTicket.initial, "ABCD")
        range = RGATreeSplitNodeRange(try! self.target.findNodePos(1), try! self.target.findNodePos(3))
        try self.target.edit(range, TimeTicket.initial, "12")

        XCTAssertEqual("A12D", self.target.toJSON)
    }

    func test_should_handle_edit_operations_with_case2() throws {
        var range = RGATreeSplitNodeRange(try! self.target.findNodePos(0), try! self.target.findNodePos(0))
        try self.target.edit(range, TimeTicket.initial, "ABCD")
        range = RGATreeSplitNodeRange(try! self.target.findNodePos(3), try! self.target.findNodePos(3))
        try self.target.edit(range, TimeTicket.initial, "\n")

        XCTAssertEqual("ABC\nD", self.target.toJSON)
    }
}

extension String: RGATreeSplitValue {
    public var string: String {
        self
    }
}
