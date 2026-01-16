import SwiftUI


struct NotionTodosView: View {
    @ObservedObject var viewModel: MainMenuViewModel
    @State private var isScanning = false
    @State private var foundTodos: [TodoItemPreview] = []
    @State private var scanComplete = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    viewModel.navigateBack()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SlackTheme.primaryText)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Text("SCAN FOR TODOS")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(SlackTheme.primaryText)
                    .tracking(1.5)

                Spacer()

                // Invisible spacer for centering
                Image(systemName: "chevron.left")
                    .font(.system(size: 16))
                    .opacity(0)
            }
            .padding(.horizontal, SlackTheme.paddingMedium)
            .padding(.top, SlackTheme.paddingLarge)
            .padding(.bottom, SlackTheme.paddingMedium)

            if !isScanning && !scanComplete {
                // Initial state
                VStack(spacing: SlackTheme.paddingLarge) {
                    Spacer()

                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(SlackTheme.accentPrimary)

                    VStack(spacing: 8) {
                        Text("Scan WhatsApp Messages")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(SlackTheme.primaryText)

                        Text("I'll check messages you sent to yourself\nand create todos in Notion")
                            .font(.system(size: 13))
                            .foregroundColor(SlackTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                    }

                    Button(action: {
                        startScanning()
                    }) {
                        Text("START SCAN")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(SlackTheme.primaryBackground)
                            .tracking(1)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(SlackTheme.accentPrimary)
                            .cornerRadius(SlackTheme.cornerRadiusMedium)
                    }
                    .buttonStyle(PlainButtonStyle())

                    Spacer()
                }
            } else if isScanning {
                // Scanning state
                VStack(spacing: SlackTheme.paddingLarge) {
                    Spacer()

                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(SlackTheme.accentPrimary)

                    VStack(spacing: 8) {
                        Text("Scanning Messages...")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(SlackTheme.primaryText)

                        Text("analyzing your notes")
                            .font(.system(size: 13))
                            .foregroundColor(SlackTheme.secondaryText)
                    }

                    Spacer()
                }
            } else {
                // Results state
                ScrollView {
                    VStack(alignment: .leading, spacing: SlackTheme.paddingMedium) {
                        HStack {
                            Text("FOUND \(foundTodos.count) TODOS")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(SlackTheme.secondaryText)
                                .tracking(1)

                            Spacer()

                            Button(action: {
                                createNotionTodos()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 12))

                                    Text("CREATE ALL")
                                        .font(.system(size: 11, weight: .bold))
                                        .tracking(0.5)
                                }
                                .foregroundColor(SlackTheme.accentPrimary)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        ForEach(foundTodos) { todo in
                            TodoPreviewCard(todo: todo)
                        }

                        Button(action: {
                            // Reset
                            scanComplete = false
                            foundTodos = []
                        }) {
                            Text("SCAN AGAIN")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(SlackTheme.accentPrimary)
                                .tracking(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white)
                                .cornerRadius(SlackTheme.cornerRadiusSmall)
                                .overlay(
                                    RoundedRectangle(cornerRadius: SlackTheme.cornerRadiusSmall)
                                        .stroke(SlackTheme.accentPrimary, lineWidth: 1)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(SlackTheme.paddingMedium)
                }
            }
        }
    }

    private func startScanning() {
        isScanning = true
        errorMessage = nil

        Task {
            do {
                let todos = try await viewModel.alfredService.scanWhatsAppForTodos()

                await MainActor.run {
                    foundTodos = todos.map { todo in
                        TodoItemPreview(
                            title: todo.title,
                            description: todo.description,
                            dueDate: formatDueDate(todo.dueDate)
                        )
                    }
                    isScanning = false
                    scanComplete = true

                    if foundTodos.isEmpty {
                        errorMessage = "No todos found in your WhatsApp messages to yourself"
                    }
                }
            } catch {
                await MainActor.run {
                    isScanning = false
                    scanComplete = false
                    errorMessage = "Error scanning messages: \(error.localizedDescription)"
                }
            }
        }
    }

    private func formatDueDate(_ date: Date?) -> String? {
        guard let date = date else { return nil }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        }
    }

    private func createNotionTodos() {
        // Todos are already created in Notion by the scan process
        print("Todos already created in Notion during scan")
    }
}

struct TodoItemPreview: Identifiable {
    let id = UUID()
    let title: String
    let description: String?
    let dueDate: String?
}

struct TodoPreviewCard: View {
    let todo: TodoItemPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(todo.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SlackTheme.primaryText)

            if let description = todo.description {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(SlackTheme.secondaryText)
                    .lineSpacing(2)
            }

            if let dueDate = todo.dueDate {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundColor(SlackTheme.accentPrimary)

                    Text(dueDate.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(SlackTheme.accentPrimary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(SlackTheme.accentPrimary.opacity(0.1))
                .cornerRadius(4)
            }
        }
        .padding(SlackTheme.paddingSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(SlackTheme.cornerRadiusSmall)
        .shadow(color: SlackTheme.shadowColor, radius: 2, x: 0, y: 1)
    }
}
