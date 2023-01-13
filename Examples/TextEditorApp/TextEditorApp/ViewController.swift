//
//  ViewController.swift
//  TextEditorApp
//
//  Created by Jung gyun Ahn on 2023/01/13.
//

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

        self.view.addSubview(self.textEditorButton)
        self.textEditorButton.topAnchor.constraint(equalTo: self.view.layoutMarginsGuide.topAnchor, constant: 50).isActive = true
        self.textEditorButton.leadingAnchor.constraint(equalTo: self.view.layoutMarginsGuide.leadingAnchor).isActive = true
        self.textEditorButton.trailingAnchor.constraint(equalTo: self.view.layoutMarginsGuide.trailingAnchor).isActive = true
        self.textEditorButton.heightAnchor.constraint(equalToConstant: 50).isActive = true

        self.textEditorButton.addTarget(self, action: #selector(self.didTapTextEditorButton), for: .touchUpInside)
    }

    @objc private func didTapTextEditorButton() {
        let viewController = TextEditorViewController()
        viewController.modalPresentationStyle = .fullScreen
        self.present(viewController, animated: true)
    }
}
