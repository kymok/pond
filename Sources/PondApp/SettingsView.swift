import Foundation
import SwiftUI
import TodoCore

struct SettingsView: View {
    @EnvironmentObject private var model: TodoAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("View") {
                    LabeledContent("Build ID") {
                        Text(buildID)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                }

                Section("Command Line") {
                    if let status = model.cliStatus {
                        LabeledContent("Link") {
                            Text(status.linkURL.path)
                                .textSelection(.enabled)
                        }

                        LabeledContent("Status") {
                            Text(statusText(status))
                                .foregroundStyle(status.installed ? .green : .secondary)
                        }

                        if !status.installDirectoryIsInPath {
                            LabeledContent("Add to PATH") {
                                Text(model.pathHint)
                                    .monospaced()
                                    .textSelection(.enabled)
                            }
                        }

                        HStack {
                            Button("Reinstall") {
                                model.installCLI()
                            }
                            .disabled(!status.installed && !status.canInstall)

                            Button("Uninstall") {
                                model.uninstallCLI()
                            }
                            .disabled(!status.canUninstall)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 560)
        .onAppear {
            model.refreshCLIStatus()
        }
    }

    private var buildID: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unavailable"
    }

    private func statusText(_ status: CLIInstallStatus) -> String {
        if status.installed {
            return "Installed"
        }

        if let conflict = status.conflictDescription {
            return conflict
        }

        return "Not installed"
    }

}
