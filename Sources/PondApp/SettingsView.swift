import Foundation
import SwiftUI
import TaskCore

struct SettingsView: View {
    @Environment(TaskAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var defaultPromptTemplate = TaskPromptSettings.storedDefaultPromptTemplate

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("View") {
                    LabeledContent("Version") {
                        Text(appVersion)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }

                    LabeledContent("Build") {
                        Text(buildNumber)
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
                                HStack(spacing: 8) {
                                    Text(model.pathHint)
                                        .monospaced()
                                        .textSelection(.enabled)

                                    Button {
                                        copyToPasteboard(model.pathHint)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Copy PATH Command")
                                }
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

                Section("Default App Prompt") {
                    VStack(alignment: .leading, spacing: 8) {
                        PromptTemplateEditor(
                            text: $defaultPromptTemplate,
                            height: 180
                        )

                        Button("Reset to Default") {
                            defaultPromptTemplate = TaskPromptTemplate.applicationDefaultTemplate.rawValue
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
            defaultPromptTemplate = TaskPromptSettings.storedDefaultPromptTemplate
        }
        .onChange(of: defaultPromptTemplate) { _, promptTemplate in
            TaskPromptSettings.setDefaultPromptTemplate(promptTemplate)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unavailable"
    }

    private var buildNumber: String {
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
