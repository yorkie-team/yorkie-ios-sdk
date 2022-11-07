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

import Combine
import UIKit

@MainActor
class KanbanViewController: UIViewController {
    private var cancellables = Set<AnyCancellable>()
    private let itemHeight: CGFloat = KanbanLayoutProperty.labelHeight
    private var width: CGFloat {
        UIScreen.main.bounds.width
    }

    private let viewModel: KanbanViewModel

    private let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        let result = UICollectionView(frame: CGRect.zero, collectionViewLayout: layout)
        result.translatesAutoresizingMaskIntoConstraints = false
        result.backgroundColor = KanbanLayoutProperty.background
        return result
    }()

    private let addColumnButton: UIButton = {
        let result = UIButton()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setTitle("+ Add another list", for: .normal)
        result.setTitleColor(UIColor(hex: "#f7f7f7"), for: .normal)
        result.setTitleColor(UIColor.lightGray, for: .highlighted)
        result.backgroundColor = UIColor.darkGray
        result.layer.borderColor = UIColor.clear.cgColor
        result.layer.borderWidth = 1
        result.layer.cornerRadius = 5
        result.clipsToBounds = true
        return result
    }()

    init() {
        self.viewModel = KanbanViewModel()

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.view.addSubview(self.collectionView)
        self.collectionView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor).isActive = true
        self.collectionView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor).isActive = true
        self.collectionView.topAnchor.constraint(equalTo: self.view.topAnchor).isActive = true
        self.collectionView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor).isActive = true

        self.collectionView.register(KanbanViewCardCell.self,
                                     forCellWithReuseIdentifier: KanbanViewCardCell.identifier)
        self.collectionView.register(KanbanViewCardHeader.self,
                                     forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: KanbanViewCardHeader.identifier)
        self.collectionView.register(KanbanViewCardFooter.self,
                                     forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter, withReuseIdentifier: KanbanViewCardFooter.identifier)
        self.collectionView.dataSource = self
        self.collectionView.delegate = self

        self.view.addSubview(self.addColumnButton)
        self.addColumnButton.bottomAnchor.constraint(equalTo: self.view.bottomAnchor, constant: -10).isActive = true
        self.addColumnButton.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 10).isActive = true
        self.addColumnButton.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -10).isActive = true
        self.addColumnButton.heightAnchor.constraint(equalToConstant: 35).isActive = true
        self.addColumnButton.addTarget(self, action: #selector(self.didClickAddColumnButton), for: .touchUpInside)

        self.viewModel.objectWillChange
            .sink { [weak self] _ in
                self?.collectionView.reloadData()
            }.store(in: &self.cancellables)
    }

    @objc private func didClickAddColumnButton() {
        let alert = UIAlertController(title: "Add a list", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Enter list title"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let addAction = UIAlertAction(title: "Add", style: .default) { _ in
            guard let textField = alert.textFields?[0], let text = textField.text else { return }
            self.viewModel.addColumn(title: text)
        }
        alert.addAction(addAction)
        present(alert, animated: true)
    }
}

extension KanbanViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        self.viewModel.columns[section].cards.count
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        self.viewModel.columns.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: KanbanViewCardCell.identifier, for: indexPath)

        guard let result = cell as? KanbanViewCardCell else {
            return cell
        }

        let column = self.viewModel.columns[indexPath.section]
        result.configure(with: column.cards[indexPath.item])
        result.deleteCard = { [weak self] card in
            guard let self else { return }
            self.viewModel.deleteCard(card)
        }

        return result
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let result: UICollectionReusableView
        if kind == UICollectionView.elementKindSectionHeader {
            result = collectionView.dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader,
                                                                     withReuseIdentifier: KanbanViewCardHeader.identifier,
                                                                     for: indexPath)
            if let view = result as? KanbanViewCardHeader {
                view.configure(with: self.viewModel.columns[indexPath.section])
                view.deleteColumn = { [weak self] column in
                    guard let self else { return }
                    self.viewModel.deleteColumn(column)
                }
            }

        } else {
            result = collectionView.dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionFooter,
                                                                     withReuseIdentifier: KanbanViewCardFooter.identifier,
                                                                     for: indexPath)
            if let view = result as? KanbanViewCardFooter {
                view.configure(with: self.viewModel.columns[indexPath.section])
                view.showAddCardView = { [weak self] column in
                    guard let self else { return }
                    self.showAddCardAlert(column: column)
                }
            }
        }

        return result
    }
}

extension KanbanViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: 50)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForFooterInSection section: Int) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: 50)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: self.itemHeight)
    }
}

extension KanbanViewController {
    func showAddCardAlert(column: KanbanColumn) {
        let alert = UIAlertController(title: "Add a card", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Enter card title"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let addAction = UIAlertAction(title: "Add", style: .default) { _ in
            guard let textField = alert.textFields?[0], let text = textField.text else { return }
            self.viewModel.addCard(title: text, columnId: column.id)
        }
        alert.addAction(addAction)
        present(alert, animated: true)
    }
}
