/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
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

import Foundation

public enum JSONTreeNode: Equatable {
    case textNode(TextNode)
    case elementNode(ElementNode)

    public static func == (lhs: JSONTreeNode, rhs: JSONTreeNode) -> Bool {
        if case .textNode(let lhsNode) = lhs, case .textNode(let rhsNode) = rhs {
            return lhsNode == rhsNode
        } else if case .elementNode(let lhsNode) = lhs, case .elementNode(let rhsNode) = rhs {
            return lhsNode == rhsNode
        } else {
            return false
        }
    }
}

struct TreeChangeWithPath {
    let actor: ActorID
    let type: TreeChangeType
    let from: [Int]
    let to: [Int]
    let fromPath: [Int]
    let toPath: [Int]
    let value: TreeChangeValue?
}

/**
 * `ElementNode` is a node that has children.
 */
public struct ElementNode: Equatable {
    let type: TreeNodeType
    let attributes: [String: String]?
    let children: [JSONTreeNode]
}

/**
 * `TextNode` is a node that has a value.
 */
public struct TextNode: Equatable {
    let type = TreeNodeType.text
    let value: String
}

/**
 * `buildDescendants` builds descendants of the given tree node.
 */
func buildDescendants(treeNode: JSONTreeNode, parent: CRDTTreeNode, context: ChangeContext) throws {
    let ticket = context.issueTimeTicket()

    switch treeNode {
    case .textNode(let node):
        let textNode = CRDTTreeNode(pos: CRDTTreePos(createdAt: ticket, offset: 0), type: .text, value: node.value)

        try parent.append(newNode: [textNode])
    case .elementNode(let node):
        let attrs = RHT()

        node.attributes?.forEach { key, value in
            attrs.set(key: key, value: value, executedAt: ticket)
        }

        let elementNode = CRDTTreeNode(pos: CRDTTreePos(createdAt: ticket, offset: 0), type: node.type, attributes: attrs.size == 0 ? nil : attrs)

        try parent.append(newNode: [elementNode])

        try node.children.forEach { child in
            try buildDescendants(treeNode: child, parent: elementNode, context: context)
        }
    }
}

/**
 * createCRDTTreeNode returns CRDTTreeNode by given TreeNode.
 */
func createCRDTTreeNode(context: ChangeContext, content: JSONTreeNode) throws -> CRDTTreeNode {
    let ticket = context.issueTimeTicket()

    let root: CRDTTreeNode
    switch content {
    case .textNode(let node):
        root = CRDTTreeNode(pos: CRDTTreePos(createdAt: ticket, offset: 0), type: node.type)
    case .elementNode(let node):
        let attrs = RHT()

        node.attributes?.forEach { key, value in
            attrs.set(key: key, value: value, executedAt: ticket)
        }

        root = CRDTTreeNode(pos: CRDTTreePos(createdAt: ticket, offset: 0), type: node.type, attributes: attrs.size == 0 ? nil : attrs)

        try node.children.forEach { child in
            try buildDescendants(treeNode: child, parent: root, context: context)
        }
    }

    return root
}

/**
 * `JSONTree` is a CRDT-based tree structure that is used to represent the document
 * tree of text-based editor such as ProseMirror.
 */
public class JSONTree {
    private let initialRoot: ElementNode?
    private let context: ChangeContext?
    private let tree: CRDTTree?

    init(initialRoot: ElementNode? = nil, context: ChangeContext?, tree: CRDTTree?) {
        self.initialRoot = initialRoot
        self.context = context
        self.tree = tree
    }

    /**
     * `id` returns the ID of this tree.
     */
    public var id: TimeTicket? {
        self.tree?.id
    }

