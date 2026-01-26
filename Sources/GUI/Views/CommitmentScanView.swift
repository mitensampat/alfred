import SwiftUI

struct CommitmentScanView: View {
    @ObservedObject var viewModel: MainMenuViewModel
    @Environment(\.presentationMode) var presentationMode
    let onComplete: () -> Void

    @State private var contactName: String = ""
    @State private var lookbackDays: Int = 14
    @State private var isScanning: Bool = false
    @State private var scanResults: ScanResults?
    @State private var errorMessage: String?

    struct ScanResults {
        let found: Int
        let saved: Int
        let duplicates: Int
    }

    var body: some View {
        ZStack {
            SlackTheme.surfaceBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                headerView
                    .padding(.vertical, SlackTheme.paddingMedium)
                    .background(SlackTheme.primaryBackground)

                ScrollView {
                    VStack(spacing: SlackTheme.paddingMedium) {
                        if isScanning {
                            scanningView
                        } else if let results = scanResults {
                            resultsView(results)
                        } else {
                            inputView
                        }
                    }
                    .padding(SlackTheme.paddingMedium)
                }

                Spacer()
            }
        }
        .frame(width: 500, height: 400)
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan for Commitments")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(SlackTheme.inverseText)

                if !isScanning {
                    Text("Extract commitments from messages")
                        .font(.system(size: 11))
                        .foregroundColor(SlackTheme.inverseText.opacity(0.7))
                }
            }

            Spacer()

            Button(action: {
                presentationMode.wrappedValue.dismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SlackTheme.inverseText)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, SlackTheme.paddingMedium)
    }

    private var inputView: some View {
        VStack(alignment: .leading, spacing: SlackTheme.paddingMedium) {
            // Contact name input
            VStack(alignment: .leading, spacing: 6) {
                Text("Contact Name (optional)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(SlackTheme.secondaryText)

                TextField("Leave empty to scan all configured contacts", text: $contactName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 12))

                Text("Examples: \"Kunal Shah\", \"Akshay Aedula\"")
                    .font(.system(size: 10))
                    .foregroundColor(SlackTheme.tertiaryText)
            }

            // Lookback period
            VStack(alignment: .leading, spacing: 6) {
                Text("Lookback Period")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(SlackTheme.secondaryText)

                HStack {
                    Stepper("\(lookbackDays) days", value: $lookbackDays, in: 1...90)
                        .font(.system(size: 12))

                    Spacer()
                }

                Text("Recommended: 7-14 days for recent commitments")
                    .font(.system(size: 10))
                    .foregroundColor(SlackTheme.tertiaryText)
            }

            if let error = errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 11))
                }
                .foregroundColor(SlackTheme.accentDanger)
                .padding(SlackTheme.paddingSmall)
                .background(SlackTheme.accentDanger.opacity(0.1))
                .cornerRadius(SlackTheme.cornerRadiusSmall)
            }

            // Scan button
            Button(action: startScan) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Start Scan")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(SlackTheme.accentPrimary)
                .cornerRadius(SlackTheme.cornerRadiusSmall)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, SlackTheme.paddingSmall)
        }
    }

    private var scanningView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: SlackTheme.accentPrimary))
                .scaleEffect(1.5)

            VStack(spacing: 8) {
                Text("Scanning Messages")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SlackTheme.primaryText)

                Text(contactName.isEmpty ? "Scanning all configured contacts..." : "Scanning \(contactName)...")
                    .font(.system(size: 11))
                    .foregroundColor(SlackTheme.secondaryText)

                Text("Looking back \(lookbackDays) days")
                    .font(.system(size: 10))
                    .foregroundColor(SlackTheme.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultsView(_ results: ScanResults) -> some View {
        VStack(spacing: SlackTheme.paddingMedium) {
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(SlackTheme.accentSuccess)

            // Results
            VStack(spacing: 12) {
                Text("Scan Complete!")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(SlackTheme.primaryText)

                VStack(spacing: 8) {
                    ResultRow(label: "Commitments found", value: "\(results.found)", icon: "magnifyingglass.circle.fill")
                    ResultRow(label: "New commitments saved", value: "\(results.saved)", icon: "arrow.down.circle.fill", color: SlackTheme.accentSuccess)
                    if results.duplicates > 0 {
                        ResultRow(label: "Duplicates skipped", value: "\(results.duplicates)", icon: "doc.on.doc", color: SlackTheme.tertiaryText)
                    }
                }
            }

            // Done button
            Button(action: {
                onComplete()
                presentationMode.wrappedValue.dismiss()
            }) {
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(SlackTheme.accentPrimary)
                    .cornerRadius(SlackTheme.cornerRadiusSmall)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(SlackTheme.paddingMedium)
    }

    private func startScan() {
        isScanning = true
        errorMessage = nil

        Task {
            do {
                let results = try await viewModel.alfredService.scanCommitments(
                    contactName: contactName.isEmpty ? nil : contactName,
                    lookbackDays: lookbackDays
                )

                await MainActor.run {
                    self.scanResults = ScanResults(
                        found: results.totalFound,
                        saved: results.saved,
                        duplicates: results.duplicates
                    )
                    self.isScanning = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isScanning = false
                }
            }
        }
    }
}

// MARK: - Result Row Component
struct ResultRow: View {
    let label: String
    let value: String
    let icon: String
    var color: Color = SlackTheme.accentPrimary

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
                .frame(width: 20)

            Text(label)
                .font(.system(size: 12))
                .foregroundColor(SlackTheme.secondaryText)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SlackTheme.primaryText)
        }
    }
}
