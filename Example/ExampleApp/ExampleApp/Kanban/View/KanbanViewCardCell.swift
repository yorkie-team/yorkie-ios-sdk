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

class KanbanViewCardCell: UICollectionViewCell {
    static var identifier = String(describing: KanbanViewCardCell.self)

    private let titleLabel: UILabel = {
        let result = Label()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.backgroundColor = UIColor.white
        result.layer.borderColor = UIColor.clear.cgColor
        result.layer.borderWidth = 1
        result.layer.cornerRadius = 5
        result.clipsToBounds = true
        return result
    }()

    private let deleteButton: UIButton = {
        let result = UIButton()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setImage(UIImage(systemName: "trash"), for: .normal)
        return result
    }()

    private var card: KanbanCard?

    var deleteCard: ((_ column: KanbanCard) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.contentView.backgroundColor = KanbanLayoutProperty.columnBackground
        self.contentView.addSubview(self.titleLabel)
        self.titleLabel.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: KanbanLayoutProperty.cellSidePadding).isActive = true
        self.titleLabel.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -KanbanLayoutProperty.cellSidePadding).isActive = true
        self.titleLabel.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 5).isActive = true
        self.titleLabel.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -5).isActive = true

        self.contentView.addSubview(self.deleteButton)
        self.deleteButton.widthAnchor.constraint(equalToConstant: KanbanLayoutProperty.trashButtonWidth).isActive = true
        self.deleteButton.trailingAnchor.constraint(equalTo: self.titleLabel.trailingAnchor, constant: -KanbanLayoutProperty.cellSidePadding).isActive = true
        self.deleteButton.centerYAnchor.constraint(equalTo: self.titleLabel.centerYAnchor).isActive = true
        self.deleteButton.addTarget(self, action: #selector(self.didClickDeleteCard), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        self.card = nil
        self.deleteCard = nil
    }

    func configure(with card: KanbanCard) {
        self.card = card
        self.titleLabel.text = card.title
    }

    @objc private func didClickDeleteCard() {
        guard let card = self.card else { return }
        self.deleteCard?(card)
    }
}
