import Foundation

/// The temp store's file rules (D-18, D-20). Permissions only, never the Locked flag: it blocks chmod and delete
/// (RESEARCH Pitfall 15).
public enum PreviewFiles {
    /// A landed copy: the file 0444 and its folder 0555, so a document app's save over it fails (513) and neither a
    /// safe-save temp nor an Unlock that only touches the file can get around it (D-18, RESEARCH S7).
    public static func makeReadOnly(_ file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: file.deletingLastPathComponent().path)
    }

    /// Deletes `folder` and everything in it, read-only copies included: every directory in the tree gets u+w first,
    /// or a 0555 folder couldn't lose its file (Pitfall 15). Absent → nothing. Links are deleted, never followed: only
    /// real directories are chmodded, and the walk doesn't descend through links.
    public static func removeAll(at folder: URL) {
        let fm = FileManager.default
        func isDirectory(_ url: URL) -> Bool {      // lstat: a link to a folder is not one
            (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
        }
        guard (try? fm.attributesOfItem(atPath: folder.path)) != nil else { return }
        if isDirectory(folder) {
            chmod(folder.path, 0o755)
            let walk = fm.enumerator(at: folder, includingPropertiesForKeys: nil)
            while let url = walk?.nextObject() as? URL {
                if isDirectory(url) { chmod(url.path, 0o755) }
            }
        }
        try? fm.removeItem(at: folder)
    }

    /// The children of `parent` left by launches that are gone: a name that isn't a process id, or names a process
    /// `isAlive` says has exited. A running instance's folder is never among them (D-20).
    public static func staleLaunchFolders(in parent: URL, isAlive: (Int32) -> Bool) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.filter { name in Int32(name).map { $0 <= 0 || !isAlive($0) } ?? true }
            .map { parent.appending(component: $0) }
    }
}
