import SwiftUI

struct OnboardingView: View {
    @State var state: OnboardingState
    let onFinished: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("LAN URL (https://filmcase.lan)", text: $state.lanURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Tailscale URL (optional)", text: $state.tailscaleURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("API token") {
                    SecureField("Token", text: $state.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button("Connect") {
                        Task { await state.connect() }
                    }
                    .disabled(state.phase == .connecting)
                }
                if case .failed(let message) = state.phase {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Connect to Filmcase")
            .overlay { if state.phase == .connecting { ProgressView() } }
        }
        .sheet(isPresented: trustPromptBinding) {
            if case .awaitingTrust(let host, let fingerprint) = state.phase {
                TrustPrompt(
                    host: host,
                    fingerprint: OnboardingState.formatted(fingerprint: fingerprint),
                    trust: { Task { await state.trustPresentedCertificate() } },
                    cancel: { state.cancelTrust() }
                )
                .presentationDetents([.medium])
                .interactiveDismissDisabled()
            }
        }
        .onChange(of: state.phase) { _, phase in
            if phase == .connected { onFinished() }
        }
    }

    private var trustPromptBinding: Binding<Bool> {
        Binding(
            get: { if case .awaitingTrust = state.phase { true } else { false } },
            set: { if !$0 { state.cancelTrust() } }
        )
    }
}

private struct TrustPrompt: View {
    let host: String
    let fingerprint: String
    let trust: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trust this certificate?").font(.title2.bold())
            Text("\(host) has not been trusted before. Compare this SHA-256 fingerprint with the one your server shows.")
            Text(fingerprint)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                    .buttonStyle(.bordered)
                Button("Trust this certificate", action: trust)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
