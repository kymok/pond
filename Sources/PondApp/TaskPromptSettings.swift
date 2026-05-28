import Foundation
import SwiftUI
import TaskCore

enum TaskPromptSettings {
    static let defaultPromptTemplateKey = "defaultPromptTemplate"

    static var storedDefaultPromptTemplate: String {
        UserDefaults.standard.string(forKey: defaultPromptTemplateKey) ?? ""
    }

    static var effectiveDefaultPromptTemplate: String {
        let storedTemplate = storedDefaultPromptTemplate
        return storedTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? TaskPromptTemplate.applicationDefaultTemplate.rawValue
            : storedTemplate
    }

    static func setDefaultPromptTemplate(_ promptTemplate: String) {
        if promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultPromptTemplateKey)
        } else {
            UserDefaults.standard.set(promptTemplate, forKey: defaultPromptTemplateKey)
        }
    }
}

struct PromptTemplateEditor: View {
    @Binding var text: String

    var height: CGFloat = 140
    private let horizontalPadding: CGFloat = 8
    private let verticalPadding: CGFloat = 12

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(height: contentHeight)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(height: height)
        .background(Color.white)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.25), lineWidth: 1)
        }
    }

    private var contentHeight: CGFloat {
        max(0, height - (verticalPadding * 2))
    }
}
