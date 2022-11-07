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

import UIKit

enum KanbanLayoutProperty {
    static let background: UIColor = .init(hex: "#3b5998")
    static let columnBackground: UIColor = .init(hex: "#f7f7f7")
    static let cellSidePadding: CGFloat = 10
    static let columnTitleFont: UIFont = UIFont.boldSystemFont(ofSize: 17)
    static let labelFont: UIFont = UIFont.systemFont(ofSize: 15)
    static let labelHeight: CGFloat = 50
    static let labelPadding: CGFloat = 10
    static let trashButtonWidth: CGFloat = 30
    static let sectionSpacing: CGFloat = 10
}
