//
//  SnapshotTests.swift
//  YorkieTests
//
//  Created by KSB on 1/22/25.
//

import XCTest
@testable import Yorkie

final class SnapshotTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    func test_should_handle_snapshot() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            // 01. Updates 700 changes over snapshot threshold.
            for idx in 0 ..< 700 {
                try await d1.update { root, _ in
                    root["\(idx)"] = Int32(idx)
                }
            }
            try await c1.sync()

            // 02. Makes local changes then pull a snapshot from the agent.
            try await d2.update { root, _ in
                root["key"] = "value"
            }
            try await c2.sync()

            let value = await d2.getRoot()["key"] as? String
            XCTAssertEqual(value, "value")

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            let d1JSON = await d1.toSortedJSON()
            let d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    func test_should_handle_snapshot_for_text_object() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            for _ in 0 ..< 700 {
                try await d1.update { root, _ in
                    root.k1 = JSONText()
                }
            }
            try await c1.sync()
            try await c2.sync()

            // 01. Updates 500 changes over snapshot threshold by c1.
            for idx in 0 ..< 500 {
                try await d1.update { root, _ in
                    (root.k1 as? JSONText)?.edit(idx, idx, "x")
                }
            }

            // 02. Makes local change by c2.
            try await d2.update { root, _ in
                (root.k1 as? JSONText)?.edit(0, 0, "o")
            }

            try await c1.sync()
            try await c2.sync()
            try await c1.sync()

            let d1JSON = await d1.toSortedJSON()
            let d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }

    func test_should_handle_snapshot_for_text_with_attributes() async throws {
        try await withTwoClientsAndDocuments(self.description) { c1, d1, c2, d2 in
            try await d1.update { root, _ in
                root.k1 = JSONText()
                (root.k1 as? JSONText)?.edit(0, 0, "a")
            }
            try await c1.sync()
            try await c2.sync()

            // 01. Updates 700 changes over snapshot threshold by c1.
            for _ in 0 ..< 700 {
                try await d1.update { root, _ in
                    (root.k1 as? JSONText)?.setStyle(0, 1, ["bold": true])
                }
            }

            try await c1.sync()
            try await c2.sync()

            let d1JSON = await d1.toSortedJSON()
            let d2JSON = await d2.toSortedJSON()
            XCTAssertEqual(d1JSON, d2JSON)
        }
    }
}
