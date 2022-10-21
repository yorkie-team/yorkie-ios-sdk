/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
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

class ConverterTests: XCTestCase {
    func test_data_to_hexString() {
        let array: [UInt8]  = [0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
        let data = Data(bytes: array, count: array.count)
        
        XCTAssertEqual(data.toHexString, "000102030405aabbccddeeff")
        
        let data2 = Data("Hello world".utf8)
        
        XCTAssertEqual(data2.toHexString, "48656c6c6f20776f726c64")
    }

    func test_hexString_to_Data() {
        let array: [UInt8]  = [0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
        let data = Data(bytes: array, count: array.count)

        let str = "000102030405aabbccddeeff"
        
        XCTAssertEqual(str.toData, data)
        
        // Odd length string.
        let strOddLength = "00010"

        XCTAssertTrue(strOddLength.toData == nil)
        
        // Invalid string.
        let strInvalid = "Hello!"

        XCTAssertTrue(strInvalid.toData == nil)
    }
    
    func test_hexString() {
        let array: [UInt8]  = [0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
        let data = Data(bytes: array, count: array.count)

        XCTAssertEqual(data, data.toHexString.toData)

        let str = "000102030405aabbccddeeff"

        XCTAssertEqual(str.toData?.toHexString, str)
    }
}
