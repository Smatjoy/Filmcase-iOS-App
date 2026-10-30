import FilmcaseKit
import SwiftUI

struct SettingsTab: View {
    let environment: AppEnvironment

    @AppStorage(AppDefaults.demoModeKey) private var demoMode = false
    @State private var servers: [URL]
    @State private var showsServerEditor = false
    @State private var hostToForget: String?
    @State private var forgetResult: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        _servers = State(initialValue: environment.endpointSettings.urls())
    }

    var body: some View {
        NavigationStack {
            Form {
                serversSection
                demoSection
                aboutSection
            }
            .navigationTitle("Settings")
        }
        .sheet(isPresented: $showsServerEditor) {
            OnboardingView(environment: environment, onCancel: { showsServerEditor = false }) {
                showsServerEditor = false
                servers = environment.endpointSettings.urls()
                Task { await environment.reloadServerContent() }
            }
        }
        .confirmationDialog(
            "Forget this certificate?", isPresented: forgetDialogBinding, titleVisibility: .visible,
            presenting: hostToForget
        ) { host in
            Button("Forget certificate", role: .destructive) {
                Task { await forget(host: host) }
            }
        } message: { host in
            Text("\(host) will ask you to trust its certificate again the next time Filmcase connects.")
        }
        .alert("Certificate", isPresented: forgetResultBinding) {
            Button("OK") { forgetResult = nil }
        } message: {
            Text(forgetResult ?? "")
        }
    }

    private var serversSection: some View {
        Section {
            ForEach(servers, id: \.absoluteString) { url in
                HStack {
                    VStack(alignment: .leading) {
                        Text(url.host() ?? url.absoluteString).font(.body)
                        Text(url.absoluteString).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget certificate", systemImage: "lock.slash") {
                        hostToForget = url.host()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "Forget certificate") { hostToForget = url.host() }
            }
            Button("Edit servers or replace token") { showsServerEditor = true }
        } header: {
            Text("Servers")
        } footer: {
            Text("Each server is trusted by its own certificate fingerprint.")
        }
    }

    private var demoSection: some View {
        Section {
            Toggle("Demo mode", isOn: $demoMode)
            LabeledContent("Running", value: environment.modeDescription)
        } footer: {
            Text("Demo mode uses bundled sample recipes and a simulated camera. It applies the next time Filmcase launches.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.versionString)
            NavigationLink("Licenses") { LicensesView() }
        }
    }

    // --- helpers ---

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var forgetDialogBinding: Binding<Bool> {
        Binding(get: { hostToForget != nil }, set: { if !$0 { hostToForget = nil } })
    }

    private var forgetResultBinding: Binding<Bool> {
        Binding(get: { forgetResult != nil }, set: { if !$0 { forgetResult = nil } })
    }

    private func forget(host: String) async {
        do {
            try await environment.forgetCertificate(host: host)
            forgetResult = "Forgot the certificate for \(host)."
        } catch {
            forgetResult = UserMessages.text(for: error)
        }
    }
}

private struct LicensesView: View {
    @State private var texts: [(title: String, body: String)] = []

    var body: some View {
        List {
            Section("Space Mono and Archivo are licensed under the SIL Open Font License 1.1.") {
                ForEach(texts, id: \.title) { entry in
                    DisclosureGroup(entry.title) {
                        Text(entry.body)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            texts = [
                ("Space Mono", BundledText.load("SpaceMono-OFL")),
                ("Archivo", BundledText.load("Archivo-OFL")),
            ]
        }
    }
}
