// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Alfred",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "alfred",
            targets: ["Alfred"]
        )
        // Desktop app removed - use web interface instead
    ],
    dependencies: [
        // No external dependencies needed - using Foundation and URLSession
    ],
    targets: [
        .executableTarget(
            name: "Alfred",
            dependencies: [],
            path: "Sources",
            exclude: [
                "GUI/Views",
                "GUI/Models",
                "GUI/Core",
                "GUI/AlfredMenuBarApp.swift.disabled",
                "GUI/AlfredMenuBarApp.swift.backup",
                // Exclude duplicate service files from GUI (use CLI versions instead)
                "GUI/Services/AlfredService.swift",
                "GUI/Services/ClaudeAIService.swift",
                "GUI/Services/CommitmentAnalyzer.swift",
                "GUI/Services/GoogleCalendarService.swift",
                "GUI/Services/HTTPServer.swift",
                "GUI/Services/IntentExecutor.swift",
                "GUI/Services/IntentRecognitionService.swift",
                "GUI/Services/MultiCalendarService.swift",
                "GUI/Services/NotificationService.swift",
                "GUI/Services/NotionService+Tasks.swift",
                "GUI/Services/NotionService.swift",
                "GUI/Services/ResearchService.swift",
                "GUI/Services/MessageReaders"
            ],
            resources: [
                .copy("GUI/Resources")
            ]
        )
    ]
)
