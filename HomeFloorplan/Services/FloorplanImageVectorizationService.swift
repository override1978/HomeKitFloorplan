import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum FloorplanImageVectorizationError: LocalizedError {
    case imageRenderingFailed
    case noWallsDetected

    var errorDescription: String? {
        switch self {
        case .imageRenderingFailed:
            return String(localized: "drawing.imageDraft.error.rendering", defaultValue: "Unable to prepare the image for local analysis.")
        case .noWallsDetected:
            return String(localized: "drawing.imageDraft.error.noWalls", defaultValue: "No reliable wall segments were detected. Try a clearer or more top-down floorplan image.")
        }
    }
}

final class FloorplanImageVectorizationService {
    static let shared = FloorplanImageVectorizationService()

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private struct PixelImage {
        let width: Int
        let height: Int
        let grayscale: [Double]
    }

    private struct CandidateSegment {
        var start: CGPoint
        var end: CGPoint
    }

    private struct AxisAlignedWallLine {
        var axis: CGFloat
        var start: CGFloat
        var end: CGFloat
        var kind: WallKind
    }

    /// Records the pixel-space position and width of a gap bridged during gap-closing.
    private struct DetectedGapOpening {
        var midpoint: CGPoint   // pixel-space midpoint of the bridged gap
        var width: Double       // pixel-space gap width
    }

