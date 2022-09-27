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

import Foundation

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
    case fatal = "FATAL"
}

enum Logger {
    static func debug(_ message: String, error: Error? = nil, filename: String = #file, function: String = #function, line: Int = #line) {
        self.log(level: .debug, message, error: error, filename: filename, function: function, line: line)
    }

    static func info(_ message: String, error: Error? = nil, filename: String = #file, function: String = #function, line: Int = #line) {
        self.log(level: .info, message, error: error, filename: filename, function: function, line: line)
    }

    static func warn(_ message: String, error: Error? = nil, filename: String = #file, function: String = #function, line: Int = #line) {
        self.log(level: .warn, message, error: error, filename: filename, function: function, line: line)
    }

    static func error(_ message: String, error: Error? = nil, filename: String = #file, function: String = #function, line: Int = #line) {
        self.log(level: .error, message, error: error, filename: filename, function: function, line: line)
    }

    static func fatal(_ message: String, error: Error? = nil, filename: String = #file, function: String = #function, line: Int = #line) {
        self.log(level: .fatal, message, error: error, filename: filename, function: function, line: line)
    }

    static func log(level: LogLevel, _ message: String, error: Error? = nil, filename: String = #file, function: String = #function, line: Int = #line) {
        let file = URL(fileURLWithPath: filename).lastPathComponent
        let log = message + (error?.localizedDescription ?? "")
        print("[\(level.rawValue)][\(file):\(line)] \(function) - \(log)")
    }
}
