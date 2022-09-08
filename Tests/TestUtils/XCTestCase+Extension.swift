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

// MARK: - Test Code Style: given/when/then

extension XCTestCase {
    func given(_ description: String = "", _ action: () -> Void) {
        print("# given ", description)
        action()
    }

    func when(_ description: String = "", _ action: () -> Void) {
        print("# when ", description)
        action()
    }

    func then(_ description: String = "", _ action: () -> Void) {
        print("# then ", description)
        action()
    }

    func tryGiven(_ description: String = "", _ action: () throws -> Void) throws {
        print("# given ", description)
        try action()
    }

    func tryWhen(_ description: String = "", _ action: () throws -> Void) throws {
        print("# when ", description)
        try action()
    }

    func tryThen(_ description: String = "", _ action: () throws -> Void) throws {
        print("# then ", description)
        try action()
    }
}
