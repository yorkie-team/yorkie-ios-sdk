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

/**
 * About `index`, `path`, `size` and `TreePos` in crdt.IndexTree.
 *
 * `index` of crdt.IndexTree represents a absolute position of a node in the tree.
 * `size` is used to calculate the relative index of nodes in the tree.
 * `index` in yorkie.IndexTree inspired by ProseMirror's index.
 *
 * For example, empty paragraph's size is 0 and index 0 is the position of the:
 *    0
 * <p> </p>,                                p.size = 0
 *
 * If a paragraph has <i>, its size becomes 2 and there are 3 indexes:
 *     0   1    2
 *  <p> <i> </i> </p>                       p.size = 2, i.size = 0
 *
 * If the paragraph has <i> and <b>, its size becomes 4:
 *     0   1    2   3   4
 *  <p> <i> </i> <b> </b> </p>              p.size = 4, i.size = 0, b.size = 0
 *     0   1    2   3    4    5   6
 *  <p> <i> </i> <b> </b> <s> </s> </p>     p.size = 6, i.size = 0, b.size = 0, s.size = 0
 *
 * If a paragraph has text, its size becomes length of the characters:
 *     0 1 2 3
 *  <p> A B C </p>                          p.size = 3,   text.size = 3
 *
 * So the size of a node is the sum of the size and type of its children:
 *  `size = children(element type).length * 2 + children.reduce((child, acc) => child.size + acc, 0)`
 *
 * `TreePos` is also used to represent the position in the tree. It contains node and offset.
 * `TreePos` can be converted to `index` and vice versa.
 *
 * For example, if a paragraph has <i>, there are 3 indexes:
 *     0   1    2
 *  <p> <i> </i> </p>                       p.size = 2, i.size = 0
 *
 * In this case, index of TreePos(p, 0) is 0, index of TreePos(p, 1) is 2.
 * Index 1 can be converted to TreePos(i, 0).
 *
 * `path` of crdt.IndexTree represents a position like `index` in crdt.IndexTree.
 * It contains offsets of each node from the root node as elements except the last.
 * The last element of the path represents the position in the parent node.
 *
 * Let's say we have a tree like this:
 *                     0 1 2
 * <p> <i> a b </i> <b> c d </b> </p>
 *
 * The path of the position between 'c' and 'd' is [1, 1]. The first element of the
 * path is the offset of the <b> in <p> and the second element represents the position
 * between 'c' and 'd' in <b>.
 */

/**
 * `NoteType` is the type of a node in the tree.
 */
public typealias TreeNodeType = String

enum DefaultTreeNodeType: String {
    /**
     * DummyHeadType is a type of dummy head. It is used to represent the head node
     * of RGA.
     */
    case dummy
    /**
     * `RootType` is the default type of the root node.
     * It is used when the type of the root node is not specified.
     */
    case root
    /**
     * `TextType` is the default type of the text node.
     * It is used when the type of the text node is not specified.
     */
    case text
}

/**
 * `addSizeOfLeftSiblings` returns the size of left siblings of the given offset.
 */
func addSizeOfLeftSiblings<T: IndexTreeNode>(parent: T, offset: Int) -> Int {
    var acc = 0

    for index in 0 ..< offset {
        let leftSibling = parent.children[index]
        acc += leftSibling.paddedSize
    }

    return acc
}

/**
 * `ElementPaddingSize` is the size of an element node as a child of another element node.
 * Because an element node could be considered as a pair of open and close tags.
 */
private let elementPaddingSize = 2

protocol IndexTreeNode: AnyObject {
    // For IndexTree
    var size: Int { get set }
    var children: [Self] { get }
    var paddedSize: Int { get }
    var isText: Bool { get }
    var parent: Self? { get set }
    var hasTextChild: Bool { get }
    var nextSibling: Self? { get }

    func findOffset(node: Self) throws -> Int?
    @discardableResult
    func split(_ soffset: Int32) throws -> Self?

    // For extension
    var isRemoved: Bool { get }
    var type: TreeNodeType { get }
    var value: String { get set }
    var innerChildren: [Self] { get set }

