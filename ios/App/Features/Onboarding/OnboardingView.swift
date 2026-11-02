import FilmcaseKit
import SwiftUI

/// Server URLs, token, and the trust-on-first-use prompt. Every decision (validation, the
/// connect/trust flow, fingerprint format) is in `OnboardingModel`; this renders its state.
struct OnboardingView: View {
    @State private var model: OnboardingModel
    let onCancel: (() -> Void)?
    let onFinished: () -> Void

    init(environment: AppEnvironment, onCancel: (() -> Void)?, onFinished: @escaping () -> Void) {
        _model = State(initialValue: environment.makeOnboardingModel())
        self.onCancel = onCancel
        self.onFinished = onFinished
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    urlField("LAN URL (https://filmcase.lan)", text: $model.lanURL, error: model.lanURLError)
                    urlField("Tailscale URL (optional)", text: $model.tailscaleURL, error: model.tailscaleURLError)
                }
                Section {
                    SecureField("Token (optional)", text: $model.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API token")
                } footer: {
                    Text("Only needed if your server sets FILMCASE_API_TOKEN.")
                }
                Section {
                    Button("Connect") { Task { await model.connect() } }
                        .disabled(model.isConnecting)
                }
                if case .failed(let message) = model.state {
                    Section {
                        StatusLabel(text: message, systemImage: "exclamationmark.triangle.fill", tint: .red)
                    }
                }
            }
            .navigationTitle("Connect to Filmcase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                }
            }
            .overlay {
                if model.isConnecting {
                    ProgressView().accessibilityLabel("Connecting")
                }
            }
        }
        .sheet(isPresented: trustPromptBinding) {
            if case .needsTrust(let host, let fingerprint) = model.state {
                TrustPrompt(
                    host: host, fingerprint: fingerprint,
                    trust: { Task { await model.trust() } },
                    cancel: { model.cancelTrust() })
                    .presentationDetents([.medium])
                    .interactiveDismissDisabled()
            }
        }
        .onChange(of: model.state) { _, state in
            if state == .connected { onFinished() }
            // A failed connect appears below the fold of the form; say it aloud.
            if case .failed(let message) = state { announce(message) }
        }
        .onChange(of: model.lanURLError) { _, message in announce(message ?? "") }
        .onChange(of: model.tailscaleURLError) { _, message in announce(message ?? "") }
    }

    private func urlField(_ prompt: String, text: Binding<String>, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(prompt, text: text)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            fieldError(error)
        }
    }

    @ViewBuilder
    private func fieldError(_ message: String?) -> some View {
        if let message {
            StatusLabel(text: message, systemImage: "exclamationmark.circle.fill", tint: .red, font: .footnote)
        }
    }

    private var trustPromptBinding: Binding<Bool> {
        Binding(
            get: { if case .needsTrust = model.state { true } else { false } },
            set: { if !$0 { model.cancelTrust() } }
        )
    }
}

private struct TrustPrompt: View {
    let host: String
    let fingerprint: String
    let trust: () -> Void
    let cancel: () -> Void

    var body: some View {
        // Scrolls so the whole prompt stays reachable at the largest text sizes.
        ScrollView {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trust this certificate?").font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("\(host) has not been trusted before. Compare this SHA-256 fingerprint with the one your server shows.")
            Text(fingerprint)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                // Read as pairs ("AB, CD, …") rather than one long string.
                .accessibilityLabel(OnboardingModel.spoken(fingerprint: fingerprint))
            AdaptiveStack {
                Button("Cancel", role: .cancel, action: cancel)
                    .buttonStyle(.bordered)
                Button("Trust this certificate", action: trust)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding()
    }
}
