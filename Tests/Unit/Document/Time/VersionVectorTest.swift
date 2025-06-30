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

    func addVersionAfters(_ number: Int) {
        for i in 0 ... number {
            self.sut.set(actorID: "actorID-\(i)", lamport: Int64(i))
        }
    }
}

extension VersionVectorTest {
    func test_set_actorID_with_lamdaPort_get_corresonding_lamdaport_from_vector() {
        // given
        let actorID: ActorID = "actorID"
        let lamdaPort: Int64 = 123

        // when
        self.sut.set(actorID: actorID, lamport: lamdaPort)

        // then
        XCTAssertEqual(self.sut.get(actorID), lamdaPort)
    }

    func test_when_no_max_lamdar_port_then_return_zero() {
        // given
        // no lamda port added
        // then
        XCTAssertEqual(self.sut.maxLamport(), .zero)
    }

    func test_when_add_more_lamda_port_get_max_lamda_port() {
        // given
        let actorID1: ActorID = "actorID-1"
        let lamdaPort1: Int64 = 123
        let actorID2: ActorID = "actorID-2"
        let lamdaPort2: Int64 = 456

        // when
        self.sut.set(actorID: actorID1, lamport: lamdaPort1)
        self.sut.set(actorID: actorID2, lamport: lamdaPort2)

        let maxLamdaPort = self.sut.maxLamport()

        // then
        XCTAssertEqual(maxLamdaPort, lamdaPort2)
        XCTAssertNotEqual(maxLamdaPort, lamdaPort1)
    }
}

// MARK: - max(other: VersionVector) -> VersionVector

extension VersionVectorTest {
    func test_get_max_from_other_vector() {
        self.addVersionAfters(200)

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
    func test_when_no_vector_get_after_or_equal_lamdaport_return_false() {
        // given
        // no lamda port added

        // then
        let afterOrEqual = self.sut.afterOrEqual(other: .initial)

        XCTAssertFalse(afterOrEqual)
    }

    func test_when_given_other_timeTicket_get_after_or_equal_lamdaport() {
        // when
        self.addVersionAfters(200)

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
        self.addVersionAfters(200)

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
    func test_filter_vector_vertsion_give_no_vector_return_empty_vector() {
        // given premitive sut
        // when filter initial vector
        // then
        let filteredSut = self.sut.filter(versionVector: .initial)

        XCTAssertEqual(filteredSut.size(), 0)
    }

    func test_filter_vector_version_give_some_vector_return_correct_vector() {
        // given 200 vectors exist
        self.addVersionAfters(200)

        // when get actor 100th
        let filteredSut = self.sut.filter(versionVector: .init(vector: ["actorID-100": 100, "actorID-300": 300]))

        // then
        XCTAssertEqual(filteredSut.get("actorID-100"), 100)
    }
}