    func clone(offset: Int32) -> Self
}

extension IndexTreeNode {
    /**
     * `updateAncestorsSize` updates the size of the ancestors.
     */
    func updateAncestorsSize() {
        var parent = self.parent
        let sign = self.isRemoved ? -1 : 1

        while parent != nil {
            parent?.size += self.paddedSize * sign
            parent = parent?.parent
        }
    }

    /**
     * `isText` returns true if the node is a text node.
     */
    var isText: Bool {
        // TODO(hackerwins): We need to get the type of text node from user.
        // Consider the use schema to get the type of text node.
        self.type == DefaultTreeNodeType.text.rawValue
    }

    /**
     * `paddedSize` returns the size of the node including padding size.
     */
    var paddedSize: Int {
        self.size + (self.isText ? 0 : elementPaddingSize)
    }

    /**
     * `isAncenstorOf` returns true if the node is an ancestor of the given node.
     */
    func isAncestorOf(node: Self) -> Bool {
        ancestorOf(ancestor: self, node: node)
    }

    /**
     * `nextSibling` returns the next sibling of the node.
     */
    var nextSibling: Self? {
        guard let parent else {
            return nil
        }

        guard let offset = try? parent.findOffset(node: self) else {
            return nil
        }

        return parent.children[safe: offset + 1]
    }

    /**
     * `split` splits the node at the given offset.
     */
    @discardableResult
    func split(_ offset: Int32) throws -> Self? {
        if self.isText {
            return try self.splitText(offset: offset)
        }

        return try self.splitElement(offset: offset)
    }

    /**
     * `splitText` splits the given node at the given offset.
     */
    func splitText(offset: Int32) throws -> Self? {
        guard offset > 0, offset < self.size else {
            return nil
        }

        let leftValue = String(self.value.substring(from: 0, to: Int(offset) - 1))
        let rightValue = String(self.value.substring(from: Int(offset), to: self.value.count - 1))

        self.value = leftValue

        let rightNode = self.clone(offset: offset)
        rightNode.value = rightValue
        try self.parent?.insertAfterInternal(newNode: rightNode, referenceNode: self)

        return rightNode
    }

    /**
     * `children` returns the children of the node.
     */
    var children: [Self] {
        // Tombstone nodes remain awhile in the tree during editing.
        // They will be removed after the editing is done.
        // So, we need to filter out the tombstone nodes to get the real children.
        self.innerChildren.filter { !$0.isRemoved }
    }

    /**
     * `hasTextChild` returns true if the node has an text child.
     */
    var hasTextChild: Bool {
        self.children.first { $0.isText } != nil
    }

    /**
     * `append` appends the given nodes to the children.
     */
    func append(contentsOf newNode: [Self]) throws {
        guard self.isText == false else {
            throw YorkieError.unexpected(message: "Text node cannot have children")
        }

        self.innerChildren.append(contentsOf: newNode)

        newNode.forEach { node in
            node.parent = self
            node.updateAncestorsSize()
        }
    }

    /**
     * `prepend` prepends the given nodes to the children.
     */
    func prepend(contentsOf newNode: [Self]) throws {
        guard self.isText == false else {
            throw YorkieError.unexpected(message: "Text node cannot have children")
        }

        self.innerChildren.insert(contentsOf: newNode, at: 0)

        newNode.forEach { node in
            node.parent = self
            node.updateAncestorsSize()
        }
    }

    /**
     * `insertBefore` inserts the given node before the given child.
     */
    func insertBefore(newNode: Self, referenceNode: Self) throws {
        guard self.isText == false else {
            throw YorkieError.unexpected(message: "Text node cannot have children")
        }

        guard let offset = self.innerChildren.firstIndex(where: { $0 === referenceNode }) else {
            throw YorkieError.unexpected(message: "child not found")
        }

        try self.insertAtInternal(newNode: newNode, offset: offset)
        newNode.updateAncestorsSize()
    }

