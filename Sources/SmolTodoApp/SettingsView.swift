import SwiftUI
import TodoCore

struct SettingsView: View {
    @EnvironmentObject private var model: TodoAppModel
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    var body: some View {
        Form {
            Section("View") {
                Toggle("Always on Top", isOn: $alwaysOnTop)
            }

            Section("Command Line") {
                if let status = model.cliStatus {
                    LabeledContent("Link") {
                        Text(status.linkURL.path)
                            .textSelection(.enabled)
                    }

                    LabeledContent("Target") {
                        Text(status.targetURL.path)
                            .textSelection(.enabled)
                    }

                    LabeledContent("Status") {
                        Text(statusText(status))
                            .foregroundStyle(status.installed ? .green : .secondary)
                    }

                    if !status.installDirectoryIsInPath {
                        LabeledContent("PATH") {
                            Text(model.pathHint)
                                .textSelection(.enabled)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }

                    HStack {
                        Button(status.installed ? "Reinstall" : "Install") {
                            model.installCLI()
                        }
                        .disabled(status.conflictDescription != nil && !status.installed)

                        Button("Uninstall") {
                            model.uninstallCLI()
                        }
                        .disabled(!status.installed)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding()
        .onAppear {
            model.refreshCLIStatus()
        }
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
