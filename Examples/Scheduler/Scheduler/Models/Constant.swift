/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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

import Foundation
import Yorkie

enum Constant {
    static let serverAddress = "http://localhost:8080"
    static var documentKey: String = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = Format.dateFormat
        dateFormatter.locale = Format.local
        let formattedDate = dateFormatter.string(from: Date())
        let result = "next.js-Scheduler-\(formattedDate)"
        return result
    }()
    
    enum Format {
        static let dateFormat = "dd-MM-yy"
        static let local = Locale(identifier: "en_US_POSIX")
    }
}

enum TDError: Error {
    case cannotInitClient(String)
}

struct ScheduleModel: JSONObjectable {
    let date: String
    let text: String
}
