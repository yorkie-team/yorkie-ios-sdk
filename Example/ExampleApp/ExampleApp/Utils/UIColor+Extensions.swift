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

extension UIColor {
    convenience init(hex: String) {
        var hex = hex
        if hex.hasPrefix("#") {
            hex.remove(at: hex.startIndex)
        }

        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)

        if hex.count == 6 {
            let red = CGFloat((rgb >> 16) & 0xFF) / 255.0
            let green = CGFloat((rgb >> 8) & 0xFF) / 255.0
            let blue = CGFloat(rgb & 0xFF) / 255.0
            self.init(red: red, green: green, blue: blue, alpha: 1.0)
        } else {
            let red = CGFloat((rgb >> 32) & 0xFF) / 255.0
            let green = CGFloat((rgb >> 16) & 0xFF) / 255.0
            let blue = CGFloat(rgb >> 8) / 255.0
            let alpha = CGFloat(rgb & 0xFF) / 255.0
            self.init(red: red, green: green, blue: blue, alpha: alpha)
        }
    }
}
