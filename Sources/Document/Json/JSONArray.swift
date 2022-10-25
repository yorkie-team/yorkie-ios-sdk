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

// It will be implemented soon.
protocol JSONArrayable: AnyObject {
    var target: CRDTArray { get set }
    var context: ChangeContext { get set }
}

class JSONArray<T>: JSONArrayable {
    var target: CRDTArray
    var context: ChangeContext

    init(target: CRDTArray, changeContext: ChangeContext) {
        self.target = target
        self.context = changeContext
    }

    func getID() -> TimeTicket {
        return self.target.getCreatedAt()
    }
}
