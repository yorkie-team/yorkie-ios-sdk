//
//  RGATreeSplitTests.swift
//  YorkieTests
//
//  Created by Jung gyun Ahn on 2023/01/03.
//

import XCTest
@testable import Yorkie

final class RGATreeSplitTests: XCTestCase {
    var target = RGATreeSplit<String>()

    func test_should_handle_edit_operations_with_case1() throws {
        print("#### \(self.target.structureAsString)")
        var range = RGATreeSplitNodeRange(target.findNodePos(0)!, self.target.findNodePos(0)!)
        self.target.edit(range, TimeTicket.initial, "ABCD")
        print("#### \(self.target.structureAsString)")
        range = RGATreeSplitNodeRange(self.target.findNodePos(1)!, self.target.findNodePos(3)!)
        self.target.edit(range, TimeTicket.initial, "12")
        print("#### \(self.target.structureAsString)")

        XCTAssertEqual("A12D", self.target.toJSON)
    }

    func test_should_handle_edit_operations_with_case2() throws {
        print("#### \(self.target.structureAsString)")
        var range = RGATreeSplitNodeRange(target.findNodePos(0)!, self.target.findNodePos(0)!)
        self.target.edit(range, TimeTicket.initial, "ABCD")
        print("#### \(self.target.structureAsString)")
        range = RGATreeSplitNodeRange(self.target.findNodePos(3)!, self.target.findNodePos(3)!)
        self.target.edit(range, TimeTicket.initial, "\n")
        print("#### \(self.target.structureAsString)")

        XCTAssertEqual("ABC\nD", self.target.toJSON)
    }
}

extension String: RGATreeSplitValue {
    public func substring(indexStart: Int, indexEnd: Int?) -> String {
        let start = self.index(self.startIndex, offsetBy: indexStart)

        if let indexEnd {
            let end = self.index(start, offsetBy: indexEnd - indexStart)

            return String(self[start ... end])
        } else {
            return String(self[start...])
        }
    }

    public var string: String {
        self
    }
}
