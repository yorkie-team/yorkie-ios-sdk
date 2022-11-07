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

class KanbanViewCardFooter: UICollectionReusableView {
    static var identifier = String(describing: KanbanViewCardFooter.self)
    static let buttonHeight: CGFloat = 40
    static let buttonWidth: CGFloat = 70
    static let buttonTopMargin: CGFloat = 10

    private let showAddCardButton: UIButton = {
        let result = UIButton()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setTitle("+ Add another card", for: .normal)
        result.setTitleColor(UIColor.gray, for: .normal)
        result.setTitleColor(UIColor.lightGray, for: .highlighted)
        result.contentHorizontalAlignment = .left
        result.contentVerticalAlignment = .center
        result.titleLabel?.font = KanbanLayoutProperty.labelFont
        return result
    }()

    private var column: KanbanColumn?

    var showAddCardView: ((_ column: KanbanColumn) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.backgroundColor = KanbanLayoutProperty.columnBackground

        self.addSubview(self.showAddCardButton)
        self.showAddCardButton.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: KanbanLayoutProperty.cellSidePadding + KanbanLayoutProperty.labelPadding).isActive = true
        self.showAddCardButton.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -KanbanLayoutProperty.cellSidePadding + KanbanLayoutProperty.labelPadding).isActive = true
        self.showAddCardButton.topAnchor.constraint(equalTo: self.topAnchor).isActive = true
        self.showAddCardButton.heightAnchor.constraint(equalToConstant: KanbanLayoutProperty.labelHeight).isActive = true
        self.showAddCardButton.addTarget(self, action: #selector(self.didClickShowAddCardButton), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        self.column = nil
        self.showAddCardView = nil
    }

    func configure(with column: KanbanColumn) {
        self.column = column
    }

    @objc private func didClickShowAddCardButton() {
        guard let item = self.column else { return }
        self.showAddCardView?(item)
    }
}
