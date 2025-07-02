//
//  VersionVectorTest.swift
//  YorkieTests
//
//  Created by kha.do on 25/6/25.
//

import XCTest
@testable import Yorkie

class VersionVectorTest: XCTestCase {
    var sut: VersionVector!

    override func setUp() {
        super.setUp()

        self.sut = .init()
    }

    override func tearDown() {
        self.sut = nil
        super.tearDown()
    }

    func addVersionVectors(number: Int) {
        for id in 0 ... number {
            self.sut.set(actorID: "actorID-\(id)", lamport: Int64(id))
        }
    }
}

extension VersionVectorTest {
    func test_set_actorID_with_lamport_get_corresponding_lamport_from_vector() {
        // given
        let actorID: ActorID = "actorID"
        let lamdaPort: Int64 = 123

        // when
        self.sut.set(actorID: actorID, lamport: lamdaPort)

        // then
        XCTAssertEqual(self.sut.get(actorID), lamdaPort)
    }

    func test_when_no_max_lamport_then_return_zero() {
        // given
        // no lamport added
        // then
        XCTAssertEqual(self.sut.maxLamport(), .zero)
    }

    func test_when_add_more_lamport_get_max_lamport() {
        // given
        let actorID1: ActorID = "actorID-1"
        let lamPort1: Int64 = 123
        let actorID2: ActorID = "actorID-2"
        let lamPort2: Int64 = 456

        // when
        self.sut.set(actorID: actorID1, lamport: lamPort1)
        self.sut.set(actorID: actorID2, lamport: lamPort2)

        let maxLamport = self.sut.maxLamport()

        // then
        XCTAssertEqual(maxLamport, lamPort2)
        XCTAssertNotEqual(maxLamport, lamPort1)
    }
}

// MARK: - max(other: VersionVector) -> VersionVector

extension VersionVectorTest {
    func test_get_max_from_other_vector() {
        self.addVersionVectors(number: 200)

        // modify actor 100 lamport from 100 -> 150
        self.sut.set(actorID: "actorID-100", lamport: 150)

        var newVersionVector = VersionVector()
        // modify actor 100 lamport from 0 -> 200 from other version vector
        newVersionVector.set(actorID: "actorID-100", lamport: 200)

        let result = self.sut.max(other: newVersionVector)

        XCTAssertEqual(result.get("actorID-100"), 200)
    }
}

// MARK: - afterOrEqual

extension VersionVectorTest {
    func test_when_no_vector_get_after_or_equal_lamdaport_return_true() {
        // given
        // no lamport added

        // then
        let afterOrEqual = self.sut.afterOrEqual(other: .init(lamport: 200, delimiter: 0, actorID: "actorID-200"))

        XCTAssertTrue(afterOrEqual)
    }

    func test_when_given_other_timeTicket_get_after_or_equal_lamdaport() {
        // when
        self.addVersionVectors(number: 200)

        let timeTicketFalse = TimeTicket(lamport: 250, delimiter: 0, actorID: "actorID-200")
        let timeTicketTrue = TimeTicket(lamport: 150, delimiter: 0, actorID: "actorID-200")

        // then
        let afterOrEqualFalse = self.sut.afterOrEqual(other: timeTicketFalse)
        XCTAssertFalse(afterOrEqualFalse)

        let afterOrEqualTrue = self.sut.afterOrEqual(other: timeTicketTrue)
        XCTAssertTrue(afterOrEqualTrue)
    }
}

// MARK: - deepcopy() -> VersionVector

extension VersionVectorTest {
    func test_deep_copy_return_corresponding_all_data_correctly() {
        // given 200 vectors exist
        self.addVersionVectors(number: 200)

        // then
        let copySut = self.sut.deepcopy()

        XCTAssertEqual(copySut.get("actorID-100"), 100)
        XCTAssertEqual(copySut.get("actorID-200"), 200)
    }
}

// MARK: - size() -> Int

extension VersionVectorTest {
    func test_get_size_then_return_the_count_of_vector() {
        // no actor, return 0
        XCTAssertEqual(self.sut.size(), 0)
        self.sut.set(actorID: "actorID-1", lamport: 100)

        // added 1 actor, return size as 1
        XCTAssertEqual(self.sut.size(), 1)
    }
}

// MARK: - filter(versionVector: VersionVector)

extension VersionVectorTest {
    func test_filter_vector_version_give_no_vector_return_empty_vector() {
        // given premitive sut
        // when filter initial vector
        // then
        let filteredSut = self.sut.filter(versionVector: .initial)

        XCTAssertEqual(filteredSut.size(), 0)
    }

    func test_filter_vector_version_give_some_vector_return_correct_vector() {
        // given 200 vectors exist
        self.addVersionVectors(number: 200)

        // when get actor 100th
        let filteredSut = self.sut.filter(versionVector: .init(vector: ["actorID-100": 100, "actorID-300": 300]))

        // then
        XCTAssertEqual(filteredSut.get("actorID-100"), 100)
    }
}
