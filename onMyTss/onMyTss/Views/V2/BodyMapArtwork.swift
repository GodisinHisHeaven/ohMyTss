import SwiftUI

/// A schematic figure, not an anatomical measurement. All paths share one view box.
enum BodyMapArtwork {
    static let size = CGSize(width: 240, height: 488)
    static let bounds = CGRect(origin: .zero, size: size)

    struct Zone: Identifiable {
        let region: Region
        let side: BodySide
        let outline: Path
        let detail: Path
        let marker: CGPoint
        var id: String { "\(region.rawValue).\(side.rawValue)" }
        var bounds: CGRect { outline.boundingRect }
    }

    static let silhouette = Path { p in
        // Head and jaw.
        p.move(120, 8)
        p.curve(103, 8, 98, 19, 100, 34)
        p.curve(100, 46, 104, 53, 109, 57)
        p.quad(120, 66, 131, 57)
        p.curve(136, 53, 140, 46, 140, 34)
        p.curve(142, 19, 137, 8, 120, 8)
        p.closeSubpath()

        // Neck, relaxed arms, torso, and legs. The open stance separates the regions.
        p.move(109, 60)
        p.line(109, 69)
        p.curve(104, 73, 94, 75, 83, 77)
        p.curve(69, 78, 60, 85, 56, 101)
        p.line(44, 136)
        p.curve(40, 146, 38, 157, 34, 171)
        p.line(23, 218)
        p.quad(18, 226, 18, 233)
        p.line(16, 249)
        p.quad(15, 258, 21, 251)
        p.line(25, 240)
        p.line(25, 256)
        p.quad(28, 264, 32, 256)
        p.line(37, 240)
        p.quad(40, 233, 35, 223)
        p.line(45, 189)
        p.curve(50, 177, 54, 163, 55, 154)
        p.line(67, 116)
        p.curve(72, 132, 79, 148, 80, 162)
        p.curve(82, 176, 76, 191, 75, 208)
        p.curve(70, 227, 71, 248, 76, 270)
        p.curve(80, 299, 80, 324, 84, 343)
        p.curve(85, 356, 79, 369, 83, 384)
        p.curve(85, 402, 90, 417, 93, 433)
        p.line(92, 453)
        p.quad(82, 463, 82, 469)
        p.quad(77, 478, 101, 477)
        p.quad(110, 477, 110, 466)
        p.line(112, 435)
        p.curve(114, 416, 120, 399, 117, 384)
        p.quad(113, 360, 113, 344)
        p.curve(115, 324, 117, 288, 118, 267)
        p.quad(118, 254, 120, 246)
        p.quad(122, 254, 122, 267)
        p.curve(123, 288, 125, 324, 127, 344)
        p.quad(127, 360, 123, 384)
        p.curve(120, 399, 126, 416, 128, 435)
        p.line(130, 466)
        p.quad(130, 477, 139, 477)
        p.quad(163, 478, 158, 469)
        p.quad(158, 463, 148, 453)
        p.line(147, 433)
        p.curve(150, 417, 155, 402, 157, 384)
        p.curve(161, 369, 155, 356, 156, 343)
        p.curve(160, 324, 160, 299, 164, 270)
        p.curve(169, 248, 170, 227, 165, 208)
        p.curve(164, 191, 158, 176, 160, 162)
        p.curve(161, 148, 168, 132, 173, 116)
        p.line(185, 154)
        p.curve(186, 163, 190, 177, 195, 189)
        p.line(205, 223)
        p.quad(200, 233, 203, 240)
        p.line(208, 256)
        p.quad(212, 264, 215, 256)
        p.line(215, 240)
        p.line(219, 251)
        p.quad(225, 258, 224, 249)
        p.line(222, 233)
        p.quad(222, 226, 217, 218)
        p.line(206, 171)
        p.curve(202, 157, 200, 146, 196, 136)
        p.line(184, 101)
        p.curve(180, 85, 171, 78, 157, 77)
        p.curve(146, 75, 136, 73, 131, 69)
        p.line(131, 60)
        p.quad(120, 67, 109, 60)
        p.closeSubpath()
    }

