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

enum ElementConverter {
    static func toWrappedElement(from value: CRDTElement, context: ChangeContext) -> Any? {
        if let value = value as? Primitive {
            return value
        } else if let object = value as? CRDTObject {
            return JSONObject(target: object, context: context)
        } else if let array = value as? CRDTArray {
            return JSONArray(target: array, changeContext: context)
        } else {
            return nil
        }
    }

    static func toJSONElement(from value: CRDTElement, context: ChangeContext) -> Any? {
        if let value = value as? Primitive {
            switch value.value {
            case .null:
                return nil
            case .boolean(let result):
                return result
            case .integer(let result):
                return result
            case .long(let result):
                return result
            case .double(let result):
                return result
            case .string(let result):
                return result
            case .bytes(let result):
                return result
            case .date(let result):
                return result
            }
        } else if let object = value as? CRDTObject {
            return JSONObject(target: object, context: context)
        } else if let array = value as? CRDTArray {
            return JSONArray(target: array, changeContext: context)
        } else if let value = value as? CRDTCounter<Int32> {
            let counter = JSONCounter(value: value.value)
            counter.initialize(context: context, counter: value)
            return counter
        } else if let value = value as? CRDTCounter<Int64> {
            let counter = JSONCounter(value: value.value)
            counter.initialize(context: context, counter: value)
            return counter
        } else {
            return nil
        }
    }
}
