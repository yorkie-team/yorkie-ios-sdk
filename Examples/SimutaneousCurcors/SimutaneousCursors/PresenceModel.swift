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

struct Cursor: Codable {
    let xPos: Double
    let yPos: Double
}

struct PresenceModel: Codable {
    let name: String
    let pointerDown: Int
    let cursorShape: CursorShape
    let cursor: Cursor
}

enum CursorShape: String, Codable {
    case heart
    case thumbs
    case pen
    case cursor
    
    var systemImageName: String {
        switch self {
        case .heart: return "heart.fill"
        case .thumbs: return "hand.draw.badge.ellipsis"
        case .pen: return "pencil.and.scribble"
        case .cursor: return "location.fill"
        }
    }
}

struct Model: Codable, Identifiable {
    var id: String { clientID }
    
    let clientID: String
    let presence: PresenceModel
}
