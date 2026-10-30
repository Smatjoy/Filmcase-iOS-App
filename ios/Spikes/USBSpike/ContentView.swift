// Throwaway spike UI (S1).

import SwiftUI

struct ContentView: View {
    @State private var model = SpikeModel()

    var body: some View {
        NavigationStack {
            List {
                authorizationSection
                deviceSection
                framingSection
                actionsSection
                resultsSection
                logSection
            }
            .navigationTitle("USB Spike")
            .navigationBarTitleDisplayMode(.inline)
            .task { model.start() }
        }
    }

    private var authorizationSection: some View {
        Section("1. Authorization") {
            LabeledContent("Control", value: model.controlStatus)
            LabeledContent("Contents", value: model.contentsStatus)
            Button("Authorize") { Task { await model.authorizeControl() } }
                .disabled(model.isBusy)
            Button("Authorize contents (fallback)") { Task { await model.authorizeContents() } }
                .disabled(model.isBusy)
        }
    }

    private var deviceSection: some View {
        Section("2. Device and session") {
            if model.devices.isEmpty {
                Text("No camera found. Camera in USB RAW CONV./BACKUP RESTORE, direct USB-C cable.")
                    .foregroundStyle(.secondary)
            }
            if model.devices.count > 1 {
                Picker("Device", selection: Binding(
                    get: { model.selectedDevice?.id ?? "" },
                    set: { model.selectDevice($0) }
                )) {
                    ForEach(model.devices) { Text($0.name).tag($0.id) }
                }
            }
            if let device = model.selectedDevice {
                LabeledContent("Name", value: device.name)
                LabeledContent("Accepts PTP commands", value: device.canAcceptPTPCommands ? "yes" : "NO")
                Text(device.capabilities.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Session", value: model.sessionOpen ? "open" : "closed")
            Button("Open session") { Task { await model.openSession() } }
                .disabled(model.isBusy || model.devices.isEmpty)
            Button("Close session") { Task { await model.closeSession() } }
                .disabled(model.isBusy || model.devices.isEmpty)
        }
    }

    private var framingSection: some View {
        Section("Command framing") {
            Picker("Framing", selection: $model.framing) {
                ForEach(CommandFraming.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var actionsSection: some View {
        Section("3-6. Actions") {
            Button("Read slots") { Task { await model.readSlots() } }
            Button("Write C7 name (FCTEST, restore)") { Task { await model.writeC7Name() } }
            Button("Stall drill (20 reads)") { Task { await model.stallDrill() } }
            if model.isBusy { ProgressView() }
        }
        .disabled(model.isBusy || model.devices.isEmpty)
    }

    @ViewBuilder
    private var resultsSection: some View {
        if !model.slots.isEmpty || !model.summary.isEmpty || model.sawNotAuthorized {
            Section("Results") {
                if model.sawNotAuthorized {
                    Text("Saw error -21249 (ICReturnPTPNotAuthorizedToSendCommand)")
                        .font(.callout.bold())
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.red, in: .rect(cornerRadius: 6))
                }
                ForEach(model.slots) { slot in
                    LabeledContent("C\(slot.index)", value: "\(slot.name)  sim=\(slot.filmSim.map(String.init) ?? "-")")
                }
                if !model.summary.isEmpty {
                    Text(model.summary).font(.footnote)
                }
            }
        }
    }

    private var logSection: some View {
        Section("Log") {
            HStack {
                Button("Prepare log file") { model.prepareExport() }
                Spacer()
                if let url = model.exportURL {
                    ShareLink(item: url)
                }
                Button("Clear", role: .destructive) { model.clearLog() }
            }
            .buttonStyle(.borderless)
            ForEach(model.log.suffix(400)) { entry in
                Text(entry.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(color(for: entry.level))
                    .listRowBackground(entry.level == .alarm ? Color.red.opacity(0.25) : nil)
                    .textSelection(.enabled)
            }
        }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: .primary
        case .warning: .orange
        case .error, .alarm: .red
        }
    }
}

#Preview {
    ContentView()
}