    static func zones(back: Bool) -> [Zone] {
        let definitions: [(Region, Path, Path, CGPoint)] = [
            (.arms, arms, armDetail, CGPoint(x: 47, y: 150)),
            (.shoulders, shoulders, Path(), CGPoint(x: 69, y: 97)),
            (back ? .back : .chest, back ? upperBack : chest,
             back ? backDetail : chestDetail, CGPoint(x: 101, y: back ? 126 : 107)),
            (back ? .glutes : .core, back ? glutes : core,
             back ? Path() : coreDetail, CGPoint(x: 102, y: back ? 241 : 174)),
            (back ? .hamstrings : .quads, back ? hamstrings : quads,
             thighDetail(back: back), CGPoint(x: 98, y: 294)),
            (.calves, calves(back: back), calfDetail, CGPoint(x: 99, y: 380))
        ]
        return definitions.flatMap { region, outline, detail, marker in
            [Zone(region: region, side: back ? .left : .right, outline: outline, detail: detail, marker: marker),
             Zone(region: region, side: back ? .right : .left, outline: mirrored(outline), detail: mirrored(detail),
                  marker: CGPoint(x: size.width - marker.x, y: marker.y))]
        }
    }

    static func contours(back: Bool) -> Path {
        let half = Path { p in
            p.move(110, 68)
            p.quad(112, 74, 118, 78)
            if !back {
                p.move(84, 212)
                p.quad(103, 220, 115, 234)
                p.addRoundedRect(in: CGRect(x: 88, y: 337, width: 19, height: 12), cornerSize: CGSize(width: 8, height: 6))
            } else {
                p.move(90, 342)
                p.quad(99, 346, 108, 342)
            }
            p.move(96, 449)
            p.quad(100, 452, 105, 451)
        }
        var path = half
        path.addPath(mirrored(half))
        return path
    }

