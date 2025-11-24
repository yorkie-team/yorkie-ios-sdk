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
import os

enum LogLevel {
    case debug, info, warning, notice, error, fault
}

struct Log {
    private static let `default` = Self(category: "DEBUG")
    private let logger: Logger

    private init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "com.example.app.todo",
        category: String
    ) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    static func log(_ message: String, level: LogLevel, _ function: String = #function, _ line: Int = #line, _ file: String = #fileID) {
        switch level {
        case .debug:
            Self.default.debug(message, function, line, file)
        case .info:
            Self.default.info(message, function, line, file)
        case .warning:
            Self.default.warning(message, function, line, file)
        case .notice:
            Self.default.notice(message, function, line, file)
        case .error:
            Self.default.error(message, function, line, file)
        case .fault:
            Self.default.fault(message, function, line, file)
        }
    }
}

extension Log {
    private func messageCentralize(_ message: String, _ function: String = #function, _ line: Int = #line, _ file: String = #file) -> String {
        "[LOG][\(file):\(function):\(line)] -> " + message
    }

    private func debug(_ message: String, _ function: String = #function, _ line: Int = #line, _ file: String = #file) {
        self.logger.debug("\(self.messageCentralize(message, function, line, file), privacy: .public)")
    }

    private func info(_ message: String, _ function: String = #function, _ line: Int = #line, _ file: String = #file) {
        self.logger.info("\(self.messageCentralize(message, function, line, file), privacy: .public)")
    }

    private func notice(_ message: String, _ function: String = #function, _ line: Int = #line, _ file: String = #file) {
        self.logger.notice("\(self.messageCentralize(message, function, line, file), privacy: .public)")
    }

    private func warning(_ message: String, _ function: String = #function, _ line: Int = #line, _ file: String = #file) {
        self.logger.warning("\(self.messageCentralize(message, function, line, file), privacy: .public)")
    }

    private func error(_ message: String, _ function: String = #function, _ line: Int = #line, _ file: String = #file) {
        self.logger.error("\(self.messageCentralize(message, function, line, file), privacy: .public)")
    }

    private func fault(_ message: String, _ function: String = #function, _ line: Int = #line, _ file: String = #file) {
        self.logger.fault("\(self.messageCentralize(message, function, line, file), privacy: .public)")
    }
}
