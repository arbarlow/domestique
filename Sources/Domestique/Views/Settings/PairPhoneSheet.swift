import CoreImage
import CoreImage.CIFilterBuiltins
import DQCore
import ServerKit
import SwiftUI

/// Settings → Servers → Connect iPhone: makes a server reachable (This Mac only), mints an `operate` token
/// and shows it as a QR code the iPhone's Camera opens in Domestique. The secret lives only in this sheet.
struct PairPhoneSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let link: ServerLink

    @State private var addresses: [LocalServer.NetworkAddress] = []
    @State private var selectedIP: String?
    @State private var pairingLink: PairingLink?
    @State private var tokens: [Proto_TokenInfo] = []
    @State private var working: String?
    @State private var error: String?
    @State private var confirmRestart = false
    @State private var copied = false

    private struct PairingLink {
        var url: String
        var link: String
        var image: CGImage?
    }

    private var busyAgents: Int { link.activity.values.filter { $0 == .running || $0 == .awaitingInput }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an iPhone to \(link.displayName)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            if let pairingLink {
                codeView(pairingLink)
            } else {
                setupView
            }
            if let error {
                Text(error).font(Theme.small).foregroundStyle(Theme.removed).fixedSize(horizontal: false, vertical: true)
            }
            if !tokens.isEmpty { pairedPhones }
            HStack {
                if link.isLocal, app.settings.phoneAccessAddress != nil, pairingLink == nil {
                    Button("Stop Listening") { stopListening() }.disabled(working != nil || busyAgents > 0)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            addresses = LocalServer.networkAddresses()
            selectedIP = app.settings.phoneAccessAddress.flatMap { ip in addresses.first { $0.ip == ip }?.ip } ?? addresses.first?.ip
            await loadTokens()
        }
        .confirmationDialog("Restart This Mac's server?", isPresented: $confirmRestart) {
            Button("Restart and Stop Agents", role: .destructive) { generate(allowRestart: true) }
        } message: {
            Text("It has to restart to listen on the network, which stops \(busyAgents) working agent\(busyAgents == 1 ? "" : "s").")
        }
    }

    @ViewBuilder private var setupView: some View {
        if link.isLocal {
            if addresses.isEmpty {
                Text("This Mac has no Tailscale or local network address. Connect to Tailscale or Wi-Fi, then reopen this.")
                    .font(Theme.ui).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Reach this Mac over", selection: $selectedIP) {
                    ForEach(addresses) { a in
                        Text(a.kind == .tailscale ? "Tailscale · \(a.ip)" : "Local network · \(a.ip)").tag(Optional(a.ip))
                    }
                }
                Text(selectedIsLAN
                    ? "Traffic on the local network is not encrypted, including the token and your code. Prefer Tailscale."
                    : "Your phone needs to be on the same tailnet. Server will listen on this address on port \(String(LocalServer.networkPort)) and require a token.")
                    .font(Theme.small).foregroundStyle(selectedIsLAN ? Theme.warning : Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                if !app.settings.keepServerRunning {
                    Text("The phone can only connect while Domestique is open, unless you turn on Keep running after Domestique quits.")
                        .font(Theme.small).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if case .remote(let cfg) = link.server {
            Text("The phone will connect to \(cfg.url), so it needs to be able to reach that address.")
                .font(Theme.ui).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            Button("Generate QR Code") { generate(allowRestart: false) }
                .buttonStyle(.borderedProminent)
                .disabled(working != nil || (link.isLocal && selectedIP == nil))
            if let working {
                ProgressView().controlSize(.small)
                Text(working).font(Theme.small).foregroundStyle(Theme.text3)
            }
        }
    }

    private var selectedIsLAN: Bool { addresses.first { $0.ip == selectedIP }?.kind == .lan }

    private func codeView(_ p: PairingLink) -> some View {
        VStack(spacing: 12) {
            if let image = p.image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
            }
            Text("Point the iPhone's Camera at this code and open it in Domestique, then tap Connect.")
                .font(Theme.ui).foregroundStyle(Theme.text2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text(p.url).font(Theme.small.monospaced()).foregroundStyle(Theme.text3)
            Button(copied ? "Copied" : "Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(p.link, forType: .string)
                copied = true
            }
            .buttonStyle(.softCompact)
            Text("Anyone with this code can run commands on this server. It's shown only here; revoke it below if it gets out.")
                .font(Theme.small).foregroundStyle(Theme.warning).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var pairedPhones: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paired phones").font(Theme.uiMedium).foregroundStyle(Theme.text)
            ForEach(tokens, id: \.id) { t in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.name).font(Theme.ui).foregroundStyle(Theme.text)
                        Text(t.lastUsedAtMs > 0 ? "Last used \(Date(protoMs: t.lastUsedAtMs).formatted(.relative(presentation: .named)))" : "Never used")
                            .font(Theme.small).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Button("Revoke") { revoke(t.id) }.buttonStyle(.softCompact)
                }
            }
        }
    }

    // MARK: Actions

    private func loadTokens() async {
        guard let c = try? await link.ready(), let all = try? await c.listTokens() else { return }
        tokens = all.filter { $0.name.lowercased().hasPrefix("iphone") }
    }

    private func revoke(_ id: String) {
        Task {
            do {
                try await link.ready().revokeToken(id: id)
                await loadTokens()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func stopListening() {
        app.settings.phoneAccessAddress = nil
        working = "Restarting server…"
        Task {
            await link.restart()
            working = nil
        }
    }

    private func generate(allowRestart: Bool) {
        error = nil
        Task {
            defer { working = nil }
            do {
                try await pair(allowRestart: allowRestart)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func pair(allowRestart: Bool) async throws {
        let url: String
        switch link.server {
        case .local:
            guard let ip = selectedIP else { return }
            url = "ws://\(ip):\(LocalServer.networkPort)"
            let previous = app.settings.phoneAccessAddress
            working = "Checking the address…"
            if await !answers(url) {
                if busyAgents > 0, !allowRestart {
                    confirmRestart = true
                    return
                }
                app.settings.phoneAccessAddress = ip
                working = "Restarting server…"
                await link.restart()
                _ = try await link.ready()
                if await !answers(url) {
                    app.settings.phoneAccessAddress = previous
                    throw ServerError(code: .unavailable, message: "Server couldn't listen on \(ip):\(LocalServer.networkPort). The port may be in use; see Show Log on This Mac's card.")
                }
            }
            app.settings.phoneAccessAddress = ip
        case .remote(let cfg):
            url = cfg.url
        }

        working = "Creating a token…"
        let client = try await link.ready()
        let name = "iphone-\(Date.now.formatted(.iso8601.year().month().day()))"
        let created = try await client.createToken(name: name, scope: .operate)

        // Prove the phone's route end to end, and that it reaches this server rather than another on the port.
        if link.isLocal {
            do {
                let welcome = try await hello(url, token: created.secret)
                if welcome.serverID != link.welcome?.serverID {
                    throw ServerError(code: .failedPrecondition, message: "Another server is answering on \(url).")
                }
            } catch {
                try? await client.revokeToken(id: created.info.id)
                throw error
            }
        }

        var c = URLComponents()
        c.scheme = "domestique"
        c.host = "add-server"
        c.queryItems = [
            .init(name: "url", value: url), .init(name: "token", value: created.secret), .init(name: "name", value: link.displayName),
        ]
        guard let string = c.string else { return }
        pairingLink = PairingLink(url: url, link: string, image: Self.qrCode(string))
        await loadTokens()
    }

    /// Whether anything speaks the Domestique protocol there. A refused handshake (no token) still counts as an answer.
    private func answers(_ url: String) async -> Bool {
        do {
            _ = try await hello(url, token: "")
            return true
        } catch let e as ServerError {
            return e.code != .unavailable
        } catch {
            return false
        }
    }

    private func hello(_ url: String, token: String) async throws -> Proto_Welcome {
        guard let u = URL(string: url) else { throw ServerError(code: .invalidArgument, message: "Bad URL \(url)") }
        let c = ServerClient(endpoint: .url(u), token: token, clientName: "Domestique for Mac (pairing)", clientID: ServerLink.clientID)
        defer { Task { await c.close() } }
        return try await c.connect()
    }

    private static func qrCode(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        // Scaled up here so the modules stay crisp at any display size.
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