    private static func mirrored(_ path: Path) -> Path {
        path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0))
    }

    private static let shoulders = Path { p in
        p.move(76, 81)
        p.curve(65, 83, 59, 92, 56, 105)
        p.line(64, 118)
        p.curve(69, 110, 72, 101, 83, 97)
        p.line(86, 84)
        p.quad(81, 81, 76, 81)
        p.closeSubpath()
    }

    private static let arms = Path { p in
        p.move(56, 113)
        p.curve(51, 124, 48, 139, 43, 153)
        p.quad(46, 160, 52, 154)
        p.curve(58, 144, 60, 128, 63, 123)
        p.closeSubpath()
        p.move(43, 161)
        p.curve(38, 171, 34, 189, 29, 207)
        p.line(27, 221)
        p.line(32, 224)
        p.curve(37, 211, 43, 195, 47, 180)
        p.line(50, 164)
        p.quad(46, 160, 43, 161)
        p.closeSubpath()
    }

    private static let chest = Path { p in
        p.move(90, 84)
        p.curve(99, 80, 110, 81, 117, 84)
        p.line(117, 122)
        p.curve(106, 130, 90, 127, 80, 117)
        p.line(75, 107)
        p.curve(79, 97, 86, 91, 90, 84)
        p.closeSubpath()
    }

    private static let core = Path { p in
        p.move(83, 132)
        p.curve(94, 137, 107, 135, 117, 131)
        p.line(117, 214)
        p.curve(108, 217, 97, 213, 87, 204)
        p.line(84, 182)
        p.curve(89, 165, 87, 151, 83, 132)
        p.closeSubpath()
    }

    private static let upperBack = Path { p in
        p.move(91, 82)
        p.curve(101, 80, 110, 76, 117, 76)
        p.line(117, 215)
        p.quad(101, 219, 86, 211)
        p.line(86, 188)
        p.quad(88, 177, 91, 169)
        p.curve(86, 158, 81, 144, 78, 132)
        p.line(75, 108)
        p.quad(86, 95, 91, 82)
        p.closeSubpath()
    }

    private static let glutes = Path { p in
        p.move(84, 223)
        p.curve(92, 217, 108, 218, 117, 226)
        p.line(117, 253)
        p.curve(110, 265, 92, 268, 81, 257)
        p.quad(77, 242, 84, 223)
        p.closeSubpath()
    }

    private static let quads = Path { p in
        p.move(84, 225)
        p.curve(91, 223, 109, 230, 116, 244)
        p.line(112, 287)
        p.curve(110, 306, 110, 322, 107, 331)
        p.quad(94, 339, 87, 327)
        p.curve(82, 305, 80, 280, 79, 256)
        p.quad(77, 240, 84, 225)
        p.closeSubpath()
    }

    private static let hamstrings = Path { p in
        p.move(81, 266)
        p.curve(91, 274, 106, 273, 114, 264)
        p.curve(114, 289, 111, 316, 108, 333)
        p.quad(97, 338, 87, 329)
        p.curve(83, 308, 81, 287, 81, 266)
        p.closeSubpath()
    }

    private static func calves(back: Bool) -> Path {
        Path { p in
            p.move(87, 354)
            p.quad(96, 348, 108, 355)
            p.curve(114, 365, 114, 381, 110, 394)
            p.curve(106, 409, 102, 420, 102, 440)
            p.quad(99, 446, 95, 439)
            p.line(92, 414)
            p.curve(back ? 84 : 88, 403, 82, 391, 83, 378)
            p.quad(82, 363, 87, 354)
            p.closeSubpath()
        }
    }

    private static let chestDetail = Path { p in
        p.move(84, 107)
        p.quad(96, 116, 112, 115)
    }

    private static let armDetail = Path { p in
        p.move(54, 126)
        p.quad(55, 138, 49, 148)
        p.move(43, 173)
        p.quad(37, 187, 32, 210)
    }

    private static let coreDetail = Path { p in
        p.move(102, 139)
        p.curve(99, 159, 101, 190, 103, 206)
        for y in [153.0, 174, 194] {
            p.move(103, y)
            p.quad(109, y - 3, 115, y - 1)
        }
        p.move(90, 150)
        p.quad(94, 156, 97, 158)
        p.move(90, 169)
        p.line(97, 176)
        p.move(90, 188)
        p.line(98, 194)
    }

    private static let backDetail = Path { p in
        p.move(113, 84)
        p.curve(100, 94, 94, 114, 98, 132)
        p.quad(103, 142, 113, 147)
        p.move(84, 127)
        p.quad(91, 146, 104, 155)
        p.move(111, 154)
        p.quad(103, 180, 108, 207)
    }

    private static func thighDetail(back: Bool) -> Path {
        Path { p in
            p.move(96, back ? 278 : 241)
            p.curve(100, back ? 290 : 265, 95, 300, 99, 324)
            if !back {
                p.move(88, 263)
                p.quad(84, 295, 92, 317)
                p.move(109, 285)
                p.quad(100, 309, 105, 324)
            }
        }
    }

    private static let calfDetail = Path { p in
        p.move(99, 359)
        p.curve(103, 383, 95, 401, 99, 426)
    }
}

struct BodyMapPath: Shape {
    let path: Path
    var sourceBounds: CGRect = BodyMapArtwork.bounds

    func path(in rect: CGRect) -> Path {
        path.applying(CGAffineTransform(translationX: -sourceBounds.minX, y: -sourceBounds.minY))
            .applying(CGAffineTransform(scaleX: rect.width / sourceBounds.width, y: rect.height / sourceBounds.height))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

// Compact curve notation keeps the artwork editable without hiding its control points.
private extension Path {
    mutating func move(_ x: CGFloat, _ y: CGFloat) { move(to: CGPoint(x: x, y: y)) }
    mutating func line(_ x: CGFloat, _ y: CGFloat) { addLine(to: CGPoint(x: x, y: y)) }
    mutating func quad(_ cx: CGFloat, _ cy: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
    }
    mutating func curve(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: ax, y: ay), control2: CGPoint(x: bx, y: by))
    }
}