    /**
     * `insertAfter` inserts the given node after the given child.
     */
    func insertAfter(newNode: Self, referenceNode: Self) throws {
        guard self.isText == false else {
            throw YorkieError.unexpected(message: "Text node cannot have children")
        }

        guard let offset = self.innerChildren.firstIndex(where: { $0 === referenceNode }) else {
            throw YorkieError.unexpected(message: "child not found")
        }

        try self.insertAtInternal(newNode: newNode, offset: offset + 1)
        newNode.updateAncestorsSize()
    }

    /**
     * `insertAt` inserts the given node at the given offset.
     */
    func insertAt(newNode: Self, offset: Int) throws {
        guard self.isText == false else {
            throw YorkieError.unexpected(message: "Text node cannot have children")
        }

        try self.insertAtInternal(newNode: newNode, offset: offset)
        newNode.updateAncestorsSize()
    }

    /**
     * `removeChild` removes the given child.
     */
    func removeChild(child: Self) throws {
        guard self.isText == false else {
            throw YorkieError.unexpected(message: "Text node cannot have children")
        }

        guard let offset = self.innerChildren.firstIndex(where: { $0 === child }) else {
            throw YorkieError.unexpected(message: "child not found")
        }

        self.innerChildren.splice(offset, 1, with: [])
        child.parent = nil
    }

    /**
     * `splitElement` splits the given element at the given offset.
     */
    func splitElement(offset: Int32) throws -> Self? {
        let clone = self.clone(offset: offset)
        try self.parent?.insertAfterInternal(newNode: clone, referenceNode: self)
        clone.updateAncestorsSize()

        let leftChildren = Array(self.children[0 ..< Int(offset)])
        let rightChildren = Array(self.children[Int(offset)...])
        self.innerChildren = leftChildren
        clone.innerChildren = rightChildren
        self.size = self.innerChildren.reduce(0) { acc, child in
            acc + child.paddedSize
        }

        clone.size = clone.innerChildren.reduce(0) { acc, child in
            acc + child.paddedSize
        }
        clone.innerChildren.forEach {
            $0.parent = clone
        }

        return clone
    }

    /**
     * `insertAfterInternal` inserts the given node after the given child.
     * This method does not update the size of the ancestors.
     */
    func insertAfterInternal(newNode: Self?, referenceNode: Self) throws {
        guard newNode != nil else {
            return
        }

        guard self.isText == false else {
            throw YorkieError.unexpected(message: "Text node cannot have children")
        }

        guard let offset = self.innerChildren.firstIndex(where: { $0 === referenceNode }) else {
            throw YorkieError.unexpected(message: "child not found")
        }

        try self.insertAtInternal(newNode: newNode!, offset: offset + 1)
    }

    /**
     * `insertAtInternal` inserts the given node at the given index.
     * This method does not update the size of the ancestors.
     */
    func insertAtInternal(newNode: Self, offset: Int) throws {
        guard self.isText == false else {
            throw YorkieError.unexpected(message: "Text node cannot have children")
        }

        self.innerChildren.splice(offset, 0, with: [newNode])
        newNode.parent = self
    }

    /**
     * findOffset returns the offset of the given node in the children.
     * It excludes the removed nodes.
     */
    func findOffset(node: Self) throws -> Int? {
        guard self.isText == false else {
            throw YorkieError.unexpected(message: "Text node cannot have children")
        }

        return self.children.firstIndex { $0 === node }
    }

    /**
     * `findBranchOffset` returns offset of the given descendant node in this node.
     * If the given node is not a descendant of this node, it returns -1.
     */
    func findBranchOffset(node: Self) throws -> Int {
        guard self.isText == false else {
            throw YorkieError.unexpected(message: "Text node cannot have children")
        }

        var current: Self? = node
        while current != nil {
            if let offset = self.innerChildren.firstIndex(where: { $0 === current }) {
                return offset
            }

            current = current?.parent
        }

        return -1
    }
}

extension Array {
    mutating func splice<C>(_ start: Int, _ deleteCount: Int, with newElements: C) where C: Collection, Self.Element == C.Element {
        let actualStart = Swift.max(Swift.min(start, self.count), 0)
        let actualDeleteCount = Swift.max(Swift.min(deleteCount, self.count - actualStart), 0)

        self.removeSubrange(actualStart ..< actualStart + actualDeleteCount)
        self.insert(contentsOf: newElements, at: actualStart)
    }
}