    func vectorize(image: UIImage) async throws -> DrawingDocument {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let wallMaskImage = try Self.makeWallMaskImage(from: image)
                    let pixelImage = try Self.makePixelImage(from: wallMaskImage, maxSide: 900)
                    let wallPixels = Self.wallForegroundMap(from: pixelImage)
                    let w = pixelImage.width, h = pixelImage.height

                    // Primary: skeleton centerlines via Zhang-Suen → orthogonal extraction.
                    // Naturally produces single-pixel centerlines, eliminating double-wall artifacts.
                    let maskBytes = wallPixels.map { $0 ? UInt8(1) : UInt8(0) }
                    let skeleton = Self.zhangSuenThinning(maskBytes, width: w, height: h)
                    let skelCandidates = Self.extractOrthogonalFromSkeleton(skeleton, width: w, height: h)

                    let imageSize = CGSize(width: w, height: h)

                    if !skelCandidates.isEmpty {
                        // PASSO A: close wall gaps → record door/window opening positions
                        let (closedSegs, gapOpenings) = Self.closeGaps(skelCandidates, imageSize: imageSize)
                        // PASSO B: flood-fill exterior → classify perimeter vs interior
                        let preassignedKinds = Self.classifyWallKindsByFloodFill(
                            segments: closedSegs, width: w, height: h)
                        let walls = Self.makeWalls(from: closedSegs, imageSize: imageSize,
                                                   preassignedKinds: preassignedKinds)
                        guard !walls.isEmpty else {
                            continuation.resume(throwing: FloorplanImageVectorizationError.noWallsDetected)
                            return
                        }
                        let placedOpenings = Self.placeDetectedOpenings(gapOpenings, walls: walls,
                                                                         imageSize: imageSize)
                        var document = DrawingDocument()
                        document.walls = Array(walls.prefix(180))
                        document.openings = placedOpenings
                        continuation.resume(returning: document)
                    } else {
                        // Fallback: row/column mask scan, then edge scan
                        let maskCandidates = Self.detectMaskSegments(in: wallPixels, width: w, height: h)
                        let candidates = maskCandidates.isEmpty
                            ? Self.detectSegments(in: Self.edgeMap(from: pixelImage), width: w, height: h)
                            : maskCandidates
                        let walls = Self.makeWalls(from: candidates, imageSize: imageSize)
                        guard !walls.isEmpty else {
                            continuation.resume(throwing: FloorplanImageVectorizationError.noWallsDetected)
                            return
                        }
                        var document = DrawingDocument()
                        document.walls = Array(walls.prefix(180))
                        continuation.resume(returning: document)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func makeWallMaskImage(from image: UIImage) throws -> UIImage {
        guard let input = CIImage(image: image) else {
            throw FloorplanImageVectorizationError.imageRenderingFailed
        }

        let grayFilter = CIFilter.colorControls()
        grayFilter.inputImage = input
        grayFilter.saturation = 0
        grayFilter.brightness = 0
        grayFilter.contrast = 1.4
        let gray = grayFilter.outputImage ?? input

        let thresholdFilter = CIFilter.colorThreshold()
        thresholdFilter.inputImage = gray
        thresholdFilter.threshold = 0.42
        let thresholded = thresholdFilter.outputImage ?? gray

        let invertFilter = CIFilter.colorInvert()
        invertFilter.inputImage = thresholded
        let binary = invertFilter.outputImage ?? thresholded

        let shortestSide = Float(min(input.extent.width, input.extent.height))
        let wallThickness = max(5, min(20, shortestSide * 0.013))
        let opened = openWallMask(binary, wallThickness: wallThickness).cropped(to: input.extent)
        guard let cgImage = ciContext.createCGImage(opened, from: opened.extent) else {
            throw FloorplanImageVectorizationError.imageRenderingFailed
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func openWallMask(_ image: CIImage, wallThickness: Float) -> CIImage {
        let clamped = image.clampedToExtent()
        let radius = wallThickness / 2

        let erodeFilter = CIFilter.morphologyMinimum()
        erodeFilter.inputImage = clamped
        erodeFilter.radius = radius
        let eroded = erodeFilter.outputImage ?? clamped

        let dilateFilter = CIFilter.morphologyMaximum()
        dilateFilter.inputImage = eroded
        dilateFilter.radius = radius
        return dilateFilter.outputImage ?? eroded
    }

    private static func makePixelImage(from image: UIImage, maxSide: Int) throws -> PixelImage {
        let sourceSize = image.size
        let longest = max(sourceSize.width, sourceSize.height)
        let scale = longest > CGFloat(maxSide) ? CGFloat(maxSide) / longest : 1
        let width = max(1, Int((sourceSize.width * scale).rounded()))
        let height = max(1, Int((sourceSize.height * scale).rounded()))

        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw FloorplanImageVectorizationError.imageRenderingFailed }

        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        guard let cgImage = image.cgImage ?? image.renderedCGImage() else {
            throw FloorplanImageVectorizationError.imageRenderingFailed
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var grayscale = [Double](repeating: 1, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            let r = Double(bytes[offset]) / 255
            let g = Double(bytes[offset + 1]) / 255
            let b = Double(bytes[offset + 2]) / 255
            grayscale[index] = 0.299 * r + 0.587 * g + 0.114 * b
        }

        return PixelImage(width: width, height: height, grayscale: grayscale)
    }

    private static func wallForegroundMap(from image: PixelImage) -> [Bool] {
        image.grayscale.map { $0 > 0.5 }
    }

    private static func detectMaskSegments(in foreground: [Bool], width: Int, height: Int) -> [CandidateSegment] {
        var segments: [CandidateSegment] = []
        segments.append(contentsOf: detectHorizontalMaskSegments(in: foreground, width: width, height: height))
        segments.append(contentsOf: detectVerticalMaskSegments(in: foreground, width: width, height: height))
        return mergeSimilarSegments(segments)
    }

    private static func detectHorizontalMaskSegments(in foreground: [Bool], width: Int, height: Int) -> [CandidateSegment] {
        let rowThreshold = max(12, Int(Double(width) * 0.025))
        let minRun = max(20, Int(Double(width) * 0.022))
        let rows = groupedIndices((1..<(height - 1)).filter { y in
            var count = 0
            for x in 1..<(width - 1) where foreground[y * width + x] { count += 1 }
            return count >= rowThreshold
        }, maximumGap: 10)

        return rows.flatMap { group -> [CandidateSegment] in
            let y = Int(group.reduce(0, +) / max(group.count, 1))
            let columns = activeColumnsAround(rows: group, foreground: foreground, width: width, height: height)
            return runs(in: columns, minimumLength: minRun).map { run in
                CandidateSegment(start: CGPoint(x: run.lowerBound, y: y), end: CGPoint(x: run.upperBound, y: y))
            }
        }
    }

    private static func detectVerticalMaskSegments(in foreground: [Bool], width: Int, height: Int) -> [CandidateSegment] {
        let columnThreshold = max(12, Int(Double(height) * 0.025))
        let minRun = max(20, Int(Double(height) * 0.022))
        let columns = groupedIndices((1..<(width - 1)).filter { x in
            var count = 0
            for y in 1..<(height - 1) where foreground[y * width + x] { count += 1 }
            return count >= columnThreshold
        }, maximumGap: 10)

        return columns.flatMap { group -> [CandidateSegment] in
            let x = Int(group.reduce(0, +) / max(group.count, 1))
            let rows = activeRowsAround(columns: group, foreground: foreground, width: width, height: height)
            return runs(in: rows, minimumLength: minRun).map { run in
                CandidateSegment(start: CGPoint(x: x, y: run.lowerBound), end: CGPoint(x: x, y: run.upperBound))
            }
        }
    }

    private static func activeColumnsAround(rows: [Int], foreground: [Bool], width: Int, height: Int) -> [Int] {
        guard let minRow = rows.min(), let maxRow = rows.max() else { return [] }
        let yRange = max(0, minRow - 3)...min(height - 1, maxRow + 3)
        let requiredHits = max(2, Int(Double(yRange.count) * 0.28))

        return (0..<width).filter { x in
            var hits = 0
            for y in yRange where foreground[y * width + x] {
                hits += 1
                if hits >= requiredHits { return true }
            }
            return false
        }
    }

    private static func activeRowsAround(columns: [Int], foreground: [Bool], width: Int, height: Int) -> [Int] {
        guard let minColumn = columns.min(), let maxColumn = columns.max() else { return [] }
        let xRange = max(0, minColumn - 3)...min(width - 1, maxColumn + 3)
        let requiredHits = max(2, Int(Double(xRange.count) * 0.28))

        return (0..<height).filter { y in
            var hits = 0
            for x in xRange where foreground[y * width + x] {
                hits += 1
                if hits >= requiredHits { return true }
            }
            return false
        }
    }

    private static func edgeMap(from image: PixelImage) -> [Bool] {
        let width = image.width
        let height = image.height
        var magnitudes = [Double](repeating: 0, count: width * height)
        var sum: Double = 0
        var count: Double = 0

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let tl = image.grayscale[(y - 1) * width + x - 1]
                let tc = image.grayscale[(y - 1) * width + x]
                let tr = image.grayscale[(y - 1) * width + x + 1]
                let ml = image.grayscale[y * width + x - 1]
                let mr = image.grayscale[y * width + x + 1]
                let bl = image.grayscale[(y + 1) * width + x - 1]
                let bc = image.grayscale[(y + 1) * width + x]
                let br = image.grayscale[(y + 1) * width + x + 1]

                let gx = -tl - 2 * ml - bl + tr + 2 * mr + br
                let gy = -tl - 2 * tc - tr + bl + 2 * bc + br
                let magnitude = min(1, sqrt(gx * gx + gy * gy) / 4)
                magnitudes[i] = magnitude
                sum += magnitude
                count += 1
            }
        }

        let mean = count > 0 ? sum / count : 0
        let threshold = max(0.16, min(0.42, mean * 2.4))
        return magnitudes.map { $0 >= threshold }
    }

    private static func detectSegments(in edges: [Bool], width: Int, height: Int) -> [CandidateSegment] {
        var segments: [CandidateSegment] = []
        segments.append(contentsOf: detectHorizontalSegments(in: edges, width: width, height: height))
        segments.append(contentsOf: detectVerticalSegments(in: edges, width: width, height: height))
        return mergeSimilarSegments(segments)
    }

    private static func detectHorizontalSegments(in edges: [Bool], width: Int, height: Int) -> [CandidateSegment] {
        let rowThreshold = max(18, Int(Double(width) * 0.08))
        let minRun = max(32, Int(Double(width) * 0.05))
        let rows = groupedIndices((1..<(height - 1)).filter { y in
            var count = 0
            for x in 1..<(width - 1) where edges[y * width + x] { count += 1 }
            return count >= rowThreshold
        })

        return rows.flatMap { group -> [CandidateSegment] in
            let y = Int(group.reduce(0, +) / max(group.count, 1))
            let columns = activeColumnsAround(row: y, edges: edges, width: width, height: height)
            return runs(in: columns, minimumLength: minRun).map { run in
                CandidateSegment(start: CGPoint(x: run.lowerBound, y: y), end: CGPoint(x: run.upperBound, y: y))
            }
        }
    }

    private static func detectVerticalSegments(in edges: [Bool], width: Int, height: Int) -> [CandidateSegment] {
        let columnThreshold = max(18, Int(Double(height) * 0.08))
        let minRun = max(32, Int(Double(height) * 0.05))
        let columns = groupedIndices((1..<(width - 1)).filter { x in
            var count = 0
            for y in 1..<(height - 1) where edges[y * width + x] { count += 1 }
            return count >= columnThreshold
        })

        return columns.flatMap { group -> [CandidateSegment] in
            let x = Int(group.reduce(0, +) / max(group.count, 1))
            let rows = activeRowsAround(column: x, edges: edges, width: width, height: height)
            return runs(in: rows, minimumLength: minRun).map { run in
                CandidateSegment(start: CGPoint(x: x, y: run.lowerBound), end: CGPoint(x: x, y: run.upperBound))
            }
        }
    }

    private static func activeColumnsAround(row: Int, edges: [Bool], width: Int, height: Int) -> [Int] {
        let yRange = max(0, row - 3)...min(height - 1, row + 3)
        return (0..<width).filter { x in
            yRange.contains { y in edges[y * width + x] }
        }
    }

    private static func activeRowsAround(column: Int, edges: [Bool], width: Int, height: Int) -> [Int] {
        let xRange = max(0, column - 3)...min(width - 1, column + 3)
        return (0..<height).filter { y in
            xRange.contains { x in edges[y * width + x] }
        }
    }

    private static func groupedIndices(_ indices: [Int]) -> [[Int]] {
        groupedIndices(indices, maximumGap: 4)
    }

    private static func groupedIndices(_ indices: [Int], maximumGap: Int) -> [[Int]] {
        guard let first = indices.first else { return [] }
        var groups: [[Int]] = [[first]]
        for index in indices.dropFirst() {
            if let last = groups.last?.last, index - last <= maximumGap {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        return groups
    }

    private static func runs(in indices: [Int], minimumLength: Int) -> [Range<Int>] {
        groupedIndices(indices).compactMap { group in
            guard let first = group.first, let last = group.last, last - first >= minimumLength else { return nil }
            return first..<last
        }
    }

    private static func mergeSimilarSegments(_ segments: [CandidateSegment]) -> [CandidateSegment] {
        var result: [CandidateSegment] = []
        for segment in segments.sorted(by: { segmentLength($0) > segmentLength($1) }) {
            let duplicate = result.contains { existing in
                abs(existing.start.x - segment.start.x) < 8 &&
                abs(existing.start.y - segment.start.y) < 8 &&
                abs(existing.end.x - segment.end.x) < 8 &&
                abs(existing.end.y - segment.end.y) < 8
            }
            if !duplicate {
                result.append(segment)
            }
        }
        return result
    }

    private static func makeWalls(
        from segments: [CandidateSegment],
        imageSize: CGSize,
        preassignedKinds: [WallKind]? = nil
    ) -> [WallSegment] {
        let mapped = segments.map { segment -> CandidateSegment in
            CandidateSegment(start: mapToCanvas(segment.start, imageSize: imageSize),
                             end: mapToCanvas(segment.end, imageSize: imageSize))
        }
        let bounds = boundingRect(for: mapped)

        var walls: [WallSegment] = []
        for (index, segment) in mapped.enumerated() {
            let start = DrawingDocument.snap(segment.start)
            let end = DrawingDocument.snap(segment.end)
            guard hypot(end.x - start.x, end.y - start.y) >= 60 else { continue }
            let kind: WallKind
            if let kinds = preassignedKinds, index < kinds.count {
                kind = kinds[index]
            } else {
                kind = wallKind(for: segment, bounds: bounds)
            }
            walls.append(WallSegment(start: start, end: end, kind: kind))
        }

        return removeNearDuplicateWalls(collapseParallelWallEdges(walls))
    }

    /// Final safety-net pass: removes remaining near-parallel near-coincident duplicates
    /// that slipped through collapseParallelWallEdges, keeping the longer wall of each pair.
    private static func removeNearDuplicateWalls(_ walls: [WallSegment]) -> [WallSegment] {
        let sorted = walls.sorted {
            hypot($0.end.x - $0.start.x, $0.end.y - $0.start.y) >
            hypot($1.end.x - $1.start.x, $1.end.y - $1.start.y)
        }
        var kept: [WallSegment] = []
        for wall in sorted {
            let h = isHorizontal(wall)
            let isDuplicate = kept.contains { other in
                guard isHorizontal(other) == h else { return false }
                if h {
                    let axisDist = abs((wall.start.y + wall.end.y) / 2 - (other.start.y + other.end.y) / 2)
                    guard axisDist > 1, axisDist <= 60 else { return false }
                    let s1 = min(wall.start.x, wall.end.x);  let e1 = max(wall.start.x, wall.end.x)
                    let s2 = min(other.start.x, other.end.x); let e2 = max(other.start.x, other.end.x)
                    let overlap = min(e1, e2) - max(s1, s2)
                    let shortest = min(e1 - s1, e2 - s2)
                    return shortest > 0 && overlap >= shortest * 0.4
                } else {
                    let axisDist = abs((wall.start.x + wall.end.x) / 2 - (other.start.x + other.end.x) / 2)
                    guard axisDist > 1, axisDist <= 60 else { return false }
                    let s1 = min(wall.start.y, wall.end.y);  let e1 = max(wall.start.y, wall.end.y)
                    let s2 = min(other.start.y, other.end.y); let e2 = max(other.start.y, other.end.y)
                    let overlap = min(e1, e2) - max(s1, s2)
                    let shortest = min(e1 - s1, e2 - s2)
                    return shortest > 0 && overlap >= shortest * 0.4
                }
            }
            if !isDuplicate { kept.append(wall) }
        }
        return kept
    }

    private static func collapseParallelWallEdges(_ walls: [WallSegment]) -> [WallSegment] {
        let horizontal = walls.filter { isHorizontal($0) }
        let vertical = walls.filter { !isHorizontal($0) }

        return collapseHorizontalEdges(horizontal) + collapseVerticalEdges(vertical)
    }

    private static func collapseHorizontalEdges(_ walls: [WallSegment]) -> [WallSegment] {
        let lines = walls.map { wall -> AxisAlignedWallLine in
            AxisAlignedWallLine(
                axis: (wall.start.y + wall.end.y) / 2,
                start: min(wall.start.x, wall.end.x),
                end: max(wall.start.x, wall.end.x),
                kind: wall.kind
            )
        }
        return collapseNearbyLines(lines).map { line in
            WallSegment(
                start: DrawingDocument.snap(CGPoint(x: line.start, y: line.axis)),
                end: DrawingDocument.snap(CGPoint(x: line.end, y: line.axis)),
                kind: line.kind
            )
        }
    }

    private static func collapseVerticalEdges(_ walls: [WallSegment]) -> [WallSegment] {
        let lines = walls.map { wall -> AxisAlignedWallLine in
            AxisAlignedWallLine(
                axis: (wall.start.x + wall.end.x) / 2,
                start: min(wall.start.y, wall.end.y),
                end: max(wall.start.y, wall.end.y),
                kind: wall.kind
            )
        }
        return collapseNearbyLines(lines).map { line in
            WallSegment(
                start: DrawingDocument.snap(CGPoint(x: line.axis, y: line.start)),
                end: DrawingDocument.snap(CGPoint(x: line.axis, y: line.end)),
                kind: line.kind
            )
        }
    }

    private static func collapseNearbyLines(_ lines: [AxisAlignedWallLine]) -> [AxisAlignedWallLine] {
        let sorted = lines.sorted {
            if abs($0.axis - $1.axis) > 1 { return $0.axis < $1.axis }
            return $0.start < $1.start
        }
        var result: [AxisAlignedWallLine] = []

        for line in sorted {
            // Find the CLOSEST matching line (minimum axis distance) rather than the first,
            // to avoid a far wall greedy-capturing lines that belong to a nearer pair.
            let matchIndex = result.indices
                .filter { canCollapse(result[$0], with: line) }
                .min { abs(result[$0].axis - line.axis) < abs(result[$1].axis - line.axis) }
            if let matchIndex {
                let existing = result[matchIndex]
                result[matchIndex] = AxisAlignedWallLine(
                    axis: (existing.axis + line.axis) / 2,
                    start: min(existing.start, line.start),
                    end: max(existing.end, line.end),
                    kind: existing.kind == .exterior || line.kind == .exterior ? .exterior : .interior
                )
            } else {
                result.append(line)
            }
        }

        return mergeCollinearRuns(result)
    }

    private static func canCollapse(_ first: AxisAlignedWallLine, with second: AxisAlignedWallLine) -> Bool {
        let wallPairDistance: CGFloat = 55
        let axisDistance = abs(first.axis - second.axis)
        guard axisDistance > 1, axisDistance <= wallPairDistance else { return false }

        let overlap = min(first.end, second.end) - max(first.start, second.start)
        let shortest = min(first.end - first.start, second.end - second.start)
        guard shortest > 0 else { return false }

        return overlap >= min(shortest * 0.55, 120)
    }

    private static func mergeCollinearRuns(_ lines: [AxisAlignedWallLine]) -> [AxisAlignedWallLine] {
        let sorted = lines.sorted {
            if abs($0.axis - $1.axis) > 1 { return $0.axis < $1.axis }
            return $0.start < $1.start
        }
        var result: [AxisAlignedWallLine] = []

        for line in sorted {
            if let last = result.last,
               abs(last.axis - line.axis) <= 12,
               line.start - last.end <= 35,
               line.end >= last.start {
                result[result.count - 1] = AxisAlignedWallLine(
                    axis: (last.axis + line.axis) / 2,
                    start: min(last.start, line.start),
                    end: max(last.end, line.end),
                    kind: last.kind == .exterior || line.kind == .exterior ? .exterior : .interior
                )
            } else {
                result.append(line)
            }
        }

        return result
    }

    private static func isHorizontal(_ wall: WallSegment) -> Bool {
        abs(wall.start.y - wall.end.y) <= abs(wall.start.x - wall.end.x)
    }

    private static func isHorizontal(_ seg: CandidateSegment) -> Bool {
        abs(seg.end.y - seg.start.y) <= abs(seg.end.x - seg.start.x)
    }

    private static func mapToCanvas(_ point: CGPoint, imageSize: CGSize) -> CGPoint {
        let canvas = DrawingDocument.canvasSize
        let scale = min(canvas / imageSize.width, canvas / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let offset = CGPoint(x: (canvas - drawSize.width) / 2, y: (canvas - drawSize.height) / 2)
        return CGPoint(x: offset.x + point.x * scale, y: offset.y + point.y * scale)
    }

    private static func wallKind(for segment: CandidateSegment, bounds: CGRect) -> WallKind {
        let tolerance: CGFloat = 60
        for point in [segment.start, segment.end] {
            if abs(point.y - bounds.minY) < tolerance || abs(point.y - bounds.maxY) < tolerance { return .exterior }
            if abs(point.x - bounds.minX) < tolerance || abs(point.x - bounds.maxX) < tolerance { return .exterior }
        }
        return .interior
    }

    private static func boundingRect(for segments: [CandidateSegment]) -> CGRect {
        let points = segments.flatMap { [$0.start, $0.end] }
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max()
        else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func segmentLength(_ segment: CandidateSegment) -> CGFloat {
        hypot(segment.end.x - segment.start.x, segment.end.y - segment.start.y)
    }

    // MARK: - PASSO A: Gap Closing

    /// Bridges gaps between collinear facing segments (door/window openings).
    /// Returns closed segments plus the pixel-space midpoint and width of each bridged gap.
    private static func closeGaps(
        _ input: [CandidateSegment],
        imageSize: CGSize,
        maxOpeningPx: Double = 65
    ) -> (closed: [CandidateSegment], openings: [DetectedGapOpening]) {
        var segs = input
        var openings: [DetectedGapOpening] = []
        let tolPerp: CGFloat = 7  // max perpendicular deviation for collinearity

        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for i in 0..<segs.count {
                for j in (i + 1)..<segs.count {
                    let a = segs[i], b = segs[j]
                    guard isHorizontal(a) == isHorizontal(b) else { continue }

                    // Find the closest endpoint pair between a and b
                    let endpointPairs: [(CGPoint, CGPoint)] = [
                        (a.start, b.start), (a.start, b.end),
                        (a.end,   b.start), (a.end,   b.end)
                    ]
                    guard let (pA, pB) = endpointPairs.min(by: {
                        hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) <
                        hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y)
                    }) else { continue }
                    let gapDist = hypot(pA.x - pB.x, pA.y - pB.y)
                    guard gapDist > 1, gapDist <= CGFloat(maxOpeningPx) else { continue }

                    // Verify collinearity: gap midpoint must lie on segment a's line
                    let gapMid = CGPoint(x: (pA.x + pB.x) / 2, y: (pA.y + pB.y) / 2)
                    guard perpDistanceFromSegmentLine(gapMid, segment: a) <= tolPerp else { continue }

                    // Merge: take the two farthest endpoints as the new segment endpoints
                    let pts = [a.start, a.end, b.start, b.end]
                    var maxD: CGFloat = 0; var e1 = pts[0], e2 = pts[1]
                    for m in 0..<pts.count {
                        for n in (m + 1)..<pts.count {
                            let d = hypot(pts[m].x - pts[n].x, pts[m].y - pts[n].y)
                            if d > maxD { maxD = d; e1 = pts[m]; e2 = pts[n] }
                        }
                    }
                    openings.append(DetectedGapOpening(midpoint: gapMid, width: Double(gapDist)))
                    segs[i] = CandidateSegment(start: e1, end: e2)
                    segs.remove(at: j)
                    didMerge = true
                    break outer
                }
            }
        }
        return (segs, openings)
    }

    /// Perpendicular distance from `point` to the infinite line through `segment`.
    private static func perpDistanceFromSegmentLine(_ point: CGPoint, segment: CandidateSegment) -> CGFloat {
        let dx = segment.end.x - segment.start.x
        let dy = segment.end.y - segment.start.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return hypot(point.x - segment.start.x, point.y - segment.start.y) }
        return abs((point.x - segment.start.x) * dy - (point.y - segment.start.y) * dx) / len
    }

    // MARK: - PASSO B: Flood-Fill Wall Classification

    /// Rasterizes a segment as a 3px-wide line (Bresenham) into `buf`.
    private static func rasterizeLine(
        _ buf: inout [UInt8], width w: Int, height h: Int,
        x1: Int, y1: Int, x2: Int, y2: Int
    ) {
        var cx = x1, cy = y1
        let adx = abs(x2 - x1), ady = abs(y2 - y1)
        let sx = x1 < x2 ? 1 : -1
        let sy = y1 < y2 ? 1 : -1
        var err = adx - ady
        while true {
            // 3px perpendicular thickness to block diagonal flood leaks
            if adx >= ady {
                for off in -1...1 {
                    let ny = cy + off
                    if cx >= 0, ny >= 0, cx < w, ny < h { buf[ny * w + cx] = 1 }
                }
            } else {
                for off in -1...1 {
                    let nx = cx + off
                    if nx >= 0, cy >= 0, nx < w, cy < h { buf[cy * w + nx] = 1 }
                }
            }
            if cx == x2 && cy == y2 { break }
            let e2 = 2 * err
            if e2 > -ady { err -= ady; cx += sx }
            if e2 <  adx { err += adx; cy += sy }
        }
    }

    /// Classifies each segment as `.exterior` (touches the flood-filled outside) or `.interior`.
    /// Returns `nil` if flood-fill cannot start (all borders are walls), triggering bounds fallback.
    private static func classifyWallKindsByFloodFill(
        segments: [CandidateSegment],
        width w: Int,
        height h: Int
    ) -> [WallKind]? {
        var buf = [UInt8](repeating: 0, count: w * h)

        // Rasterize all segments
        for seg in segments {
            rasterizeLine(&buf, width: w, height: h,
                          x1: Int(seg.start.x.rounded()), y1: Int(seg.start.y.rounded()),
                          x2: Int(seg.end.x.rounded()),   y2: Int(seg.end.y.rounded()))
        }

        // Find a background pixel on the image border as flood-fill seed
        var seedX = -1, seedY = -1
        for x in 0..<w where buf[x] == 0               { seedX = x; seedY = 0;     break }
        if seedX < 0 { for x in 0..<w where buf[(h-1)*w+x] == 0 { seedX = x; seedY = h-1; break } }
        if seedX < 0 { for y in 0..<h where buf[y*w] == 0       { seedX = 0; seedY = y;    break } }
        if seedX < 0 { for y in 0..<h where buf[y*w+w-1] == 0   { seedX = w-1; seedY = y; break } }
        guard seedX >= 0 else { return nil }

        // 4-connected iterative flood-fill: marks exterior pixels as 2
        var stack = [(seedX, seedY)]
        while let (x, y) = stack.popLast() {
            guard x >= 0, y >= 0, x < w, y < h else { continue }
            let p = y * w + x
            guard buf[p] == 0 else { continue }
            buf[p] = 2
            stack.append((x + 1, y)); stack.append((x - 1, y))
            stack.append((x, y + 1)); stack.append((x, y - 1))
        }
        guard buf.contains(2) else { return nil }

        // Probe each segment perpendicularly — exterior contact on either side → .exterior
        let probeDist = 5
        return segments.map { seg in
            let dx = seg.end.x - seg.start.x
            let dy = seg.end.y - seg.start.y
            let len = hypot(dx, dy)
            guard len > 0 else { return .interior }
            let pxU = -dy / len  // perpendicular unit vector
            let pyU =  dx / len

            for i in 1...5 {
                let t = CGFloat(i) / 6.0
                let cx = seg.start.x + t * dx
                let cy = seg.start.y + t * dy
                for sign: CGFloat in [-1, 1] {
                    let nx = Int((cx + sign * pxU * CGFloat(probeDist)).rounded())
                    let ny = Int((cy + sign * pyU * CGFloat(probeDist)).rounded())
                    if nx >= 0, ny >= 0, nx < w, ny < h, buf[ny * w + nx] == 2 {
                        return .exterior
                    }
                }
            }
            return .interior
        }
    }

    // MARK: - Opening Placement

    /// Converts pixel-space gap openings to `PlacedOpening` objects on the final canvas walls.
    private static func placeDetectedOpenings(
        _ openings: [DetectedGapOpening],
        walls: [WallSegment],
        imageSize: CGSize
    ) -> [PlacedOpening] {
        let scale = min(DrawingDocument.canvasSize / imageSize.width,
                        DrawingDocument.canvasSize / imageSize.height)
        var result: [PlacedOpening] = []

        for opening in openings {
            let canvasMid = mapToCanvas(opening.midpoint, imageSize: imageSize)
            let rawWidth = CGFloat(opening.width) * scale
            let clampedWidth = max(40, min(160, rawWidth))

            var bestWall: WallSegment?
            var bestT: CGFloat = 0
            var bestDist: CGFloat = .greatestFiniteMagnitude

            for wall in walls {
                let proj = wall.project(canvasMid)
                guard proj.t > 0.08, proj.t < 0.92, proj.distance < 50 else { continue }
                if proj.distance < bestDist {
                    bestDist = proj.distance; bestWall = wall; bestT = proj.t
                }
            }
            guard let wall = bestWall else { continue }
            result.append(PlacedOpening(wallID: wall.id, t: bestT, kind: .door, width: clampedWidth))
        }

        return result
    }

    // MARK: - Zhang-Suen Thinning

    /// Reduces foreground (value=1) regions to 1-pixel-wide centerlines.
    /// Input and output use 1=foreground, 0=background.
    private static func zhangSuenThinning(_ src: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var img = src
        @inline(__always) func at(_ x: Int, _ y: Int) -> UInt8 { img[y * w + x] }
        var changed = true
        while changed {
            changed = false
            for pass in 0..<2 {
                var toDelete: [Int] = []
                for y in 1..<(h - 1) {
                    for x in 1..<(w - 1) {
                        let p = y * w + x
                        if img[p] == 0 { continue }
                        let p2 = at(x,     y - 1)  // N
                        let p3 = at(x + 1, y - 1)  // NE
                        let p4 = at(x + 1, y)      // E
                        let p5 = at(x + 1, y + 1)  // SE
                        let p6 = at(x,     y + 1)  // S
                        let p7 = at(x - 1, y + 1)  // SW
                        let p8 = at(x - 1, y)      // W
                        let p9 = at(x - 1, y - 1)  // NW
                        let B = Int(p2)+Int(p3)+Int(p4)+Int(p5)+Int(p6)+Int(p7)+Int(p8)+Int(p9)
                        if B < 2 || B > 6 { continue }
                        let seq: [UInt8] = [p2, p3, p4, p5, p6, p7, p8, p9, p2]
                        var A = 0
                        for i in 0..<8 where seq[i] == 0 && seq[i + 1] == 1 { A += 1 }
                        if A != 1 { continue }
                        if pass == 0 {
                            if Int(p2)*Int(p4)*Int(p6) != 0 { continue }
                            if Int(p4)*Int(p6)*Int(p8) != 0 { continue }
                        } else {
                            if Int(p2)*Int(p4)*Int(p8) != 0 { continue }
                            if Int(p2)*Int(p6)*Int(p8) != 0 { continue }
                        }
                        toDelete.append(p)
                    }
                }
                if !toDelete.isEmpty {
                    changed = true
                    for p in toDelete { img[p] = 0 }
                }
            }
        }
        return img
    }

    // MARK: - Orthogonal Skeleton Extraction

    /// Extracts horizontal and vertical runs from a 1px skeleton image.
    /// gapTolerance is intentionally small (12px) to preserve door openings as gaps.
    private static func extractOrthogonalFromSkeleton(_ skel: [UInt8], width w: Int, height h: Int) -> [CandidateSegment] {
        let minLength = max(12, Int(0.022 * Double(max(w, h))))
        let gapTolerance = 12

        @inline(__always) func at(_ x: Int, _ y: Int) -> UInt8 { skel[y * w + x] }
        var segs: [CandidateSegment] = []

        // Horizontal runs — each row scanned independently
        for y in 0..<h {
            var x = 0
            while x < w {
                guard at(x, y) == 1 else { x += 1; continue }
                let start = x
                var end = x
                var gap = 0
                var xx = x + 1
                while xx < w {
                    if at(xx, y) == 1 { end = xx; gap = 0 }
                    else {
                        gap += 1
                        if gap > gapTolerance { break }
                    }
                    xx += 1
                }
                if end - start + 1 >= minLength {
                    segs.append(CandidateSegment(
                        start: CGPoint(x: start, y: y),
                        end:   CGPoint(x: end,   y: y)
                    ))
                }
                x = xx
            }
        }

        // Vertical runs — each column scanned independently
        for x in 0..<w {
            var y = 0
            while y < h {
                guard at(x, y) == 1 else { y += 1; continue }
                let start = y
                var end = y
                var gap = 0
                var yy = y + 1
                while yy < h {
                    if at(x, yy) == 1 { end = yy; gap = 0 }
                    else {
                        gap += 1
                        if gap > gapTolerance { break }
                    }
                    yy += 1
                }
                if end - start + 1 >= minLength {
                    segs.append(CandidateSegment(
                        start: CGPoint(x: x, y: start),
                        end:   CGPoint(x: x, y: end)
                    ))
                }
                y = yy
            }
        }

        return mergeSimilarSegments(segs)
    }
}

private extension UIImage {
    func renderedCGImage() -> CGImage? {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}
