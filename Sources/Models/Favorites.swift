import Foundation

/// Favorites - priority contacts and groups that get special attention across all features
struct Favorites: Codable {
    var contacts: [FavoriteContact]
    var groups: [FavoriteGroup]

    init(contacts: [FavoriteContact] = [], groups: [FavoriteGroup] = []) {
        self.contacts = contacts
        self.groups = groups
    }

    /// Check if a contact name is a favorite
    func isContactFavorite(_ name: String) -> Bool {
        contacts.contains { contact in
            contact.name.lowercased() == name.lowercased() ||
            contact.aliases.contains { $0.lowercased() == name.lowercased() }
        }
    }

    /// Check if a group name is a favorite
    func isGroupFavorite(_ name: String) -> Bool {
        groups.contains { group in
            group.name.lowercased() == name.lowercased() ||
            group.aliases.contains { $0.lowercased() == name.lowercased() }
        }
    }

    /// Check if any name (contact or group) is a favorite
    func isFavorite(_ name: String) -> Bool {
        isContactFavorite(name) || isGroupFavorite(name)
    }

    /// Get all favorite names (for filtering)
    var allNames: [String] {
        var names: [String] = []
        for contact in contacts {
            names.append(contact.name)
            names.append(contentsOf: contact.aliases)
        }
        for group in groups {
            names.append(group.name)
            names.append(contentsOf: group.aliases)
        }
        return names
    }
}

struct FavoriteContact: Codable, Identifiable {
    var id: String { name }
    let name: String
    var aliases: [String]
    var platforms: [String]  // ["whatsapp", "imessage", "email"]
    var notes: String?
    var addedAt: Date

    init(name: String, aliases: [String] = [], platforms: [String] = ["whatsapp", "imessage"], notes: String? = nil) {
        self.name = name
        self.aliases = aliases
        self.platforms = platforms
        self.notes = notes
        self.addedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case name
        case aliases
        case platforms
        case notes
        case addedAt = "added_at"
    }
}

struct FavoriteGroup: Codable, Identifiable {
    var id: String { name }
    let name: String
    var aliases: [String]
    var platform: String  // "whatsapp", "imessage"
    var notes: String?
    var addedAt: Date

    init(name: String, aliases: [String] = [], platform: String = "whatsapp", notes: String? = nil) {
        self.name = name
        self.aliases = aliases
        self.platform = platform
        self.notes = notes
        self.addedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case name
        case aliases
        case platform
        case notes
        case addedAt = "added_at"
    }
}

// MARK: - Persistence

class FavoritesService {
    static let shared = FavoritesService()

    private let filePath: String
    private var favorites: Favorites

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        filePath = "\(homeDir)/.alfred/favorites.json"

        // Load existing favorites or create empty
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601  // Match the encoding strategy used in save()

        if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
           let loaded = try? decoder.decode(Favorites.self, from: data) {
            favorites = loaded
            print("✓ Loaded \(favorites.contacts.count) favorite contacts and \(favorites.groups.count) favorite groups")
        } else {
            favorites = Favorites()
            print("ℹ Starting with empty favorites (no existing file or parse error)")
        }
    }

    func getFavorites() -> Favorites {
        return favorites
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(favorites)
        try data.write(to: URL(fileURLWithPath: filePath))
    }

    // MARK: - Contacts

    func addContact(_ contact: FavoriteContact) throws {
        // Check for duplicates
        if favorites.contacts.contains(where: { $0.name.lowercased() == contact.name.lowercased() }) {
            throw FavoritesError.duplicateEntry
        }
        favorites.contacts.append(contact)
        try save()
    }

    func removeContact(name: String) throws {
        favorites.contacts.removeAll { $0.name.lowercased() == name.lowercased() }
        try save()
    }

    func updateContact(_ contact: FavoriteContact) throws {
        if let index = favorites.contacts.firstIndex(where: { $0.name.lowercased() == contact.name.lowercased() }) {
            favorites.contacts[index] = contact
            try save()
        } else {
            throw FavoritesError.notFound
        }
    }

    // MARK: - Groups

    func addGroup(_ group: FavoriteGroup) throws {
        // Check for duplicates
        if favorites.groups.contains(where: { $0.name.lowercased() == group.name.lowercased() }) {
            throw FavoritesError.duplicateEntry
        }
        favorites.groups.append(group)
        try save()
    }

    func removeGroup(name: String) throws {
        favorites.groups.removeAll { $0.name.lowercased() == name.lowercased() }
        try save()
    }

    func updateGroup(_ group: FavoriteGroup) throws {
        if let index = favorites.groups.firstIndex(where: { $0.name.lowercased() == group.name.lowercased() }) {
            favorites.groups[index] = group
            try save()
        } else {
            throw FavoritesError.notFound
        }
    }

    // MARK: - Queries

    func isContactFavorite(_ name: String) -> Bool {
        return favorites.isContactFavorite(name)
    }

    func isGroupFavorite(_ name: String) -> Bool {
        return favorites.isGroupFavorite(name)
    }

    func isFavorite(_ name: String) -> Bool {
        return favorites.isFavorite(name)
    }
}

enum FavoritesError: Error, LocalizedError {
    case duplicateEntry
    case notFound

    var errorDescription: String? {
        switch self {
        case .duplicateEntry:
            return "This favorite already exists"
        case .notFound:
            return "Favorite not found"
        }
    }
}
