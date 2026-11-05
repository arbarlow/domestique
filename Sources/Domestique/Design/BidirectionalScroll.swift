import SwiftUI

/// Two-axis scroll view whose content is pinned top-leading and at least as large as the viewport.
struct BidirectionalScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                content
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
    }
}
