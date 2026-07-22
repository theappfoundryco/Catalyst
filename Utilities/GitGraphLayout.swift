import Foundation

/// A positioned commit in the graph: its row (vertical order) and lane (column).
///
/// ```swift
/// let node = GraphNode(commit: commit, row: 0, lane: 1)
/// ```
struct GraphNode: Sendable, Identifiable, Equatable {
    let commit: GraphCommit
    let row: Int
    let lane: Int
    var id: String { commit.hash }
}

/// A parent link between two commits, in lane/row coordinates, colored by the lane the
/// parent occupies (so a branch keeps one color as it descends).
///
/// ```swift
/// let edge = GraphEdge(fromRow: 0, fromLane: 1, toRow: 1, toLane: 1, colorIndex: 1)
/// ```
struct GraphEdge: Sendable, Equatable, Identifiable {
    let fromRow: Int
    let fromLane: Int
    let toRow: Int
    let toLane: Int
    let colorIndex: Int
    var id: String { "\(fromRow)-\(fromLane)->\(toRow)-\(toLane)" }
}

/// A single lane line passing through one row's gutter, in lane coordinates.
///
/// Rendering per-row (instead of one giant canvas) keeps the graph fully lazy: each
/// commits only its own short segments, so a 1,000-commit history never builds
/// a 40,000-pt canvas layer (the previous scroll-jank source). The line jogs to its
/// target lane within the child's row, then runs straight down — a clean, readable style.
///
/// ```swift
/// let segment = RowSegment(topLane: 1, bottomLane: 1, colorIndex: 1, startsAtNode: true, endsAtNode: false)
/// ```
struct RowSegment: Sendable, Equatable {
    /// Lane at the top edge of the row (the child node's lane on its own row).
    let topLane: Int
    /// Lane at the bottom edge of the row (the lane the line settles into).
    let bottomLane: Int
    let colorIndex: Int
    /// The line begins at this row's node center (this is the child's row).
    let startsAtNode: Bool
    /// The line ends at this row's node center (this is the parent's row).
    let endsAtNode: Bool
}

/// The fully-resolved graph: nodes, per-row line segments, and the lane (column) count.
///
/// ```swift
/// let layout = GitGraphLayoutEngine.layout(commits)
/// ```
struct GitGraphLayout: Sendable, Equatable {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
    /// One entry per row (aligned with `nodes` by index): the lane lines to draw there.
    let rowSegments: [[RowSegment]]
    let laneCount: Int

    static let empty = GitGraphLayout(nodes: [], edges: [], rowSegments: [], laneCount: 0)
    var isEmpty: Bool { nodes.isEmpty }
}

/// Pure, `Sendable`, deterministic lane-assignment for a commit list.
///
/// Input commits must be newest-first in `--date-order` (children before parents). The
/// engine walks them top→bottom, keeping a set of **active lanes** — each lane reserved
/// for the next commit expected in it. A commit takes the lane reserved for it (or a
/// free one), then reserves lanes for its parents: the first parent continues the
/// commit's own lane; extra parents (a merge) take fresh lanes. Freed lanes are reused,
/// so the graph stays compact. No UI, no I/O — trivially unit-testable
/// (`CODING_STANDARDS.md` 1.3 / §43).
///
/// ```swift
/// let layout = GitGraphLayoutEngine.layout(commits)
/// ```
enum GitGraphLayoutEngine {
    /// Transforms a linear array of commits into a two-dimensional grid of topological lanes.
    /// - Parameter commits: A chronologically sorted subset of parsed git log histories.
    /// - Returns: A spatial rendering layout object for the topological graph.
    static func layout(_ commits: [GraphCommit]) -> GitGraphLayout {
        guard !commits.isEmpty else { return .empty }

        /// Row + membership lookups.
        ///
        /// **Rationale:** Pre-computing row indices avoids O(N) linear scans through the commit array during the graph rendering pass.
        var rowOf = [String: Int](minimumCapacity: commits.count)
        for (row, c) in commits.enumerated() { rowOf[c.hash] = row }

        var laneOf = [String: Int](minimumCapacity: commits.count)
        var active: [String?] = []       // lane -> hash it is currently reserved for
        var maxLaneIndex = 0

        /// Determines the lowest available horizontal lane index for a new branch trace.
        /// - Returns: The lowest available integer offset denoting an empty rendering lane.
        func firstFreeLane() -> Int {
            if let i = active.firstIndex(where: { $0 == nil }) { return i }
            active.append(nil)
            return active.count - 1
        }

        for (_, commit) in commits.enumerated() {
            /// The commit's lane: one already reserved for it, else a free lane.
            ///
            /// **Rationale:** Reusing lanes from parent reservations keeps the branch line straight rather than stair-stepping horizontally down the graph.
            let myLane: Int
            if let reserved = active.firstIndex(where: { $0 == commit.hash }) {
                myLane = reserved
            } else {
                myLane = firstFreeLane()
            }
            active[myLane] = nil                 // free it; the first parent may re-take it
            laneOf[commit.hash] = myLane
            maxLaneIndex = max(maxLaneIndex, myLane)

            /// Reserve lanes for parents that are within the loaded window.
            ///
            /// **Gotchas:** Attempting to reserve lanes for commits outside the pagination window will leak lanes globally, crushing the graph into a narrow sliver.
            for (i, parent) in commit.parents.enumerated() where rowOf[parent] != nil {
                if active.contains(where: { $0 == parent }) { continue } // already on a lane
                if i == 0 && active[myLane] == nil {
                    active[myLane] = parent       // first parent continues this lane
                } else {
                    let free = firstFreeLane()
                    active[free] = parent          // merge parent branches off
                    maxLaneIndex = max(maxLaneIndex, free)
                }
            }
        }

        let nodes = commits.enumerated().map { row, c in
            GraphNode(commit: c, row: row, lane: laneOf[c.hash] ?? 0)
        }

        var edges: [GraphEdge] = []
        var rowSegments = Array(repeating: [RowSegment](), count: commits.count)
        for (row, c) in commits.enumerated() {
            let fromLane = laneOf[c.hash] ?? 0
            for parent in c.parents {
                guard let pRow = rowOf[parent], let pLane = laneOf[parent] else { continue }
                edges.append(GraphEdge(fromRow: row, fromLane: fromLane,
                                       toRow: pRow, toLane: pLane, colorIndex: pLane))

                /// Split the edge into one segment per row it spans (row < pRow always,
                /// since a parent is older and therefore lower in the list).
                ///
                /// **Rationale:** SwiftUI's `Canvas` must draw the graph row-by-row; splitting the edge allows each row to draw only the segment of the line that crosses its bounds.
                guard row < pRow else { continue }
                for r in row...pRow {
                    let starts = (r == row)
                    let ends = (r == pRow)
                    rowSegments[r].append(RowSegment(
                        topLane: starts ? fromLane : pLane,
                        bottomLane: pLane,
                        colorIndex: pLane,
                        startsAtNode: starts,
                        endsAtNode: ends
                    ))
                }
            }
        }

        return GitGraphLayout(nodes: nodes, edges: edges,
                              rowSegments: rowSegments, laneCount: maxLaneIndex + 1)
    }
}
