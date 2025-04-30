// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors


public struct FXSortedSet<Element: Comparable & Hashable & Sendable>: Sendable {
    fileprivate var uniqueElements: Set<Element>
    fileprivate var sortedElements: [Element]

    public init() {
        uniqueElements = Set()
        sortedElements = Array()
    }

    public init(_ elements: [Element]) {
        uniqueElements = Set(elements)
        sortedElements = uniqueElements.sorted()
    }

    public init(_ elements: Set<Element>) {
        uniqueElements = elements
        sortedElements = uniqueElements.sorted()
    }

    public var isEmpty: Bool {
        uniqueElements.isEmpty
    }
}

extension FXSortedSet: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sortedElements == rhs.sortedElements
    }
}

extension FXSortedSet: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(uniqueElements)
    }
}

extension FXSortedSet: Collection {
    public typealias Index = Array<Element>.Index

    public var startIndex: Index {
        sortedElements.startIndex
    }

    public var endIndex: Index {
        sortedElements.endIndex
    }

    public subscript(position: Index) -> Element {
        get {
            sortedElements[position]
        }
    }

    public func index(after i: Index) -> Index {
        sortedElements.index(after: i)
    }
}

extension FXSortedSet: BidirectionalCollection {
    public func index(before i: Index) -> Index {
        sortedElements.index(before: i)
    }
}

extension FXSortedSet: Sequence {
    public typealias Iterator = Array<Element>.Iterator

    public func makeIterator() -> Iterator {
        sortedElements.makeIterator()
    }
}

extension FXSortedSet: SetAlgebra {
    public func contains(_ member: Element) -> Bool {
        uniqueElements.contains(member)
    }

    public func union(_ other: Self) -> Self {
        Self(uniqueElements.union(other.uniqueElements))
    }

    public func intersection(_ other: Self) -> Self {
        Self(uniqueElements.intersection(other.uniqueElements))
    }

    public func symmetricDifference(_ other: Self) -> Self {
        Self(uniqueElements.symmetricDifference(other.uniqueElements))
    }

    @discardableResult
    public mutating func insert(
        _ newMember: Element
    ) -> (inserted: Bool, memberAfterInsert: Element) {
        defer { sortedElements = uniqueElements.sorted() }
        return uniqueElements.insert(newMember)
    }

    @discardableResult
    public mutating func remove(_ member: Element) -> Element? {
        defer { sortedElements = uniqueElements.sorted() }
        return uniqueElements.remove(member)
    }

    @discardableResult
    public mutating func update(with newMember: Element) -> Element? {
        defer { sortedElements = uniqueElements.sorted() }
        return uniqueElements.update(with: newMember)
    }

    public mutating func formUnion(_ other: Self) {
        uniqueElements.formUnion(other.uniqueElements)
        sortedElements = uniqueElements.sorted()
    }

    public mutating func formIntersection(_ other: Self) {
        uniqueElements.formIntersection(other.uniqueElements)
        sortedElements = uniqueElements.sorted()
    }

    public mutating func formSymmetricDifference(_ other: Self) {
        uniqueElements.formSymmetricDifference(other.uniqueElements)
        sortedElements = uniqueElements.sorted()
    }
}

extension FXSortedSet: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Element...) {
        self = Self(elements)
    }
}

extension FXSortedSet: Encodable where Element: Encodable {
    public func encode(to encoder: Encoder) throws {
        try sortedElements.encode(to: encoder)
    }
}

extension FXSortedSet: Decodable where Element: Decodable {
    public init(from decoder: Decoder) throws {
        let elements: [Element] = try .init(from: decoder)

        self = Self(elements)
    }
}
