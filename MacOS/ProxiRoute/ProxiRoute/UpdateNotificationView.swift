import SwiftUI
import Combine

struct UpdateNotificationView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss
    let versionInfo: VersionInfo
    @StateObject private var viewModel: UpdateNotificationViewModel
    
    init(versionInfo: VersionInfo) {
        self.versionInfo = versionInfo
        _viewModel = StateObject(wrappedValue: UpdateNotificationViewModel(versionInfo: versionInfo))
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Icon and Title
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)
                
                Text(L10n.t("Update Available"))
                    .font(.title2)
                    .fontWeight(.bold)
            }
            
            Divider()
            
            // Version Information
            VStack(spacing: 10) {
                HStack {
                    Text(L10n.t("Current Version:"))
                        .fontWeight(.medium)
                    Spacer()
                    Text(versionInfo.currentVersion)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text(L10n.t("New Version:"))
                        .fontWeight(.medium)
                    Spacer()
                    Text(versionInfo.latestVersion)
                        .foregroundColor(.green)
                        .fontWeight(.semibold)
                }
            }
            .padding(.horizontal)
            
            Text(L10n.t("A new version of ProxiRoute is available!"))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if let notes = versionInfo.releaseNotesUrl, let url = URL(string: notes) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                        Text(L10n.t("View Release Notes"))
                    }
                }
            }
            
            // Download Progress
            if viewModel.isDownloading {
                VStack(spacing: 8) {
                    ProgressView(value: viewModel.downloadProgress, total: 1.0)
                        .progressViewStyle(.linear)
                    Text(viewModel.downloadStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            }
            
            // Error Message
            if viewModel.hasError {
                Text(viewModel.errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            Spacer()
            
            // Action Buttons
            if !viewModel.isDownloading {
                HStack(spacing: 12) {
                    Button(L10n.t("Don't Ask Again")) {
                        viewModel.dontAskAgain()
                        dismiss()
                    }
                    
                    Button(L10n.t("Later")) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    
                    Button(L10n.t("Update Now")) {
                        Task {
                            await viewModel.downloadAndInstall()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                }
            } else {
                Button(L10n.t("Cancel")) {
                    dismiss()
                }
                .disabled(true)
            }
        }
        .padding()
        .frame(width: 450, height: 350)
    }
}

@MainActor
class UpdateNotificationViewModel: ObservableObject {
    @Published var downloadStatus = ""
    @Published var errorMessage = ""
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var hasError = false
    
    private let updateService = UpdateService()
    private let versionInfo: VersionInfo
    
    init(versionInfo: VersionInfo) {
        self.versionInfo = versionInfo
    }
    
    func downloadAndInstall() async {
        guard let downloadUrl = versionInfo.downloadUrl,
              let fileName = versionInfo.fileName else {
            hasError = true
            errorMessage = L10n.t("Download URL not available")
            return
        }
        
        isDownloading = true
        downloadProgress = 0
        downloadStatus = L10n.t("Starting download...")
        hasError = false
        errorMessage = ""
        
        do {
            let installerPath = try await updateService.downloadUpdate(
                from: downloadUrl,
                fileName: fileName
            ) { progress in
                Task { @MainActor in
                    self.downloadProgress = progress
                    self.downloadStatus = String(format: L10n.t("Downloading... %.0f%%"), progress * 100)
                }
            }
            
            downloadStatus = L10n.t("Download complete. Starting installer...")
            try await Task.sleep(nanoseconds: 1_000_000_000)
            
            updateService.installUpdateAndQuit(installerPath: installerPath)
        } catch {
            hasError = true
            errorMessage = L10n.f("Error downloading update: %@", error.localizedDescription)
            downloadStatus = L10n.t("Download failed")
            isDownloading = false
        }
    }
    
    func dontAskAgain() {
        UserDefaults.standard.set(false, forKey: "checkForUpdatesOnStartup")
    }
}
