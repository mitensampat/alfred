import Foundation

// MARK: - Communication Training Models

struct CommunicationTraining: Codable {
    let version: String
    let description: String
    let userProfile: UserProfile
    let trainingExamples: [TrainingExample]
    let responsePatterns: [String: [String: String]]
    let toneIndicators: [String: ToneIndicator]
    let contextHints: [String: ContextHint]
    let personalizationRules: PersonalizationRules

    struct UserProfile: Codable {
        let communicationStyle: String
        let typicalResponseLength: String
        let usesEmojis: Bool
        let preferredGreeting: String?
        let preferredClosing: String?

        enum CodingKeys: String, CodingKey {
            case communicationStyle = "communication_style"
            case typicalResponseLength = "typical_response_length"
            case usesEmojis = "uses_emojis"
            case preferredGreeting = "preferred_greeting"
            case preferredClosing = "preferred_closing"
        }
    }

    struct TrainingExample: Codable {
        let category: String
        let incomingMessage: String
        let yourTypicalResponse: String
        let tone: String
        let context: String

        enum CodingKeys: String, CodingKey {
            case category
            case incomingMessage = "incoming_message"
            case yourTypicalResponse = "your_typical_response"
            case tone
            case context
        }
    }

    struct ToneIndicator: Codable {
        let keywords: [String]
        let formalityLevel: String

        enum CodingKeys: String, CodingKey {
            case keywords
            case formalityLevel = "formality_level"
        }
    }

    struct ContextHint: Codable {
        let keywords: [String]
        let suggestedResponseType: String

        enum CodingKeys: String, CodingKey {
            case keywords
            case suggestedResponseType = "suggested_response_type"
        }
    }

    struct PersonalizationRules: Codable {
        let neverUse: [String]
        let preferredPhrases: [String]
        let timeReferences: [String: String]

        enum CodingKeys: String, CodingKey {
            case neverUse = "never_use"
            case preferredPhrases = "preferred_phrases"
            case timeReferences = "time_references"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case description
        case userProfile = "user_profile"
        case trainingExamples = "training_examples"
        case responsePatterns = "response_patterns"
        case toneIndicators = "tone_indicators"
        case contextHints = "context_hints"
        case personalizationRules = "personalization_rules"
    }
}

// MARK: - Training Loader

class CommunicationTrainingLoader {
    static func load(from configPath: String = "Config/communication_training.json") -> CommunicationTraining? {
        let fileURL: URL

        // Try absolute path first
        if configPath.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: configPath)
        } else {
            // Try relative to current directory
            let currentDir = FileManager.default.currentDirectoryPath
            fileURL = URL(fileURLWithPath: currentDir).appendingPathComponent(configPath)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("⚠️  Communication training file not found at: \(fileURL.path)")
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let training = try JSONDecoder().decode(CommunicationTraining.self, from: data)
            return training
        } catch {
            print("⚠️  Failed to load communication training: \(error)")
            return nil
        }
    }

    /// Find similar training examples based on message content
    static func findSimilarExamples(
        for message: String,
        in training: CommunicationTraining,
        limit: Int = 3
    ) -> [CommunicationTraining.TrainingExample] {
        let messageLower = message.lowercased()

        // Score each training example by keyword overlap
        let scored = training.trainingExamples.map { example -> (example: CommunicationTraining.TrainingExample, score: Int) in
            let exampleLower = example.incomingMessage.lowercased()

            // Calculate similarity score
            var score = 0

            // Exact match bonus
            if exampleLower == messageLower {
                score += 100
            }

            // Keyword overlap
            let messageWords = Set(messageLower.split(separator: " ").map { String($0) })
            let exampleWords = Set(exampleLower.split(separator: " ").map { String($0) })
            score += messageWords.intersection(exampleWords).count * 5

            // Category-based matching
            for (contextName, hint) in training.contextHints {
                let hasContextKeyword = hint.keywords.contains { messageLower.contains($0.lowercased()) }
                if hasContextKeyword && example.context == contextName {
                    score += 10
                }
            }

            return (example, score)
        }

        // Return top N examples
        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.example }
    }

    /// Detect message category based on context hints
    static func detectCategory(
        for message: String,
        in training: CommunicationTraining
    ) -> String? {
        let messageLower = message.lowercased()

        for (category, hint) in training.contextHints {
            if hint.keywords.contains(where: { messageLower.contains($0.lowercased()) }) {
                return category
            }
        }

        return nil
    }

    /// Determine appropriate tone based on message content
    static func suggestTone(
        for message: String,
        in training: CommunicationTraining
    ) -> String {
        let messageLower = message.lowercased()

        for (tone, indicator) in training.toneIndicators {
            if indicator.keywords.contains(where: { messageLower.contains($0.lowercased()) }) {
                return tone
            }
        }

        return "professional-friendly"  // Default
    }
}
