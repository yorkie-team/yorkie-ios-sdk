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

enum Constant {
    private static var currentYorkieServerIP: String {
        if let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let ip = dict["CurrentIPAddress"] as? String,
           ip != "0.0.0.0"
        {
            return "http://\(ip):8080"
        }
        return "http://localhost:8080"
    }

    static var serverAddress = currentYorkieServerIP
    static var documentKey: String = "simultaneous-cursors"
}

enum TDError: Error {
    case cannotInitClient(String)
}

enum ContentState {
    case loading
    case error(TDError)
    case success
}