    /**
     * `buildRoot` returns the root node of this tree.
     */
    func buildRoot(context: ChangeContext) throws -> CRDTTreeNode {
        guard let initialRoot else {
            return CRDTTreeNode(pos: CRDTTreePos(createdAt: context.issueTimeTicket(), offset: 0), type: .root)
        }

        // TODO(hackerwins): Need to use the ticket of operation of creating tree.
        let root = CRDTTreeNode(pos: CRDTTreePos(createdAt: context.issueTimeTicket(), offset: 0), type: initialRoot.type)

        try self.initialRoot?.children.forEach { child in
            try buildDescendants(treeNode: child, parent: root, context: context)
        }

        return root
    }

    /**
     * `getSize` returns the size of this tree.
     */
    public func getSize() throws -> Int {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return tree.size
    }

    /**
     * `getIndexTree` returns the index tree of this tree.
     */
    func getIndexTree() throws -> IndexTree<CRDTTreeNode> {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return tree.indexTree
    }

    /**
     * `styleByPath` sets the attributes to the elements of the given path.
     */
    public func styleByPath(path: [Int], attributes: [String: String]) throws {
        guard let context, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if path.isEmpty {
            throw YorkieError.unexpected(message: "path should not be empty")
        }

        let (fromPos, toPos) = try tree.pathToPosRange(path: path)
        let ticket = context.issueTimeTicket()

        try tree.style(range: (fromPos, toPos), attributes: attributes, editedAt: ticket)

        // TreeStyleOperation
//        context.push(
//            TreeStyleOperation.create(
//                tree.getCreatedAt(),
//                fromPos,
//                toPos,
//                attrs != nil ? Dictionary(uniqueKeysWithValues: attrs!.map { ($0.key, $0.value) }) : [:],
//                ticket
//            )
//        )
    }

    /**
     * `style` sets the attributes to the elements of the given range.
     */
    public func style(fromIdx: Int, toIdx: Int, attributes: [String: String]) throws {
        guard let context, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if fromIdx > toIdx {
            throw YorkieError.unexpected(message: "from should be less than or equal to to")
        }

        let fromPos = try tree.findPos(index: fromIdx)
        let toPos = try tree.findPos(index: toIdx)
        let ticket = context.issueTimeTicket()

        try tree.style(range: (fromPos, toPos), attributes: attributes, editedAt: ticket)

//        context.push(
//            TreeStyleOperation.create(
//                tree.getCreatedAt(),
//                fromPos,
//                toPos,
//                attrs != nil ? Dictionary(uniqueKeysWithValues: attrs!.map { ($0.key, $0.value) }) : [:],
//                ticket
//            )
//        )
    }

    /**
     * `editByPath` edits this tree with the given node and path.
     */
    public func editByPath(fromPath: [Int], toPath: [Int], content: JSONTreeNode?) throws -> Bool {
        guard let context, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if fromPath.count != toPath.count {
            throw YorkieError.unexpected(message: "path length should be equal")
        }

        if fromPath.isEmpty || toPath.isEmpty {
            throw YorkieError.unexpected(message: "path should not be empty")
        }

        let crdtNode = content != nil ? try createCRDTTreeNode(context: context, content: content!) : nil
        let fromPos = try tree.pathToPos(path: fromPath)
        let toPos = try tree.pathToPos(path: toPath)
        let ticket = context.lastTimeTicket
        try tree.edit(range: (fromPos, toPos), content: crdtNode?.deepcopy(), editedAt: ticket)

//        context.push(
//            TreeEditOperation.create(
//                tree.getCreatedAt(),
//                fromPos,
//                toPos,
//                crdtNode,
//                ticket
//            )
//        )

        if fromPos != toPos {
            context.registerElementHasRemovedNodes(tree)
        }

        return true
    }

