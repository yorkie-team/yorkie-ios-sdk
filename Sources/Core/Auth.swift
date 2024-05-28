/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
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

import Connect
import Foundation

struct AuthHeader {
    let apiKey: String?
    let token: String?

    func makeHeader(_ docKey: String?) -> [String: [String]] {
        var header = [String: [String]]()

        if let apiKey {
            header["x-api-key"] = [apiKey]

            var shardKey = "\(apiKey)"

            if let docKey, docKey.isEmpty == false {
                shardKey += "/\(docKey)"
            }

            header["x-shard-key"] = [shardKey]
        }

        if let token {
            header["authorization"] = [token]
        }

        header["x-yorkie-user-agent"] = ["yorkie-ios-sdk/\(yorkieVersion)"]

        return header
    }
}
