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

class ViewController: UIViewController {
    private let textEditorButton: UIButton = {
        let result = UIButton()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setTitle("Text Editor", for: .normal)
        result.setTitleColor(UIColor.black, for: .normal)
        result.setTitleColor(UIColor.gray, for: .highlighted)
        result.layer.borderColor = UIColor.black.cgColor
        result.layer.borderWidth = 1
        result.layer.cornerRadius = 5
        return result
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        self.title = "Yorkie Sample"

        self.view.addSubview(self.textEditorButton)
        self.textEditorButton.topAnchor.constraint(equalTo: self.view.layoutMarginsGuide.topAnchor, constant: 50).isActive = true
        self.textEditorButton.leadingAnchor.constraint(equalTo: self.view.layoutMarginsGuide.leadingAnchor).isActive = true
        self.textEditorButton.trailingAnchor.constraint(equalTo: self.view.layoutMarginsGuide.trailingAnchor).isActive = true
        self.textEditorButton.heightAnchor.constraint(equalToConstant: 50).isActive = true

        self.textEditorButton.addTarget(self, action: #selector(self.didTapTextEditorButton), for: .touchUpInside)
    }

    @objc private func didTapTextEditorButton() {
        let viewController = TextEditorViewController()

        self.navigationController?.pushViewController(viewController, animated: true)
    }
}
