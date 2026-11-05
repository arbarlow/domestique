import SwiftUI

/// Pure SwiftUI activity indicator. NSProgressIndicator-backed ProgressViews inside lists/split views
/// can send AppKit into constraint-update loops; this one has no AppKit view at all.
struct Spinner: View {
    var size: CGFloat = 12
    var lineWidth: CGFloat? = nil
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.88)
            .stroke(.secondary, style: StrokeStyle(lineWidth: lineWidth ?? max(1.5, size / 7), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