    /**
     * `edit` edits this tree with the given node.
     */
    public func edit(fromIdx: Int, toIdx: Int, content: JSONTreeNode?) throws -> Bool {
        guard let context, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        if fromIdx > toIdx {
            throw YorkieError.unexpected(message: "from should be less than or equal to to")
        }

        let crdtNode = content != nil ? try createCRDTTreeNode(context: context, content: content!) : nil
        let fromPos = try tree.findPos(index: fromIdx)
        let toPos = try tree.findPos(index: toIdx)
        let ticket = context.lastTimeTicket
        try tree.edit(range: (fromPos, toPos), content: crdtNode?.deepcopy(), editedAt: ticket)

//        context.push(
//            TreeEditOperation.create(
//                createdAt: tree.getCreatedAt(),
//                fromPos: fromPos,
//                toPos: toPos,
//                crdtNode: crdtNode,
//                ticket: ticket
//            )
//        )

        if fromPos != toPos {
            context.registerElementHasRemovedNodes(tree)
        }

        return true
    }

    /**
     * `split` splits this tree at the given index.
     */
    public func split(index: Int, depth: Int) throws -> Bool {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        try tree.split(index: index, depth: depth)
        return true
    }

    /**
     * `toXML` returns the XML string of this tree.
     */
    public func toXML() throws -> String {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return tree.toXML
    }

    /**
     * `toJSON` returns the JSON string of this tree.
     */
    public func toJSON() throws -> String {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return tree.toJSON()
    }

    /**
     * `indexToPath` returns the path of the given index.
     */
    public func indexToPath(index: Int) throws -> [Int] {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return try tree.indexToPath(index: index)
    }

//    /**
//     * eslint-disable-next-line jsdoc/require-jsdoc
//     * @internal
//     */
//    public *[Symbol.iterator](): IterableIterator<TreeNode> {
//        if (!this.tree) {
//            return;
//        }
//
//        // TODO(hackerwins): Fill children of element node later.
//        for (const node of this.tree) {
//            if (node.isText) {
//                const textNode = node as TextNode;
//                yield {
//                type: textNode.type,
//                value: textNode.value,
//                };
//            } else {
//                const elementNode = node as ElementNode;
//                yield {
//                type: elementNode.type,
//                children: [],
//                };
//            }
//        }
//    }

    /**
     * `createRange` returns pair of CRDTTreePos of the given integer offsets.
     */
    func createRange(fromIdx: Int, toIdx: Int) throws -> TreeRange? {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return try tree.createRange(fromIdx: fromIdx, toIdx: toIdx)
    }

    /**
     * `createRangeByPath` returns pair of CRDTTreePos of the given integer offsets.
     */
    func createRangeByPath(fromPath: [Int], toPath: [Int]) throws -> TreeRange? {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        let fromIdx = try tree.pathToIndex(path: fromPath)
        let toIdx = try tree.pathToIndex(path: toPath)

        return try tree.createRange(fromIdx: fromIdx, toIdx: toIdx)
    }

    /**
     * `rangeToIndex` returns the integer offsets of the given range.
     */
    func rangeToIndex(range: TreeRange) throws -> (Int, Int) {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return try tree.rangeToIndex(range: range)
    }

    /**
     * `rangeToPath` returns the path of the given range.
     */
    func rangeToPath(range: TreeRange) throws -> ([Int], [Int]) {
        guard self.context != nil, let tree else {
            throw YorkieError.unexpected(message: "it is not initialized yet")
        }

        return try tree.rangeToPath(range: range)
    }
}

/*
 public struct TreeIterator: IteratorProtocol {
     private let tree: JSONTree?
     private var iterator: TreeIteratorProtocol?

     init(tree: Tree?) {
         self.tree = tree
         self.iterator = tree?.makeIterator()
     }

     mutating public func next() -> TreeNode? {
         guard let iterator = iterator?.next() else {
             return nil
         }

         if iterator.isText {
             if let textNode = iterator as? TextNode {
                 return TreeNode(type: textNode.type, value: textNode.value)
             }
         } else {
             if let elementNode = iterator as? ElementNode {
                 return TreeNode(type: elementNode.type, children: [])
             }
         }

         return nil
     }
 }

 extension TreeWrapper: Sequence {
     public func makeIterator() -> TreeIterator {
         return TreeIterator(tree: self.tree)
     }
 }
 */
