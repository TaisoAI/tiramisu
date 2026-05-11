import Foundation

/// Persists security-scoped bookmarks so files on external volumes / iCloud
/// Drive / Documents stay accessible after the panel-granted scope dies
/// (panel scope = lifetime of the NSOpenPanel/NSSavePanel pick + current
/// process). Required for sandbox apps to reopen recents and save back to
/// `currentFileURL` after a restart.
enum FileBookmarks {
    private static let prefix = "ai.taiso.tiramisu.bookmark."

    /// Capture and store a security-scoped bookmark for a URL the user just
    /// picked (open / save panel result).
    static func store(for url: URL) {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
            UserDefaults.standard.set(data, forKey: prefix + url.path)
        } catch {
            tlog("FileBookmarks.store failed for \(url.path): \(error)")
        }
    }

    /// Resolve a previously stored bookmark back to a URL. Returns nil if no
    /// bookmark, file is gone, or the bookmark can't be resolved. Refreshes
    /// stale bookmarks transparently.
    static func resolve(path: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: prefix + path) else { return nil }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            if stale {
                if let refreshed = try? url.bookmarkData(options: [.withSecurityScope],
                                                          includingResourceValuesForKeys: nil,
                                                          relativeTo: nil) {
                    UserDefaults.standard.set(refreshed, forKey: prefix + url.path)
                }
            }
            return url
        } catch {
            tlog("FileBookmarks.resolve failed for \(path): \(error)")
            return nil
        }
    }

    static func remove(path: String) {
        UserDefaults.standard.removeObject(forKey: prefix + path)
    }

    /// Run `body` with the URL's security scope started, ensuring it's stopped
    /// afterwards. Safe to call on URLs that don't need scope — `startAccessing…`
    /// returns false and we skip the stop.
    @discardableResult
    static func withScope<T>(_ url: URL, _ body: (URL) throws -> T) rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
}
