import Foundation

/// Read-only links from a canonical workout to its retained source records.
/// Building the index once keeps traversals linear in the relevant links.
nonisolated struct WorkoutLinkGraph {
    nonisolated struct Link: Sendable {
        let id: String
        let parentID: String?
    }

    private let children: [String: [String]]

    init(_ links: [Link]) {
        var children: [String: [String]] = [:]
        for link in links {
            guard let parent = link.parentID else { continue }
            children[parent, default: []].append(link.id)
        }
        self.children = children
    }

    /// The original records remain their owners. A changed link naturally
    /// removes a former alias from this view; cycles cannot loop indefinitely.
    func relatedIDs(to canonicalID: String) -> Set<String> {
        var result: Set<String> = [canonicalID]
        var pending = [canonicalID]
        while let id = pending.popLast() {
            for child in children[id] ?? [] where result.insert(child).inserted {
                pending.append(child)
            }
        }
        return result
    }
}
