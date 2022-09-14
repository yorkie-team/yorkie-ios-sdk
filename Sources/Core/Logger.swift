//
//  Logger.swift
//  Yorkie
//
//  Created by Hyeongsik Won on 2022/09/14.
//
//

import Foundation

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
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

    static func log(level: LogLevel, _ message: String, error: Error? = nil, filename: String = #file, function: String = #function, line: Int = #line) {
        let file = URL(fileURLWithPath: filename).lastPathComponent
        let log = message + (error?.localizedDescription ?? "")
        print("[\(level.rawValue)][\(file):\(line)] \(function) - \(log)")
    }
}
