import Foundation
import simd

/// A sheet size. Modelled as portrait: x along the short side, y along the long side, in mm.
public struct PaperSize: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var shortMM: Double
    public var longMM: Double

    public init(name: String, shortMM: Double, longMM: Double) {
        self.name = name
        self.shortMM = min(shortMM, longMM)
        self.longMM = max(shortMM, longMM)
    }

    public var id: String { "\(name)-\(shortMM)x\(longMM)" }
    public var isSquare: Bool { (longMM - shortMM) / longMM < 0.03 }

    /// Corners in paper mm: TL, TR, BR, BL.
    public var corners: [Vec2] {
        [Vec2(0, 0), Vec2(shortMM, 0), Vec2(shortMM, longMM), Vec2(0, longMM)]
    }

    public var label: String {
        "\(name) · \(Self.fmt(shortMM)) × \(Self.fmt(longMM)) mm"
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    public static let a5 = PaperSize(name: "A5", shortMM: 148, longMM: 210)
    public static let a4 = PaperSize(name: "A4", shortMM: 210, longMM: 297)
    public static let a3 = PaperSize(name: "A3", shortMM: 297, longMM: 420)
    public static let letter = PaperSize(name: "Letter", shortMM: 215.9, longMM: 279.4)
    public static let legal = PaperSize(name: "Legal", shortMM: 215.9, longMM: 355.6)
    public static let presets: [PaperSize] = [.a5, .a4, .a3, .letter, .legal]
}

/// Where the reference image sits on the paper, in paper mm.
public struct Placement: Codable, Hashable, Sendable {
    public var centerX: Double
    public var centerY: Double
    public var width: Double
    /// Clockwise, as seen looking at the paper.
    public var rotationDegrees: Double

    public init(centerX: Double, centerY: Double, width: Double, rotationDegrees: Double = 0) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.rotationDegrees = rotationDegrees
    }

    /// Image corners on the paper (TL, TR, BR, BL). `imageAspect` = height / width.
    public func corners(imageAspect: Double) -> [Vec2] {
        let hw = width / 2, hh = width * imageAspect / 2
        let t = rotationDegrees * .pi / 180
        let c = cos(t), s = sin(t)
        let center = Vec2(centerX, centerY)
        return [Vec2(-hw, -hh), Vec2(hw, -hh), Vec2(hw, hh), Vec2(-hw, hh)].map {
            center + Vec2($0.x * c - $0.y * s, $0.x * s + $0.y * c)
        }
    }

    /// Centered, as large as fits with the given margin fraction.
    public static func fitted(paper: PaperSize, imageAspect: Double, fill: Double = 0.85) -> Placement {
        let w = min(paper.shortMM * fill, paper.longMM * fill / imageAspect)
        return Placement(centerX: paper.shortMM / 2, centerY: paper.longMM / 2, width: w)
    }
}
