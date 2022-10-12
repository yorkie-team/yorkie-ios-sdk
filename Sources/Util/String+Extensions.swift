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

extension String {
    func substring(from: Int, to: Int) -> SubSequence {
        guard from <= to, from < self.count else {
            return ""
        }

        let adaptedTo = to >= self.count ? self.count - 1 : to

        let start = index(self.startIndex, offsetBy: from)
        let end = index(self.startIndex, offsetBy: adaptedTo)
        let range = start ... end
        return self[range]
    }
}
