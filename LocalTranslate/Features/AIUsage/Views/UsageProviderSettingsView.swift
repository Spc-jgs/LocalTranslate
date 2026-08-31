import SwiftUI
import AppKit

/// AI 用量的账号来源配置。
struct UsageProviderSettingsView: View {

    @ObservedObject
    private var store = UsageProviderSettingsStore.shared

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            header

            Divider()
                .opacity(0.3)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    codexSection
                    builtInSection
                }
                .padding(20)
            }

            Divider()
                .opacity(0.3)

            footer
        }
        .frame(width: 520, height: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("账号来源")
                .font(.system(size: 15, weight: .semibold))

            Text("LocalTranslate 只读取本机客户端目录，不代你登录任何账号。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Codex

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 8) {

            HStack {
                Label("Codex 账号", systemImage: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    store.addCodexAccount()
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }

            if store.settings.codexAccounts.isEmpty {
                Text("没有配置任何 Codex 账号。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 10) {
                    ForEach(store.settings.codexAccounts) { account in
                        codexRow(account)
                    }
                }
            }

            Text("每个账号对应一个 CODEX_HOME 目录，路径相对用户主目录。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func codexRow(_ account: UsageCodexAccount) -> some View {
        VStack(alignment: .leading, spacing: 7) {

            HStack(spacing: 8) {
                TextField(
                    "显示名",
                    text: binding(
                        for: account.id,
                        keyPath: \.displayName
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

                Button(role: .destructive) {
                    store.removeCodexAccount(id: account.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("移除此账号")
                .accessibilityLabel(Text("移除账号 \(account.displayName)"))
            }

            HStack(spacing: 8) {
                Text("~/")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)

                TextField(
                    ".codex",
                    text: binding(
                        for: account.id,
                        keyPath: \.relativePath
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))

                // 目录不存在时该来源必然读不出数据，提前说清楚，
                // 而不是让它在看板上表现为一张永远空着的卡片。
                if account.exists {
                    Label("已找到", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                        .labelStyle(.iconOnly)
                        .help("目录存在")
                } else {
                    Label("目录不存在", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .labelStyle(.iconOnly)
                        .help("目录不存在：该来源不会有数据")
                }
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
    }

    // MARK: - Built-in

    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: 8) {

            Label("其他来源", systemImage: "switch.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(BuiltInUsageProvider.allCases.enumerated()), id: \.element.id) { index, provider in

                    if index > 0 {
                        Divider().opacity(0.2)
                    }

                    Toggle(
                        isOn: Binding(
                            get: { store.isEnabled(provider) },
                            set: { store.setEnabled($0, for: provider) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                                .font(.system(size: 12))

                            Text(provider.sourceHint)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 10)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            }

            Text("停用的来源不会被读取，也不会出现在看板上。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button("完成") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Binding

    private func binding(
        for id: String,
        keyPath: WritableKeyPath<UsageCodexAccount, String>
    ) -> Binding<String> {
        Binding(
            get: {
                store.settings.codexAccounts
                    .first { $0.id == id }?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                store.update { settings in
                    guard let index = settings.codexAccounts.firstIndex(
                        where: { $0.id == id }
                    ) else { return }
                    settings.codexAccounts[index][keyPath: keyPath] = newValue
                }
            }
        )
    }
}
