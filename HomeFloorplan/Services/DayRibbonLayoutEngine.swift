import Foundation
import CoreGraphics
import SwiftUI

/// Motore di calcolo spaziale per la disposizione temporale sul DayRibbon.
/// Contiene funzioni pure per disporre momenti, gesti e durate senza accavallamenti visivi.
enum DayRibbonLayoutEngine {

    // MARK: Momenti sull'asse (Axis)

    struct AxisPlacement: Equatable {
        let moment: DayMoment
        /// Quanti momenti stanno sotto questo punto. Uno significa sé stesso.
        let count: Int
        let x: CGFloat
        let level: Int
        /// `nil` quando il nome non si mostra: o non c'è spazio, o quel momento
        /// è lontano dall'ora presente.
        let labelWidth: CGFloat?
    }

    static let clusterSeparation: CGFloat = 15
    static let labelledPast = 2
    static let labelledFuture = 3
    static let maxLabelWidth: CGFloat = 130
    static let minLabelWidth: CGFloat = 40

    static func axisLayout(_ moments: [DayMoment],
                           now: Date,
                           width: CGFloat,
                           fraction: (Date) -> CGFloat) -> [AxisPlacement] {
        let sorted = moments.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
        guard !sorted.isEmpty else { return [] }

        // 1. Grappoli: chi cade troppo vicino al precedente ci finisce dentro.
        var clusters: [(moment: DayMoment, count: Int, x: CGFloat)] = []
        for moment in sorted {
            let x = fraction(moment.at) * width
            if let last = clusters.last, x - last.x < clusterSeparation {
                clusters[clusters.count - 1].count += 1
            } else {
                clusters.append((moment, 1, x))
            }
        }

        // 2. Quali nominare: una finestra attorno ad adesso.
        let boundary = clusters.firstIndex { $0.moment.at > now } ?? clusters.count
        let from = max(0, boundary - labelledPast)
        let to = min(clusters.count, boundary + labelledFuture)
        let labelled = Array(from..<to)

        // 3. Le etichette dei soli nominati si spartiscono due righe sfalsate,
        //    con la larghezza che arriva fino al vicino sulla stessa riga.
        var lastXOnRow = [CGFloat](repeating: -.greatestFiniteMagnitude, count: 2)
        var rowOf: [Int: Int] = [:]
        for index in labelled {
            let x = clusters[index].x
            for row in 0..<2 where x - lastXOnRow[row] >= minLabelWidth + 6 {
                rowOf[index] = row
                lastXOnRow[row] = x
                break
            }
        }

        return clusters.enumerated().map { index, cluster in
            guard let row = rowOf[index] else {
                return AxisPlacement(moment: cluster.moment, count: cluster.count,
                                     x: cluster.x, level: 0, labelWidth: nil)
            }
            let nextX = labelled.first { $0 > index && rowOf[$0] == row }
                .map { clusters[$0].x } ?? width
            let available = min(maxLabelWidth, nextX - cluster.x - 6)
            return AxisPlacement(moment: cluster.moment, count: cluster.count,
                                 x: cluster.x, level: row,
                                 labelWidth: available >= minLabelWidth ? available : nil)
        }
    }

    // MARK: Durate (Spans)
    
    static let spanLanes = 3

    struct SpanPlacement: Equatable {
        let span: DaySpan
        let lane: Int
    }

    static func assignLanes(_ spans: [DaySpan], now: Date) -> [SpanPlacement] {
        var laneEnds = [Date](repeating: .distantPast, count: spanLanes)
        var placements: [SpanPlacement] = []

        for span in spans.sorted(by: DaySpanBuilder.precedes) {
            let end = span.end ?? now
            guard let lane = (0..<spanLanes).first(where: { laneEnds[$0] <= span.start }) else { continue }
            laneEnds[lane] = end
            placements.append(SpanPlacement(span: span, lane: lane))
        }
        return placements
    }

    // MARK: Gesti (Gestures)

    struct GesturePlacement {
        let gesture: HumanGesture
        let x: CGFloat
    }

    static func lane(_ gestures: [HumanGesture],
                     width: CGFloat,
                     fraction: (Date) -> CGFloat,
                     minSpacing: CGFloat = 26) -> [GesturePlacement] {
        let sorted = gestures.sorted { $0.at < $1.at }
        guard !sorted.isEmpty else { return [] }

        var groups: [[HumanGesture]] = []
        var currentX: CGFloat = -.greatestFiniteMagnitude

        for gesture in sorted {
            let x = fraction(gesture.at) * width
            if x - currentX < minSpacing, !groups.isEmpty {
                groups[groups.count - 1].append(gesture)
            } else {
                groups.append([gesture])
                currentX = x
            }
        }

        return groups.map { group in
            let merged = group.count == 1 ? group[0] : HumanGestureBuilder.merge(group)
            return GesturePlacement(gesture: merged, x: fraction(merged.at) * width)
        }
    }

    // MARK: Disposizione delle etichette (Generic Layout)

    struct Placement {
        let moment: DayMoment
        let x: CGFloat
        let level: Int
        let labelWidth: CGFloat?
    }

    static func layout(_ moments: [DayMoment],
                       width: CGFloat,
                       fraction: (Date) -> CGFloat) -> [Placement] {
        let sorted = moments.sorted { $0.at < $1.at }
        let xs = sorted.map { fraction($0.at) * width }

        var lastXOnRow = [CGFloat](repeating: -.greatestFiniteMagnitude, count: 2)
        var rowOf = [Int?](repeating: nil, count: sorted.count)

        for (index, x) in xs.enumerated() {
            for row in 0..<2 where x - lastXOnRow[row] >= minLabelWidth + 6 {
                rowOf[index] = row
                lastXOnRow[row] = x
                break
            }
        }

        return sorted.enumerated().map { index, moment in
            guard let row = rowOf[index] else {
                return Placement(moment: moment, x: xs[index], level: 0, labelWidth: nil)
            }
            let nextX = xs.indices.dropFirst(index + 1)
                .first { rowOf[$0] == row }
                .map { xs[$0] } ?? width
            let available = min(maxLabelWidth, nextX - xs[index] - 6)
            return Placement(moment: moment,
                             x: xs[index],
                             level: row,
                             labelWidth: available >= minLabelWidth ? available : nil)
        }
    }
}
