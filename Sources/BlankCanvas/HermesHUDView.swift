import SwiftUI

struct HermesHUDView: View {
    @ObservedObject var connection: HermesConnectionModel
    @ObservedObject private var client: HermesClientModel
    @State private var composerText = ""
    @State private var clarificationText = ""
    @State private var sensitiveValue = ""

    init(connection: HermesConnectionModel) {
        self.connection = connection
        _client = ObservedObject(wrappedValue: connection.client)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            connectionHeader
            if client.connectionState == .connected {
                if client.selectedSession == nil {
                    sessionList
                } else {
                    conversation
                }
            } else {
                connectionForm
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var connectionHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(client.connectionState == .connected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.status)
                    .font(.system(size: 11, weight: .semibold))
                if let error = client.errorMessage ?? connection.errorMessage {
                    Text(error)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if client.connectionState == .connected {
                if client.selectedSession != nil {
                    Button("Sessions") { client.clearSelection() }
                        .buttonStyle(.borderless)
                }
                Button("Disconnect", action: connection.disconnect)
                    .buttonStyle(.borderless)
            }
        }
        .padding(11)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect to a selected Hermes backend")
                .font(.system(size: 13, weight: .bold))
            Text("Blank Canvas does not discover profiles or provider credentials. The endpoint and profile are explicit; the session credential is stored only in this Mac’s Keychain.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("ws://127.0.0.1:9119/api/ws", text: $connection.endpointText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Hermes WebSocket endpoint")
            TextField("Profile name (optional)", text: $connection.profileText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Hermes profile name")
            Picker("Authentication", selection: $connection.authMode) {
                ForEach(HermesAuthMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            SecureField(
                connection.hasStoredCredential ? "Credential stored in Keychain" : connection.authMode.title,
                text: $connection.credentialText
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(connection.authMode.title)

            HStack {
                Button(client.connectionState == .connecting ? "Connecting…" : "Connect") {
                    Task { await connection.connect() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(client.connectionState == .connecting)
                if connection.hasStoredCredential {
                    Button("Forget credential", action: connection.forgetCredential)
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(12)
        .background(Color.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("HERMES SESSIONS")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await client.refreshSessions() } }
                    .buttonStyle(.borderless)
                    .disabled(client.isBusy)
            }
            if client.sessions.isEmpty {
                Text("No persisted sessions are available in the selected profile.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(client.sessions) { session in
                            Button {
                                Task { await client.select(session) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.title.isEmpty ? "Untitled session" : session.title)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .lineLimit(1)
                                    if !session.preview.isEmpty {
                                        Text(session.preview)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Text("\(session.messageCount) messages · \(session.startedAt, style: .relative)")
                                        .font(.system(size: 8.5))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                            }
                            .buttonStyle(.plain)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityHint("Opens this Hermes session in the native HUD")
                        }
                    }
                }
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 9) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(client.transcript.messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                        if let streaming = client.transcript.streamingText {
                            messageBubble(role: .assistant, text: streaming.isEmpty ? "Working…" : streaming)
                                .id("streaming")
                        }
                    }
                }
                .onChange(of: client.transcript.messages.count) { _ in
                    if let id = client.transcript.messages.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
                .onChange(of: client.transcript.streamingText) { _ in
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }

            if let clarification = client.pendingClarification {
                clarificationCard(clarification)
            }
            if let approval = client.pendingApproval {
                approvalCard(approval)
            }
            if let sensitiveRequest = client.pendingSensitiveRequest {
                sensitiveRequestCard(sensitiveRequest)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Hermes", text: $composerText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(sendComposer)
                Button("Send", action: sendComposer)
                    .buttonStyle(.borderedProminent)
                    .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Stop") { Task { await client.interrupt() } }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: HermesMessage) -> some View {
        if message.role == .tool {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                Text(message.toolName ?? "Tool")
                    .fontWeight(.semibold)
                Text(message.text).lineLimit(1)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        } else {
            messageBubble(role: message.role, text: message.text)
        }
    }

    private func messageBubble(role: HermesMessageRole, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(role == .user ? "YOU" : role.rawValue.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(
            role == .user ? Color.indigo.opacity(0.09) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private func clarificationCard(_ request: HermesClarificationRequest) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Hermes requires clarification")
                .font(.system(size: 11, weight: .bold))
            Text(request.question)
                .font(.system(size: 10.5))
            if request.choices.isEmpty {
                HStack {
                    TextField("Response", text: $clarificationText)
                        .textFieldStyle(.roundedBorder)
                    Button("Respond") {
                        let answer = clarificationText
                        clarificationText = ""
                        Task { await client.respondToClarification(answer) }
                    }
                    .disabled(clarificationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                HStack {
                    ForEach(request.choices, id: \.self) { choice in
                        Button(choice) { Task { await client.respondToClarification(choice) } }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func approvalCard(_ request: HermesApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Native approval required")
                .font(.system(size: 11, weight: .bold))
            Group {
                if !request.detail.isEmpty {
                    Text(request.detail).font(.system(size: 10.5))
                }
                if !request.command.isEmpty {
                    Text(request.command)
                        .font(.system(size: 9.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(7)
                        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack {
                ForEach(request.choices, id: \.rawValue) { choice in
                    approvalButton(choice)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func approvalButton(_ choice: HermesApprovalChoice) -> some View {
        if choice == .deny {
            Button(approvalTitle(choice)) {
                Task { await client.respondToApproval(choice) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else {
            Button(approvalTitle(choice)) {
                Task { await client.respondToApproval(choice) }
            }
            .buttonStyle(.bordered)
        }
    }

    private func sensitiveRequestCard(_ request: HermesSensitiveRequest) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(request.kind == .sudo ? "Administrator authorization required" : "Credential required")
                .font(.system(size: 11, weight: .bold))
            Text(request.prompt)
                .font(.system(size: 10.5))
            if let environmentVariable = request.environmentVariable, !environmentVariable.isEmpty {
                Text(environmentVariable)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            SecureField(request.kind == .sudo ? "Administrator password" : "Credential", text: $sensitiveValue)
                .textFieldStyle(.roundedBorder)
                .accessibilityHint("This value is sent to the active Hermes request and is not saved by Blank Canvas")
            HStack {
                Button("Submit") {
                    let value = sensitiveValue
                    sensitiveValue = ""
                    Task { await client.respondToSensitiveRequest(value, cancelling: false) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sensitiveValue.isEmpty)
                Button("Cancel") {
                    sensitiveValue = ""
                    Task { await client.respondToSensitiveRequest("", cancelling: true) }
                }
                .buttonStyle(.bordered)
            }
            Text("Blank Canvas does not store or display this value after submission.")
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func approvalTitle(_ choice: HermesApprovalChoice) -> String {
        switch choice {
        case .once: return "Allow once"
        case .session: return "Allow for session"
        case .always: return "Always allow"
        case .deny: return "Deny"
        }
    }

    private func sendComposer() {
        let text = composerText
        composerText = ""
        Task { await client.submit(text) }
    }
}
