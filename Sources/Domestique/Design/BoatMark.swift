import SwiftUI

/// boat.dev's mark (two sails over a hull), from https://boat.dev/icon.svg, as a vector shape so it
/// scales and takes any colour: brand blue on its own, white on a tile.
struct BoatMark: Shape {
    /// width / height of the original artwork.
    static let aspectRatio: CGFloat = 497.985 / 462.094
    /// boat.dev's brand blue.
    static let brandBlue = Color(red: 0x26 / 255, green: 0x3F / 255, blue: 0xA9 / 255)

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: p(rect, 0.98421, 0.78222))
        path.addCurve(to: p(rect, 1.00000, 0.79924), control1: p(rect, 0.99293, 0.78222), control2: p(rect, 1.00000, 0.78983))
        path.addLine(to: p(rect, 1.00000, 0.87410))
        path.addCurve(to: p(rect, 0.98421, 0.89111), control1: p(rect, 1.00000, 0.88349), control2: p(rect, 0.99293, 0.89111))
        path.addLine(to: p(rect, 0.95046, 0.89111))
        path.addCurve(to: p(rect, 0.93456, 0.90825), control1: p(rect, 0.94168, 0.89111), control2: p(rect, 0.93456, 0.89879))
        path.addLine(to: p(rect, 0.93456, 0.98299))
        path.addCurve(to: p(rect, 0.91877, 1.00000), control1: p(rect, 0.93456, 0.99238), control2: p(rect, 0.92749, 1.00000))
        path.addLine(to: p(rect, 0.16940, 1.00000))
        path.addCurve(to: p(rect, 0.16311, 0.99668), control1: p(rect, 0.16696, 1.00000), control2: p(rect, 0.16462, 0.99874))
        path.addCurve(to: p(rect, 0.01579, 0.89111), control1: p(rect, 0.10535, 0.91768), control2: p(rect, 0.10436, 0.91669))
        path.addCurve(to: p(rect, 0.00000, 0.87410), control1: p(rect, 0.00737, 0.88868), control2: p(rect, 0.00000, 0.88349))
        path.addLine(to: p(rect, 0.00000, 0.79924))
        path.addCurve(to: p(rect, 0.01579, 0.78222), control1: p(rect, 0.00000, 0.78983), control2: p(rect, 0.00707, 0.78222))
        path.addLine(to: p(rect, 0.98421, 0.78222))
        path.closeSubpath()
        path.move(to: p(rect, 0.47023, 0.01043))
        path.addCurve(to: p(rect, 0.50634, 0.01529), control1: p(rect, 0.47911, -0.00556), control2: p(rect, 0.50138, -0.00256))
        path.addLine(to: p(rect, 0.64648, 0.51985))
        path.addLine(to: p(rect, 0.49071, 0.73218))
        path.addLine(to: p(rect, 0.10434, 0.73218))
        path.addCurve(to: p(rect, 0.08728, 0.69974), control1: p(rect, 0.08890, 0.73218), control2: p(rect, 0.07935, 0.71403))
        path.addLine(to: p(rect, 0.47023, 0.01043))
        path.closeSubpath()
        path.move(to: p(rect, 0.90978, 0.28622))
        path.addCurve(to: p(rect, 0.87481, 0.27774), control1: p(rect, 0.90604, 0.26870), control2: p(rect, 0.88515, 0.26364))
        path.addLine(to: p(rect, 0.56687, 0.69746))
        path.addCurve(to: p(rect, 0.58247, 0.73218), control1: p(rect, 0.55657, 0.71151), control2: p(rect, 0.56585, 0.73218))
        path.addLine(to: p(rect, 0.98011, 0.73218))
        path.addCurve(to: p(rect, 0.99948, 0.70594), control1: p(rect, 0.99289, 0.73218), control2: p(rect, 1.00235, 0.71936))
        path.addLine(to: p(rect, 0.90978, 0.28622))
        path.closeSubpath()
        return path
    }

    private func p(_ rect: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }
}

/// The mark on a brand-blue rounded tile, matching the other settings and provider tiles.
struct BoatTile: View {
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(BoatMark.brandBlue.gradient)
            .frame(width: size, height: size)
            .overlay {
                BoatMark()
                    .fill(.white)
                    .aspectRatio(BoatMark.aspectRatio, contentMode: .fit)
                    .padding(size * 0.2)
            }
    }
}
