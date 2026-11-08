import DQCore
import ServerKit
import SwiftUI
import UIKit

/// Colours shared with the Mac app's Theme (same values), plus iOS system surfaces.
enum Palette {
    static let accent = Color(red: 0.85, green: 0.47, blue: 0.34)  // Claude orange, the app's tint
    static let userBubble = dyn(light: 0x111111, dark: 0x3A3A3D)
    static let added = dyn(light: 0x1A7F37, dark: 0x3FB950)
    static let removed = dyn(light: 0xCF222E, dark: 0xF85149)
    static let addedBG = dyn(light: 0x1A7F37, dark: 0x3FB950, alpha: 0.12)
    static let removedBG = dyn(light: 0xCF222E, dark: 0xF85149, alpha: 0.12)
    static let warning = dyn(light: 0xD9480F, dark: 0xFF8A4C)
    static let running = dyn(light: 0x2F80ED, dark: 0x58A6FF)
    static let toolRead = dyn(light: 0x0E7C86, dark: 0x39C5CF)
    static let toolSearch = dyn(light: 0x8250DF, dark: 0xA371F7)
    static let toolWeb = dyn(light: 0xBF3989, dark: 0xF778BA)
    static let toolThought = dyn(light: 0x8C6D1F, dark: 0xD4A72C)
    static let codex = dyn(light: 0x111111, dark: 0xECECEE)

    static func provider(_ p: ProviderKind) -> Color { p == .claude ? accent : codex }

    private static func dyn(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(UIColor { t in
            let hex = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        })
    }
}

/// A session's provider mark: the Claude starburst or the Codex hexagon, as SF Symbols stand-ins.
struct ProviderBadge: View {
    let provider: ProviderKind
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: provider == .claude ? "asterisk" : "hexagon")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Palette.provider(provider))
            .accessibilityLabel(provider.displayName)
    }
}

/// Running / needs-input / idle, for workspace rows and chat pickers.
struct ActivityIndicator: View {
    let activity: Proto_SessionActivity

    var body: some View {
        switch activity {
        case .running:
            ProgressView().controlSize(.small).accessibilityLabel("Working")
        case .awaitingInput:
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Palette.warning)
                .accessibilityLabel("Needs your input")
        default:
            EmptyView()
        }
    }
}

struct StatusDot: View {
    let status: ServerConnection.Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch status {
        case .connected: Palette.added
        case .connecting: .yellow
        case .offline: Palette.removed
        }
    }

    private var label: String {
        switch status {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .offline(let why): "Offline: \(why)"
        }
    }
}
