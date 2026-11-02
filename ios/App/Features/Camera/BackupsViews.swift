// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.
//
// Backups on the Camera tab: one row per slot (what it held before Filmcase, and how many
// backups there are), and a screen per slot with its history, where identical backups in a
// row are merged. Every decision and every sentence comes from BackupsModel / UserMessages.

import FilmcaseKit
import SwiftUI

struct BackupsSection: View {
    let backups: BackupsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Backups").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if backups.canRestoreOriginals {
                    Button(backups.restoreOriginalsLabel, systemImage: "clock.arrow.circlepath") {
                        Task { await backups.requestRestoreOriginals() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Text("Each slot is backed up before Filmcase writes to it. Open a slot to put an earlier version back.")
                .font(.footnote)
                .secondaryText()

            if let message = backups.message {
                BackupsMessage(text: message)
            }

            ForEach(cameraGroups, id: \.camera) { group in
                if cameraGroups.count > 1 {
                    Text(group.camera).font(.subheadline.weight(.semibold)).secondaryText()
                }
                VStack(spacing: 0) {
                    ForEach(group.histories) { history in
                        NavigationLink {
                            SlotBackupsScreen(historyID: history.id, slotIndex: history.slotIndex, backups: backups)
                        } label: {
                            SlotBackupsRow(history: history, backups: backups)
                        }
                        .buttonStyle(.plain)
                        if history.id != group.histories.last?.id {
                            Divider().padding(.leading, 58)
                        }
                    }
                }
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
            }
        }
        .confirmationDialog(
            backups.restoreOriginalsLabel,
            isPresented: Binding(
                get: { backups.restoreOriginalsPrompt != nil },
                set: { if !$0 { backups.cancelRestoreOriginals() } }),
            titleVisibility: .visible
        ) {
            Button(backups.restoreOriginalsLabel, role: .destructive) {
                Task { await backups.restoreOriginals() }
            }
            Button("Cancel", role: .cancel) { backups.cancelRestoreOriginals() }
        } message: {
            Text(backups.restoreOriginalsPrompt ?? "")
        }
        .sensoryFeedback(.success, trigger: backups.successCount)
        // A restore result arrives long after the tap; speak it instead of relying on focus.
        .onChange(of: backups.message) { _, message in announce(message ?? "") }
    }

    /// Histories per camera model, keeping the model's order.
    private var cameraGroups: [(camera: String, histories: [SlotBackupHistory])] {
        var groups: [(camera: String, histories: [SlotBackupHistory])] = []
        for history in backups.histories {
            if let index = groups.firstIndex(where: { $0.camera == history.cameraName }) {
                groups[index].histories.append(history)
            } else {
                groups.append((history.cameraName, [history]))
            }
        }
        return groups
    }
}

/// One slot in the list: its original, the original's film simulation and the backup count.
private struct SlotBackupsRow: View {
    let history: SlotBackupHistory
    let backups: BackupsModel

    var body: some View {
        let original = history.original.backup
        HStack(spacing: 12) {
            Text("C\(history.slotIndex)")
                .appMonoFont(15, relativeTo: .subheadline, bold: true)
                .frame(minWidth: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(original.slotName).font(.body)
                Text(details.joined(separator: " \u{00B7} "))
                    .font(.footnote)
                    .secondaryText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(history.entries.count)")
                .font(.subheadline)
                .secondaryText()
                .accessibilityHidden(true)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("C\(history.slotIndex), \(UserMessages.originalSummary(history)), \(UserMessages.backupCountText(history.entries.count))")
    }

    private var details: [String] {
        [backups.beforeFilmcaseBadge, backups.filmSimulationName(history.original.backup)].compactMap { $0 }
    }
}

/// Every backup of one slot, newest first, identical neighbours merged. Tapping one asks
/// before putting it back.
private struct SlotBackupsScreen: View {
    let historyID: String
    let slotIndex: Int
    let backups: BackupsModel

    var body: some View {
        List {
            if let message = backups.message {
                Section { Text(message).font(.subheadline) }
            }
            Section {
                ForEach(history?.runs ?? []) { run in
                    Button { backups.requestRestore(run.backup) } label: {
                        BackupRunRow(run: run, backups: backups)
                    }
                    .tint(.primary)
                    .disabled(backups.isRestoring)
                    .accessibilityHint("Puts this backup back in C\(slotIndex)")
                }
            } footer: {
                Text("Tap a backup to put it back in C\(slotIndex). What C\(slotIndex) holds now is backed up first.")
            }
        }
        .navigationTitle("C\(slotIndex) backups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if backups.isRestoring {
                ToolbarItem(placement: .primaryAction) { ProgressView() }
            }
        }
        .confirmationDialog(
            backups.pendingRestore.map(UserMessages.restorePromptTitle) ?? "",
            isPresented: Binding(
                get: { backups.pendingRestore != nil },
                set: { if !$0 { backups.cancelRestore() } }),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) { Task { await backups.confirmRestore() } }
            Button("Cancel", role: .cancel) { backups.cancelRestore() }
        } message: {
            Text(backups.pendingRestore.map(UserMessages.restorePromptMessage) ?? "")
        }
        .sensoryFeedback(.success, trigger: backups.successCount)
        .onChange(of: backups.message) { _, message in announce(message ?? "") }
    }

    /// Looked up live, so the list follows a restore (which adds a backup of its own).
    private var history: SlotBackupHistory? {
        backups.histories.first { $0.id == historyID }
    }
}

private struct BackupRunRow: View {
    let run: BackupHistoryRun
    let backups: BackupsModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(run.backup.slotName).font(.body)
                if let sim = backups.filmSimulationName(run.backup) {
                    Text(sim).font(.subheadline).secondaryText()
                }
                Group {
                    if let count = UserMessages.runCountText(run) {
                        Text("\(count), latest \(run.newest, format: .dateTime.day().month().hour().minute())")
                    } else {
                        Text(run.newest, format: .dateTime.day().month().hour().minute())
                    }
                }
                .font(.footnote)
                .secondaryText()
                if run.isBeforeFilmcase {
                    // Text and a shape, never colour alone.
                    Label(backups.beforeFilmcaseBadge, systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct BackupsMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }
}
