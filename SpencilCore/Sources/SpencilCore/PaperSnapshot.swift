import Foundation

/// Tiny grayscale "fingerprint" of the sheet, sampled in paper coordinates.
///
/// Saved with the session. When the paper is re-found (resume, or tracking
/// lost), comparing against it in each possible orientation tells us which
/// way up the sheet is — as long as something has been drawn on it.
public enum PaperSnapshot {
    public static let cols = 32
    public static let rows = 44

    public static func capture(_ img: LumaImage, quad: Quad, paper: PaperSize) -> [UInt8]? {
        guard let h = Homography(from: paper.corners, to: quad.corners) else { return nil }
        let w = paper.shortMM, ht = paper.longMM
        var out = [UInt8]()
        out.reserveCapacity(cols * rows)
        var missing = 0
        for r in 0..<rows {
            for c in 0..<cols {
                var acc = 0.0, n = 0.0
                for sy in 0..<2 {
                    for sx in 0..<2 {
                        // Inset 5% to stay clear of the edges/background.
                        let u = 0.05 + 0.9 * (Double(c) + 0.25 + 0.5 * Double(sx)) / Double(cols)
                        let v = 0.05 + 0.9 * (Double(r) + 0.25 + 0.5 * Double(sy)) / Double(rows)
                        if let p = h.applyChecked(Vec2(u * w, v * ht)), let val = img.sample(p) {
                            acc += val; n += 1
                        }
                    }
                }
                if n == 0 { missing += 1 }
                out.append(n > 0 ? UInt8(max(0, min(255, acc / n))) : 0)
            }
        }
        return missing > cols * rows / 10 ? nil : out
    }

    /// Which corner-shift (0/2, or 0–3 for square paper) makes the current view
    /// match the reference. nil when it can't tell (e.g. blank paper).
    public static func bestRotation(_ img: LumaImage, quad: Quad, paper: PaperSize, reference: [UInt8]) -> Int? {
        let steps = paper.isSquare ? [0, 1, 2, 3] : [0, 2]
        let ref = highPass(reference)
        var scores = [(k: Int, s: Double)]()
        for k in steps {
            guard let snap = capture(img, quad: quad.rotated(by: k), paper: paper),
                  let s = ncc(highPass(snap), ref) else { return nil }
            scores.append((k, s))
        }
        scores.sort { $0.s > $1.s }
        guard scores[0].s > 0.3, scores[0].s - scores[1].s > 0.15 else { return nil }
        return scores[0].k
    }

    /// Removes slow lighting gradients so only the drawing itself is compared.
    static func highPass(_ x: [UInt8]) -> [Double] {
        let r = 4
        var out = [Double](repeating: 0, count: x.count)
        for y in 0..<rows {
            for c in 0..<cols {
                var acc = 0.0, n = 0.0
                for yy in max(0, y - r)...min(rows - 1, y + r) {
                    for xx in max(0, c - r)...min(cols - 1, c + r) {
                        acc += Double(x[yy * cols + xx]); n += 1
                    }
                }
                out[y * cols + c] = Double(x[y * cols + c]) - acc / n
            }
        }
        return out
    }

    /// Normalized cross-correlation; nil if either signal is basically flat.
    static func ncc(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in 0..<a.count {
            let da = a[i] - ma, db = b[i] - mb
            sab += da * db; saa += da * da; sbb += db * db
        }
        let sa = (saa / n).squareRoot(), sb = (sbb / n).squareRoot()
        guard sa > 2, sb > 2 else { return nil }
        return sab / (saa * sbb).squareRoot()
    }
}
