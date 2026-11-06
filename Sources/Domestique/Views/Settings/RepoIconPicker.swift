import DQCore
import SwiftUI
import UniformTypeIdentifiers

/// Icon editor for a repository: monogram / symbol / emoji / image, plus colour.
struct RepoIconPicker: View {
    @Environment(AppModel.self) private var app
    let repo: Repository
    @State private var candidates: [String] = []
    @State private var scanning = false
    @State private var fetchingAvatar = false
    @State private var emoji = ""

    private var icon: RepoIcon { repo.icon ?? RepoIcon(kind: .monogram) }

    var body: some View {
        SettingsSection(title: "Icon") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(RepoIcon.Kind.allCases, id: \.self) { kind in
                        PillTab(title: title(kind), selected: icon.kind == kind) { setKind(kind) }
                    }
                }
                switch icon.kind {
                case .monogram:
                    swatches
                case .symbol:
                    symbolGrid
                    swatches
                case .emoji:
                    HStack(spacing: 8) {
                        TextField("Emoji", text: $emoji)
                            .textFieldStyle(.plain)
                            .font(.system(size: 18))
                            .frame(width: 60, height: 32)
                            .multilineTextAlignment(.center)
                            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 0.5))
                            .onChange(of: emoji) { _, v in
                                guard let first = v.first else { return }
                                update { $0.emoji = String(first) }
                                if v.count > 1 { emoji = String(first) }
                            }
                        Text("Type or press ⌃⌘Space for the emoji picker")
                            .font(Theme.small)
                            .foregroundStyle(Theme.text3)
                    }
                    .onAppear { emoji = icon.emoji ?? "" }
                case .image:
                    imageOptions
                }
            }
            .padding(14)
        }
    }

    // MARK: pieces

    private var swatches: some View {
        HStack(spacing: 8) {
            ForEach(RepoIconStyle.palette, id: \.self) { hex in
                let selected = (icon.colorHex ?? "") == hex
                Circle()
                    .fill(Color(hex: hex) ?? .gray)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))  // keeps dark swatches visible on dark cards
                    .overlay(Circle().strokeBorder(Theme.text, lineWidth: selected ? 2 : 0).padding(-3))
                    .contentShape(Circle())
                    .onTapGesture { update { $0.colorHex = hex } }
            }
            Button("Auto") { update { $0.colorHex = nil } }
                .buttonStyle(.softCompact)
        }
        .padding(.vertical, 2)
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 12), spacing: 6) {
            ForEach(RepoIconStyle.symbols, id: \.self) { name in
                let selected = icon.symbol == name
                Image(systemName: name)
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.text : Theme.text2)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.selected : Theme.hover.opacity(0.6)))
                    .contentShape(Rectangle())
                    .onTapGesture { update { $0.symbol = name } }
            }
        }
    }

    private var imageOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("Choose image…") { chooseFile() }.buttonStyle(.soft)
                if let slug = repo.githubSlug {
                    Button {
                        fetchingAvatar = true
                        Task {
                            if let file = await RepoIconStore.githubAvatar(slug: slug) { setImage(file) }
                            fetchingAvatar = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if fetchingAvatar { Spinner(size: 10) }
                            Text("Use GitHub avatar")
                        }
                    }
                    .buttonStyle(.soft)
                }
                Button {
                    scanning = true
                    Task {
                        candidates = await RepoIconStore.candidates(in: repo.path)
                        scanning = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if scanning { Spinner(size: 10) }
                        Text("Find in repo")
                    }
                }
                .buttonStyle(.soft)
            }
            if !candidates.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 10), count: 8), spacing: 10) {
                    ForEach(candidates, id: \.self) { rel in
                        let url = URL(fileURLWithPath: repo.path + "/" + rel)
                        VStack(spacing: 3) {
                            if let img = NSImage(contentsOf: url) {
                                Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .frame(width: 56, height: 56)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.hover))
                        .help(rel)
                        .contentShape(Rectangle())
                        .onTapGesture { if let file = RepoIconStore.importFile(url) { setImage(file) } }
                    }
                }
            } else if !scanning {
                Text("Pick a file, your GitHub avatar, or an app icon / logo already in the repo.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.text3)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, let file = RepoIconStore.importFile(url) else { return false }
            setImage(file)
            return true
        }
    }

    // MARK: actions

    private func title(_ k: RepoIcon.Kind) -> String {
        switch k {
        case .monogram: "Letter"
        case .symbol: "Symbol"
        case .emoji: "Emoji"
        case .image: "Image"
        }
    }

    private func setKind(_ kind: RepoIcon.Kind) {
        update { icon in
            icon.kind = kind
            if kind == .symbol, icon.symbol == nil { icon.symbol = "folder.fill" }
            if kind == .emoji, icon.emoji == nil { icon.emoji = "🚲" }
        }
        if kind == .emoji { emoji = repo.icon?.emoji ?? "🚲" }
    }

    private func setImage(_ file: String) {
        update {
            $0.kind = .image
            $0.imageFile = file
        }
    }

    private func update(_ mutate: (inout RepoIcon) -> Void) {
        app.updateRepo(repo.id) { r in
            var icon = r.icon ?? RepoIcon(kind: .monogram)
            mutate(&icon)
            r.icon = icon
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let file = RepoIconStore.importFile(url) else { return }
        setImage(file)
    }
}
