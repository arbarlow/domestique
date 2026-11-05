import Foundation

struct FileNode: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var children: [FileNode]?

    static func tree(from paths: [String]) -> [FileNode] {
        final class Builder {
            var dirs: [String: Builder] = [:]
            var files: [String] = []
        }
        let root = Builder()
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            var node = root
            for dir in parts.dropLast() {
                if let next = node.dirs[dir] {
                    node = next
                } else {
                    let next = Builder()
                    node.dirs[dir] = next
                    node = next
                }
            }
            if let file = parts.last { node.files.append(file) }
        }
        func build(_ b: Builder, prefix: String) -> [FileNode] {
            let dirs = b.dirs.keys.sorted().map { name -> FileNode in
                let p = prefix.isEmpty ? name : "\(prefix)/\(name)"
                return FileNode(name: name, path: p, children: build(b.dirs[name]!, prefix: p))
            }
            let files = b.files.sorted().map { name in
                FileNode(name: name, path: prefix.isEmpty ? name : "\(prefix)/\(name)", children: nil)
            }
            return dirs + files
        }
        return build(root, prefix: "")
    }
}
