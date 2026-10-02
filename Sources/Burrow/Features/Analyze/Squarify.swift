import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing and van Wijk, 2000).
///
/// Items are laid out greedily in rows along the shorter side of the remaining rectangle; an item
/// joins the current row only while that does not worsen the row's worst aspect ratio.
enum Squarify {
    /// - Parameters:
    ///   - values: positive weights, ideally sorted descending (the algorithm assumes it for good ratios).
    ///   - rect: the area to fill.
    /// - Returns: one rectangle per value, in the same order. Non-positive values get `.zero`.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0) { $0 + max(0, $1) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }

        let scale = Double(rect.width * rect.height) / total
        let items: [(index: Int, area: Double)] = values.enumerated()
            .filter { $0.element > 0 }
            .map { ($0.offset, $0.element * scale) }

        var remaining = rect
        var row: [(index: Int, area: Double)] = []
        var i = 0
        while i < items.count {
            let item = items[i]
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [item], side: side) <= worst(row, side: side) {
                row.append(item)
                i += 1
            } else {
                remaining = place(row, in: remaining, into: &result)
                row.removeAll()
            }
        }
        if !row.isEmpty { _ = place(row, in: remaining, into: &result) }
        return result
    }

    /// Worst aspect ratio of a row laid along a side of length `side`.
    static func worst(_ row: [(index: Int, area: Double)], side: Double) -> Double {
        guard !row.isEmpty, side > 0 else { return .infinity }
        let sum = row.reduce(0) { $0 + $1.area }
        guard sum > 0 else { return .infinity }
        let rmax = row.map(\.area).max() ?? 0
        let rmin = row.map(\.area).min() ?? 0
        let s2 = sum * sum, w2 = side * side
        return max(w2 * rmax / s2, s2 / (w2 * max(rmin, .leastNonzeroMagnitude)))
    }

    /// Places a finished row along the shorter side and returns the leftover rectangle.
    private static func place(_ row: [(index: Int, area: Double)], in rect: CGRect, into result: inout [CGRect]) -> CGRect {
        let sum = row.reduce(0) { $0 + $1.area }
        guard sum > 0 else { return rect }
        if rect.width >= rect.height {
            // Column on the left, items stacked top to bottom.
            let width = CGFloat(sum / Double(rect.height))
            var y = rect.minY
            for (n, item) in row.enumerated() {
                let h = n == row.count - 1 ? rect.maxY - y : CGFloat(item.area) / width
                result[item.index] = CGRect(x: rect.minX, y: y, width: width, height: h)
                y += h
            }
            return CGRect(x: rect.minX + width, y: rect.minY, width: max(0, rect.width - width), height: rect.height)
        } else {
            // Row along the top, items left to right.
            let height = CGFloat(sum / Double(rect.width))
            var x = rect.minX
            for (n, item) in row.enumerated() {
                let w = n == row.count - 1 ? rect.maxX - x : CGFloat(item.area) / height
                result[item.index] = CGRect(x: x, y: rect.minY, width: w, height: height)
                x += w
            }
            return CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: max(0, rect.height - height))
        }
    }
}
