/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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
import Testing
@testable import Yorkie

struct StringValueTypeDictionaryTests {
    @Test func test_presence_value_StringValueTypeDictionary() async throws {
        struct CodableStruct: Codable {
            let value: String
        }

        let intValue = 123
        let doubleValue = 123.45
        let stringValue = "hello"
        let boolValue = true
        let codableStruct = CodableStruct(value: "test")

        var dict = StringValueTypeDictionary()
        dict["intValue"] = intValue.toJSONString
        dict["doubleValue"] = doubleValue.toJSONString
        dict["stringValue"] = stringValue.toJSONString
        dict["boolValue"] = boolValue.toJSONString
        dict["codableStruct"] = codableStruct.toJSONString

        #expect(dict["intValue"] == "123")
        #expect(dict["doubleValue"] == "123.45")
        #expect(dict["stringValue"] == "\"hello\"")
        #expect(dict["boolValue"] == "true")
        #expect(dict["codableStruct"] == "{\"value\":\"test\"}")
    }
}