/**
 * `TreePos` is the position of a node in the tree.
 *
 * `offset` is the position of node's token. For example, if the node is an
 * element node, the offset is the index of the child node. If the node is a
 * text node, the offset is the index of the character.
 */
struct TreePos<T: IndexTreeNode> {
    let node: T
    let offset: Int32
}

/**
 * `ancestorOf` returns true if the given node is an ancestor of the other node.
 */
func ancestorOf<T: IndexTreeNode>(ancestor: T, node: T) -> Bool {
    if ancestor === node {
        return false
    }

    var node: T? = node
    while node?.parent != nil {
        if node?.parent === ancestor {
            return true
        }
        node = node?.parent
    }
    return false
}

/**
 * `nodesBetween` iterates the nodes between the given range.
 * If the given range is collapsed, the callback is not called.
 * It traverses the tree with postorder traversal.
 */
func nodesBetween<T: IndexTreeNode>(root: T,
                                    from: Int,
                                    to: Int,
                                    callback: @escaping (T) -> Void) throws
{
    if from > to {
        throw YorkieError.unexpected(message: "from is greater than to: \(from) > \(to)")
    }

    if from > root.size {
        throw YorkieError.unexpected(message: "from is out of range: \(from) > \(root.size)")
    }

    if to > root.size {
        throw YorkieError.unexpected(message: "to is out of range: \(to) > \(root.size)")
    }

    if from == to {
        return
    }

    var pos = 0
    try root.children.forEach { child in
        // If the child is an element node, the size of the child.
        if from - child.paddedSize < pos, pos < to {
            // If the child is an element node, the range of the child
            // is from - 1 to to - 1. Because the range of the element node is from
            // the open tag to the close tag.
            let fromChild = child.isText ? from - pos : from - pos - 1
            let toChild = child.isText ? to - pos : to - pos - 1
            try nodesBetween(
                root: child,
                from: max(0, fromChild),
                to: min(toChild, child.size),
                callback: callback
            )

            // If the range spans outside the child,
            // the callback is called with the child.
            if fromChild < 0 || toChild > child.size || child.isText {
                callback(child)
            }
        }
        pos += child.paddedSize
    }
}

/**
 * `traverse` traverses the tree with postorder traversal.
 */
func traverse<T: IndexTreeNode>(node: T,
                                callback: @escaping (T, Int32) -> Void,
                                depth: Int32 = 0)
{
    node.children.forEach { child in
        traverse(node: child, callback: callback, depth: depth + 1)
    }
    callback(node, depth)
}

/**
 * `traverseAll` traverses the whole tree (include tombstones) with postorder traversal.
 */
func traverseAll<T: IndexTreeNode>(node: T, depth: Int32 = 0, callback: @escaping (T, Int32) -> Void) {
    node.innerChildren.forEach { child in
        traverseAll(node: child, depth: depth + 1, callback: callback)
    }

    callback(node, depth)
}

/**
 * `findTreePos` finds the position of the given index in the given node.
 */
func findTreePos<T: IndexTreeNode>(node: T,
                                   index: Int,
                                   preferText: Bool = true) throws -> TreePos<T>
{
    if index > node.size {
        throw YorkieError.unexpected(message: "index is out of range: \(index) > \(node.size)")
    }

    if node.isText {
        return TreePos(node: node, offset: Int32(index))
    }

    // offset is the index of the child node.
    // pos is the window of the index in the given node.
    var offset = 0
    var pos = 0
    for child in node.children {
        // The pos is in bothsides of the text node, we should traverse
        // inside of the text node if preferText is true.
        if preferText, child.isText, child.size >= index - pos {
            return try findTreePos(node: child, index: index - pos, preferText: preferText)
        }

        // The position is in leftside of the element node.
        if index == pos {
            return TreePos(node: node, offset: Int32(offset))
        }

        // The position is in rightside of the element node and preferText is false.
        if !preferText, child.paddedSize == index - pos {
            return TreePos(node: node, offset: Int32(offset + 1))
        }

        // The position is in middle the element node.
        if child.paddedSize > index - pos {
            // If we traverse inside of the element node, we should skip the open.
            let skipOpenSize = 1
            return try findTreePos(node: child, index: index - pos - skipOpenSize, preferText: preferText)
        }

        pos += child.paddedSize
        offset += 1
    }

    // The position is in rightmost of the given node.
    return TreePos(node: node, offset: Int32(offset))
}

