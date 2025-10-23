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

import UIKit

extension UIFont {
    func addBold() -> UIFont {
        let font: UIFont = self
        var combinedTraits = font.fontDescriptor.symbolicTraits

        let fontDescriptor = font.fontDescriptor
        combinedTraits.insert(.traitBold)
        guard let boldItalicDescriptor = fontDescriptor.withSymbolicTraits(combinedTraits) else {
            fatalError()
        }
        let boldItalicFont = UIFont(descriptor: boldItalicDescriptor, size: font.pointSize)
        return boldItalicFont
    }

    func removeBold() -> UIFont {
        let font: UIFont = self
        var combinedTraits = font.fontDescriptor.symbolicTraits

        let fontDescriptor = font.fontDescriptor
        combinedTraits.remove(.traitBold)
        guard let boldItalicDescriptor = fontDescriptor.withSymbolicTraits(combinedTraits) else {
            fatalError()
        }
        let boldItalicFont = UIFont(descriptor: boldItalicDescriptor, size: font.pointSize)
        return boldItalicFont
    }

    func addItalic() -> UIFont {
        let font: UIFont = self
        var combinedTraits = font.fontDescriptor.symbolicTraits

        let fontDescriptor = font.fontDescriptor
        combinedTraits.insert(.traitItalic)
        guard let boldItalicDescriptor = fontDescriptor.withSymbolicTraits(combinedTraits) else {
            fatalError()
        }
        let boldItalicFont = UIFont(descriptor: boldItalicDescriptor, size: font.pointSize)
        return boldItalicFont
    }

    func removeItalic() -> UIFont {
        let font: UIFont = self
        var combinedTraits = font.fontDescriptor.symbolicTraits

        let fontDescriptor = font.fontDescriptor
        combinedTraits.remove(.traitItalic)
        guard let boldItalicDescriptor = fontDescriptor.withSymbolicTraits(combinedTraits) else {
            fatalError()
        }
        let boldItalicFont = UIFont(descriptor: boldItalicDescriptor, size: font.pointSize)
        return boldItalicFont
    }
}

extension UIFont {
    static let defaulf = UIFont(name: "SpaceMono-Regular", size: Constant.TextInfo.fontSize)!
    var isBold: Bool {
        return fontDescriptor.symbolicTraits.contains(.traitBold)
    }

    var isItalic: Bool {
        return fontDescriptor.symbolicTraits.contains(.traitItalic)
    }

    var isNormal: Bool {
        return !self.isBold && !self.isItalic
    }

    func boldSelf() -> UIFont {
        self.addBold()
    }

    func unBoldSelf() -> UIFont {
        self.removeBold()
    }

    func italicSelf() -> UIFont {
        self.addItalic()
    }

    func unItalicSelf() -> UIFont {
        self.removeItalic()
    }
}
