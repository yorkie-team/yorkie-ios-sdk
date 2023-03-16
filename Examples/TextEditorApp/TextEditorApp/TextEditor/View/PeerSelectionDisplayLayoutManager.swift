/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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

class PeerSelectionDisplayLayoutManager: NSLayoutManager {
    private static let AttributeKeyPrefix = "PEER_SELECT_"

    static func createKey(_ id: String) -> NSAttributedString.Key {
        NSAttributedString.Key(rawValue: "\(Self.AttributeKeyPrefix)\(id)")
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        textStorage?.enumerateAttributes(in: characterRange) { attrs, subrange, _ in
            let colors = Array(attrs.filter { $0.key.rawValue.starts(with: Self.AttributeKeyPrefix) }.compactMapValues { $0 as? UIColor }.values)

            let tokenGlypeRange = glyphRange(forCharacterRange: subrange, actualCharacterRange: nil)
            self.drawBackground(forGlyphRange: tokenGlypeRange, at: origin, colors: colors)
        }

        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawBackground(forGlyphRange tokenGlypeRange: NSRange, at origin: CGPoint, colors: [UIColor]) {
        guard let textContainer = textContainer(forGlyphAt: tokenGlypeRange.location, effectiveRange: nil) else { return }

        let withinRange = NSRange(location: NSNotFound, length: 0)

        enumerateEnclosingRects(forGlyphRange: tokenGlypeRange, withinSelectedGlyphRange: withinRange, in: textContainer) { rect, _ in
            let tokenRect = rect.offsetBy(dx: origin.x, dy: origin.y)

            colors.forEach { color in
                color.setFill()
                UIBezierPath(rect: tokenRect).fill()
            }
        }
    }
}