/**
 * `getAncestors` returns the ancestors of the given node.
 */
func getAncestors<T: IndexTreeNode>(node: T) -> [T] {
    var ancestors = [T]()
    var parent = node.parent
    while parent != nil {
        ancestors.insert(parent!, at: 0)
        parent = parent?.parent
    }
    return ancestors
}

/**
 * `findCommonAncestor` finds the lowest common ancestor of the given nodes.
 */
func findCommonAncestor<T: IndexTreeNode>(nodeA: T, nodeB: T) -> T? {
    if nodeA === nodeB {
        return nodeA
    }

    let ancestorsOfA = getAncestors(node: nodeA)
    let ancestorsOfB = getAncestors(node: nodeB)

    var commonAncestor: T?
    for index in 0 ..< ancestorsOfA.count {
        let ancestorOfA = ancestorsOfA[index]
        let ancestorOfB = ancestorsOfB[index]

        if ancestorOfA !== ancestorOfB {
            break
        }

        commonAncestor = ancestorOfA
    }

    return commonAncestor
}

/**
 * `findLeftmost` finds the leftmost node of the given tree.
 */
func findLeftmost<T: IndexTreeNode>(node: T) -> T {
    if node.isText || node.children.isEmpty {
        return node
    }

    return findLeftmost(node: node.children[0])
}

/**
 * `findTextPos` returns the tree position of the given path element.
 */
func findTextPos<T: IndexTreeNode>(node: T, pathElement: Int) throws -> TreePos<T> {
    var node = node
    var pathElement = pathElement

    if node.size < pathElement {
        throw YorkieError.unexpected(message: "unacceptable path")
    }

    for index in 0 ..< node.children.count {
        let child = node.children[index]

        if child.size < pathElement {
            pathElement -= child.size
        } else {
            node = child

            break
        }
    }

    return TreePos(node: node, offset: Int32(pathElement))
}

/**
 * `IndexTree` is a tree structure for linear indexing.
 */
class IndexTree<T: IndexTreeNode> {
    let root: T

    init(root: T) {
        self.root = root
    }

    /**
     * `nodeBetween` returns the nodes between the given range.
     */
    func nodesBetween(_ from: Int, _ to: Int, _ callback: @escaping (T) -> Void) throws {
        try Yorkie.nodesBetween(root: self.root, from: from, to: to, callback: callback)
    }

    /**
     * `traverse` traverses the tree with postorder traversal.
     */
    func traverse(callback: @escaping (T, Int32) -> Void) {
        Yorkie.traverse(node: self.root, callback: callback, depth: 0)
    }

    /**
     * `traverseAll` traverses the whole tree (include tombstones) with postorder traversal.
     */
    func traverseAll(callback: @escaping (T, Int32) -> Void) {
        Yorkie.traverseAll(node: self.root, depth: 0, callback: callback)
    }

    /**
     * `split` splits the node at the given index.
     */
    public func split(_ index: Int, _ depth: Int = 1) throws -> TreePos<T> {
        let treePos = try Yorkie.findTreePos(node: self.root, index: index, preferText: true)

        var node: T? = treePos.node
        var offset = treePos.offset
        for _ in 0 ..< depth {
            guard node != nil, node !== self.root else {
                break
            }
            try node!.split(offset)

            guard let nextOffset = try node!.parent?.findOffset(node: node!) else {
                throw YorkieError.unexpected(message: "cant find offset")
            }
            offset = Int32(offset == 0 ? nextOffset : nextOffset + 1)
            node = node?.parent
        }

        return treePos
    }

