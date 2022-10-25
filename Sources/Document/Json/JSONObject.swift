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

protocol JSONSpec {
    init()
    static var keyMap: [AnyKeyPath: String] { get }
}

protocol JSONObjectable: AnyObject {
    var dataHandler: ObjectDataHandler? { get set }
}

/**
 * `JSONObject` represents a JSON object, but unlike regular JSON, it has time
 * tickets created by a logical clock to resolve conflicts.
 */
@dynamicMemberLookup
class JSONObject<T: JSONSpec>: JSONObjectable {
    var dataHandler: ObjectDataHandler?
    private var jsonSpec: T
    private let keyMap: [AnyKeyPath: String]

    init() {
        self.jsonSpec = T()
        self.keyMap = T.keyMap
    }

    init(target: CRDTObject, context: ChangeContext) {
        self.dataHandler = ObjectDataHandler(target: target, context: context)
        self.jsonSpec = T()
        self.keyMap = T.keyMap
    }

    subscript<V>(dynamicMember member: WritableKeyPath<T, V>) -> V {
        get {
            guard let key = self.keyMap[member] else {
                assertionFailure("Must define a label for keyPath\(String(describing: member))")
                return self.jsonSpec[keyPath: member]
            }

            Logger.trivial("obj[\(key)]")

            let defaultValue = self.jsonSpec[keyPath: member]

            guard let dataHandler = self.dataHandler else {
                Logger.error("This instance is not binded.")
                return defaultValue
            }

            let value = try? dataHandler.get(key: key)
            if let jsonObject = defaultValue as? JSONObjectable,
               let crdtObject = value as? CRDTObject
            {
                jsonObject.dataHandler = ObjectDataHandler(target: crdtObject, context: dataHandler.context)
                return jsonObject as? V ?? defaultValue
            } else if let crdtArray = value as? CRDTArray, let jsonArray = defaultValue as? JSONArrayable {
                jsonArray.target = crdtArray
                jsonArray.context = dataHandler.context
                return jsonArray as? V ?? defaultValue
            } else {
                return value as? V ?? defaultValue
            }
        }

        set {
            guard let key = self.keyMap[member] else {
                assertionFailure("Must define a label for keyPath\(String(describing: member))")
                return
            }

            Logger.trivial("obj[\(key)]=\(String(describing: newValue))")

            guard let dataHandler = self.dataHandler else {
                Logger.error("This instance is not binded.")
                return
            }

            if let value = newValue as? JSONObjectable {
                let crdtObject: CRDTObject
                if let value = try? dataHandler.get(key: key) as? CRDTObject {
                    crdtObject = value
                } else {
                    crdtObject = CRDTObject(createdAt: dataHandler.context.issueTimeTicket())
                }

                let valueObject = ObjectDataHandler(target: crdtObject, context: dataHandler.context)
                value.dataHandler = valueObject

                dataHandler.set(key: key, value: valueObject.target)
                self.jsonSpec[keyPath: member] = newValue
            } else if let value = newValue as? JSONArrayable {
                let crdtArray: CRDTArray
                if let value = try? dataHandler.get(key: key) as? CRDTArray {
                    crdtArray = value
                } else {
                    crdtArray = CRDTArray(createdAt: dataHandler.context.issueTimeTicket())
                }

                value.target = crdtArray
                value.context = dataHandler.context

                dataHandler.set(key: key, value: value.target)
                self.jsonSpec[keyPath: member] = newValue
            } else {
                dataHandler.set(key: key, value: newValue)
            }
        }
    }

    /**
     * `getID` returns the ID(time ticket) of this Object.
     */
    func getID() -> TimeTicket? {
        self.dataHandler?.target.getCreatedAt()
    }

    /**
     * `toJSON` returns the JSON encoding of this object.
     */
    func toJson() -> String {
        self.dataHandler?.target.toJSON() ?? "{}"
    }

    func toSortedJSON() -> String {
        self.dataHandler?.target.toSortedJSON() ?? "{}"
    }

    func remove(member: AnyKeyPath) throws {
        guard let key = self.keyMap[member] else {
            return
        }

        Logger.trivial("obj[\(key)]")

        try self.dataHandler?.remove(key: key)
    }

    func setWithDictionary(values: [AnyKeyPath: Any]) {}
}

extension JSONObject: CustomStringConvertible {
    var description: String {
        self.toJson()
    }
}
