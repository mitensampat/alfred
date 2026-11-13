import Foundation

/// The people you have pinned to the top of the People tab.
///
/// This is a pin and nothing else. It deliberately does NOT live in `favorites.json`, because that
/// list is *scan scope* — `AlfredService.scanCommitments` resolves `scanMode: "favorites"` straight
/// into `FavoritesService.getFavorites()`. Keeping pins in their own file means pinning someone can
/// never quietly widen what Alfred scans, and nobody reading the code later can mistake one for the
/// other. If you want Alfred to look harder at a person, that is the per-person rescan action, or
/// the favourites list in settings — not this.
///
/// Stored at `~/.alfred/pinned_people.json` as `{"names": ["Alex Carter", …]}`: hand-editable,
/// no schema, no tags.
final class PinnedPeopleStore {
    static let shared = PinnedPeopleStore()

    private struct Pins: Codable { var names: [String] = [] }

    private let filePath: String
    private let lock = NSLock()
    private var pins: Pins

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        filePath = AlfredPaths.data("pinned_people.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
           let loaded = try? JSONDecoder().decode(Pins.self, from: data) {
            pins = loaded
        } else {
            pins = Pins()
        }
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Pinned names in the form they were added, oldest first.
    func all() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return pins.names
    }

    func isPinned(_ name: String) -> Bool {
        let k = Self.key(name)
        lock.lock(); defer { lock.unlock() }
        return pins.names.contains { Self.key($0) == k }
    }

    /// Pin a person. Pinning someone already pinned is a no-op, not an error.
    func pin(_ name: String) throws {
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return }
        let k = Self.key(display)
        lock.lock()
        if pins.names.contains(where: { Self.key($0) == k }) { lock.unlock(); return }
        pins.names.append(display)
        let snapshot = pins
        lock.unlock()
        try write(snapshot)
    }

    func unpin(_ name: String) throws {
        let k = Self.key(name)
        lock.lock()
        pins.names.removeAll { Self.key($0) == k }
        let snapshot = pins
        lock.unlock()
        try write(snapshot)
    }

    private func write(_ snapshot: Pins) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: URL(fileURLWithPath: filePath))
    }
}
