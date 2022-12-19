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
import Logging

enum Logger {
    static var logLevel: Logging.Logger.Level {
        get {
            yorkieLogger.logLevel
        }

        set {
            yorkieLogger.logLevel = newValue
        }
    }

    private static var yorkieLogger = Logging.Logger(label: "Yorkie")

    static func trace(_ message: String, error: Error? = nil, filename: String = #fileID, function: String = #function, line: UInt = #line) {
        self.log(level: .trace, message, error: error, filename: filename, function: function, line: line)
    }

    static func debug(_ message: String, error: Error? = nil, filename: String = #fileID, function: String = #function, line: UInt = #line) {
        self.log(level: .debug, message, error: error, filename: filename, function: function, line: line)
    }

    static func info(_ message: String, error: Error? = nil, filename: String = #fileID, function: String = #function, line: UInt = #line) {
        self.log(level: .info, message, error: error, filename: filename, function: function, line: line)
    }

    static func warning(_ message: String, error: Error? = nil, filename: String = #fileID, function: String = #function, line: UInt = #line) {
        self.log(level: .warning, message, error: error, filename: filename, function: function, line: line)
    }

    static func error(_ message: String, error: Error? = nil, filename: String = #fileID, function: String = #function, line: UInt = #line) {
        self.log(level: .error, message, error: error, filename: filename, function: function, line: line)
    }

    static func critical(_ message: String, error: Error? = nil, filename: String = #fileID, function: String = #function, line: UInt = #line) {
        self.log(level: .critical, message, error: error, filename: filename, function: function, line: line)
    }

    static func log(level: Logging.Logger.Level, _ message: String, error: Error? = nil, filename: String = #file, function: String = #function, line: UInt = #line) {
        let log = message + (error?.localizedDescription ?? "")
        let message = "\(function) - \(log)"

        self.yorkieLogger.log(level: level, Logging.Logger.Message(stringLiteral: message), source: "\(filename):\(line)", file: filename, function: function, line: line)
    }
}
