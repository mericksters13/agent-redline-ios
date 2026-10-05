#if os(macOS)
import Foundation

/// The folder holding `.git` above a path: the worktree, which is what tells chats apart.
enum Worktree {
    static func root(of path: String) -> String {
        let files = FileManager.default
        var folder = URL(filePath: path).standardizedFileURL
        var isFolder: ObjCBool = false
        if !files.fileExists(atPath: folder.path, isDirectory: &isFolder) || !isFolder.boolValue
            || folder.pathExtension == "xcodeproj"
        {
            folder = folder.deletingLastPathComponent()
        }
        var candidate = folder
        while candidate.path != "/" {
            if files.fileExists(atPath: candidate.appending(path: ".git").path) { return candidate.path }
            candidate = candidate.deletingLastPathComponent()
        }
        return folder.path
    }
}
#endif