    /**
     * findTreePos finds the position of the given index in the tree.
     */
    public func findTreePos(_ index: Int, _ preferText: Bool = true) throws -> TreePos<T> {
        try Yorkie.findTreePos(node: self.root, index: index, preferText: preferText)
    }

    /**
     * `treePosToPath` returns path from given treePos
     */
    public func treePosToPath(_ treePos: TreePos<T>) throws -> [Int] {
        var path = [Int]()
        var node = treePos.node

        if node.isText {
            guard let offset = try node.parent!.findOffset(node: node) else {
                throw YorkieError.unexpected(message: "invalid treePos")
            }

            let sizeOfLeftSiblings = addSizeOfLeftSiblings(parent: node.parent!, offset: offset)
            node = node.parent!
            path.append(sizeOfLeftSiblings + Int(treePos.offset))
        } else {
            path.append(Int(treePos.offset))
        }

        while node.parent != nil {
            guard let offset = try node.parent?.findOffset(node: node) else {
                throw YorkieError.unexpected(message: "invalid treePos")
            }

            path.append(offset)
            node = node.parent!
        }

        return path.reversed()
    }

    /**
     * `pathToIndex` returns index from given path
     */
    public func pathToIndex(_ path: [Int]) throws -> Int {
        let treePos = try self.pathToTreePos(path)

        return try self.indexOf(treePos)
    }

    /**
     * `pathToTreePos` returns treePos from given path
     */
    public func pathToTreePos(_ path: [Int]) throws -> TreePos<T> {
        guard path.isEmpty != true else {
            throw YorkieError.unexpected(message: "unacceptable path")
        }

        var node = self.root
        for index in 0 ..< path.count - 1 {
            let pathElement = path[index]

            if node.children[safe: pathElement] == nil {
                throw YorkieError.unexpected(message: "unacceptable path")
            }

            node = node.children[pathElement]
        }

        if node.hasTextChild {
            return try findTextPos(node: node, pathElement: path[path.count - 1])
        }

        if node.children.count < path[path.count - 1] {
            throw YorkieError.unexpected(message: "unacceptable path")
        }

        return TreePos(node: node, offset: Int32(path[path.count - 1]))
    }

    /**
     * `size` returns the size of the tree.
     */
    var size: Int {
        self.root.size
    }

    /**
     * `findPostorderRight` finds right node of the given tree position with
     *  postorder traversal.
     */
    public func findPostorderRight(_ treePos: TreePos<T>) -> T {
        let node = treePos.node
        let offset = Int(treePos.offset)

        if node.isText {
            if node.size == offset {
                if let nextSibling = node.nextSibling {
                    return nextSibling
                }

                return node.parent!
            }

            return node
        }

        if node.children.count == offset {
            return node
        }

        return findLeftmost(node: node.children[offset])
    }

    /**
     * `indexOf` returns the index of the given tree position.
     */
    public func indexOf(_ pos: TreePos<T>) throws -> Int {
        var node = pos.node
        let offset = Int(pos.offset)

        var size = 0
        var depth = 1
        if node.isText {
            size += offset

            let parent = node.parent!
            guard let offsetOfNode = try parent.findOffset(node: node) else {
                throw YorkieError.unexpected(message: "invalid pos")
            }

            size += addSizeOfLeftSiblings(parent: parent, offset: offsetOfNode)

            node = node.parent!
        } else {
            size += addSizeOfLeftSiblings(parent: node, offset: offset)
        }

        while node.parent != nil {
            let parent = node.parent!
            guard let offsetOfNode = try parent.findOffset(node: node) else {
                throw YorkieError.unexpected(message: "invalid pos")
            }

            size += addSizeOfLeftSiblings(parent: parent, offset: offsetOfNode)
            depth += 1
            node = node.parent!
        }

        return size + depth - 1
    }

    /**
     * `indexToPath` returns the path of the given index.
     */
    public func indexToPath(_ index: Int) throws -> [Int] {
        let treePos = try self.findTreePos(index)
        return try self.treePosToPath(treePos)
    }
}