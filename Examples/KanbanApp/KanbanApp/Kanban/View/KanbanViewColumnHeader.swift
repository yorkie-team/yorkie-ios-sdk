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

class KanbanViewCardHeader: UICollectionReusableView {
    static var identifier = String(describing: KanbanViewCardHeader.self)

    private let spaceView: UIView = {
        let result = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.backgroundColor = UIColor.clear
        return result
    }()

    private let titleLabel: UILabel = {
        let result = Label()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.font = KanbanLayoutProperty.columnTitleFont
        return result
    }()

    private let deleteButton: UIButton = {
        let result = UIButton()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setImage(UIImage(systemName: "trash"), for: .normal)
        return result
    }()

    var deleteColumn: ((_ column: KanbanColumn) -> Void)?

    private var column: KanbanColumn?

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.backgroundColor = KanbanLayoutProperty.columnBackground

        self.addSubview(self.spaceView)
        self.spaceView.topAnchor.constraint(equalTo: self.topAnchor).isActive = true
        self.spaceView.leadingAnchor.constraint(equalTo: self.leadingAnchor).isActive = true
        self.spaceView.trailingAnchor.constraint(equalTo: self.trailingAnchor).isActive = true
        self.spaceView.heightAnchor.constraint(equalToConstant: KanbanLayoutProperty.sectionSpacing).isActive = true
        self.spaceView.backgroundColor = KanbanLayoutProperty.background

        self.addSubview(self.deleteButton)
        self.deleteButton.widthAnchor.constraint(equalToConstant: KanbanLayoutProperty.trashButtonWidth).isActive = true
        self.deleteButton.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -KanbanLayoutProperty.cellSidePadding * 2).isActive = true
        self.deleteButton.topAnchor.constraint(equalTo: self.spaceView.bottomAnchor).isActive = true
        self.deleteButton.bottomAnchor.constraint(equalTo: self.bottomAnchor).isActive = true
        self.deleteButton.addTarget(self, action: #selector(self.didClickDeleteButton), for: .touchUpInside)

        self.addSubview(self.titleLabel)
        self.titleLabel.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: KanbanLayoutProperty.cellSidePadding * 2).isActive = true
        self.titleLabel.trailingAnchor.constraint(equalTo: self.deleteButton.leadingAnchor, constant: -KanbanLayoutProperty.cellSidePadding).isActive = true
        self.titleLabel.topAnchor.constraint(equalTo: self.spaceView.bottomAnchor).isActive = true
        self.titleLabel.bottomAnchor.constraint(equalTo: self.bottomAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        self.column = nil
        self.deleteColumn = nil
    }

    func configure(with column: KanbanColumn) {
        self.column = column
        self.titleLabel.text = column.title
    }

    @objc private func didClickDeleteButton() {
        guard let column = self.column else { return }
        self.deleteColumn?(column)
    }
}
