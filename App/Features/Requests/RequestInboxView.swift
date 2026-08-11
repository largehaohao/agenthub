import SwiftUI
import AgentHubCore

struct RequestInboxView: View {
    let requests: [PendingRequest]
    let canResolve: (UUID) -> Bool
    let onResolve: (UUID, RequestDecision) async -> Void
    let onAuthenticate: (String, String) async -> Void

    private var actionable: [PendingRequest] {
        requests
            .filter { $0.state == .pending || $0.state == .resolving }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List(actionable) { request in
            RequestCard(
                request: request,
                canResolve: canResolve(request.id),
                onResolve: onResolve,
                onAuthenticate: onAuthenticate
            )
        }
        .navigationTitle("Requests")
        .overlay {
            if actionable.isEmpty {
                ContentUnavailableView("No pending requests", systemImage: "checkmark.circle")
            }
        }
    }
}

private struct RequestCard: View {
    let request: PendingRequest
    let canResolve: Bool
    let onResolve: (UUID, RequestDecision) async -> Void
    let onAuthenticate: (String, String) async -> Void

    @State private var selectedChoices: [String: Set<String>] = [:]
    @State private var freeText: [String: String] = [:]
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title).font(.headline)
                    Text(request.provider.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ReliabilityBadge(level: request.reliability)
            }
            Text(request.detail)
                .font(.callout)
                .foregroundStyle(.secondary)

            switch request.kind {
            case .authentication:
                authenticationControls
            case .choice where !request.fields.isEmpty:
                questionControls
            case .permission where request.provider == .openCode:
                openCodePermissionControls
            default:
                standardControls
            }
        }
        .padding(.vertical, 6)
        .onDisappear(perform: clearSensitiveInputs)
    }

    private var openCodePermissionControls: some View {
        HStack {
            Button("Reject") { resolve(.decline) }
            Spacer()
            if request.state == .resolving {
                ProgressView().controlSize(.small)
            }
            Button("Once") { resolve(.accept) }
                .disabled(!canResolve)
            Button("Always") { resolve(.acceptForSession) }
                .buttonStyle(.borderedProminent)
                .disabled(!canResolve)
        }
        .disabled(!canResolve)
    }

    private var standardControls: some View {
        HStack {
            Button("Decline") { resolve(.decline) }
                .disabled(!canResolve)
            Spacer()
            if request.state == .resolving {
                ProgressView().controlSize(.small)
            }
            Button("Allow") { resolve(.accept) }
                .buttonStyle(.borderedProminent)
                .disabled(!canResolve)
        }
    }

    private var questionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(request.fields) { field in
                VStack(alignment: .leading, spacing: 6) {
                    Text(field.prompt).font(.callout.bold())
                    if field.allowsMultiple {
                        ForEach(field.choices, id: \.self) { choice in
                            Toggle(choice, isOn: choiceBinding(fieldID: field.id, choice: choice))
                        }
                    } else if !field.choices.isEmpty {
                        Picker("Answer", selection: singleChoiceBinding(fieldID: field.id)) {
                            Text("Choose…").tag("")
                            ForEach(field.choices, id: \.self) { choice in
                                Text(choice).tag(choice)
                            }
                        }
                    }
                    if field.allowsFreeText {
                        TextField(
                            "Other answer",
                            text: textBinding(fieldID: field.id),
                            axis: .vertical
                        )
                    }
                }
            }
            HStack {
                Button("Cancel") { resolve(.cancel) }
                Spacer()
                Button("Submit answers") {
                    let answers = orderedAnswers()
                    clearSensitiveInputs()
                    Task { await onResolve(request.id, .answers(answers)) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canResolve)
            }
        }
    }

    private var authenticationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("OpenCode password", text: $password)
            HStack {
                Spacer()
                Button("Authenticate") {
                    let submitted = password
                    password = ""
                    Task { await onAuthenticate(request.threadID, submitted) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty || !canResolve)
            }
        }
    }

    private func resolve(_ decision: RequestDecision) {
        clearSensitiveInputs()
        Task { await onResolve(request.id, decision) }
    }

    private func choiceBinding(fieldID: String, choice: String) -> Binding<Bool> {
        Binding(
            get: { selectedChoices[fieldID, default: []].contains(choice) },
            set: { selected in
                if selected {
                    selectedChoices[fieldID, default: []].insert(choice)
                } else {
                    selectedChoices[fieldID, default: []].remove(choice)
                }
            }
        )
    }

    private func singleChoiceBinding(fieldID: String) -> Binding<String> {
        Binding(
            get: { selectedChoices[fieldID]?.first ?? "" },
            set: { selectedChoices[fieldID] = $0.isEmpty ? [] : [$0] }
        )
    }

    private func textBinding(fieldID: String) -> Binding<String> {
        Binding(
            get: { freeText[fieldID, default: ""] },
            set: { freeText[fieldID] = $0 }
        )
    }

    private func orderedAnswers() -> [[String]] {
        request.fields.map { field in
            var answers = field.choices.filter {
                selectedChoices[field.id, default: []].contains($0)
            }
            if let custom = freeText[field.id]?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !custom.isEmpty {
                answers.append(custom)
            }
            return answers
        }
    }

    private func clearSensitiveInputs() {
        selectedChoices.removeAll()
        freeText.removeAll()
        password = ""
    }
}
