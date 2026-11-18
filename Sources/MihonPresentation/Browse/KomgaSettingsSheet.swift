import SwiftUI
import MihonDomain
import MihonData

// MARK: - Komga settings (upstream's Komga source preferences)

/// Upstream's Address / Username / Password / API key, and its login check (the server's libraries).
struct KomgaSettingsSheet: View {
    let sourceId: Int64
    let onDone: () -> Void
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @State private var account = KomgaAccount()
    @State private var checking = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { onDone() }
                    .buttonStyle(MihonButtonStyle(.text))
                Spacer()
                Text(store.sourceName(for: sourceId))
                    .font(MihonType.titleMedium)
                    .foregroundStyle(colors.onSurface)
                Spacer()
                Button("保存") {
                    // Upstream refuses an address that is not a URL; an empty one signs this instance out.
                    if !account.baseUrl.isEmpty && !account.isConfigured {
                        result = (false, KomgaError.badAddress.localizedDescription)
                        return
                    }
                    var accounts = store.komgaAccounts
                    accounts[sourceId] = account
                    store.komgaAccounts = accounts
                    onDone()
                }
                .buttonStyle(MihonButtonStyle(.filled))
                .mihonTestAnchor("komga.save")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            MihonDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    field("服务器地址", text: $account.address, prompt: "http://192.168.1.10:25600", isURL: true)
                    field("用户名（邮箱）", text: $account.username, prompt: "")
                    field("密码", text: $account.password, prompt: "", secure: true)
                    field("API Key（可选，填了就不用密码）", text: $account.apiKey, prompt: "", secure: true)
                    // Upstream's Komga tracker: read chapters go both ways, by number.
                    MihonSwitchPreference(
                        title: "同步阅读进度",
                        subtitle: "和 Komga 服务器双向同步已读章节（书架里的作品）",
                        isOn: $account.syncsProgress
                    )
                    .padding(.top, 8)
                    Text(account.sendsLoginInTheClear
                         ? "这个地址用 http 经过互联网：账号密码会明文传输，建议改用 https。"
                         : "局域网里的服务器可以用 http；通过互联网访问请用 https。")
                        .font(MihonType.bodySmall)
                        .foregroundStyle(account.sendsLoginInTheClear ? colors.error : colors.onSurfaceVariant)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    HStack(spacing: MihonPadding.small) {
                        Button(checking ? "正在连接…" : "测试连接") { Task { await check() } }
                            .buttonStyle(MihonButtonStyle(.tonal))
                            .disabled(checking || !account.isConfigured)
                        if let result {
                            Text(result.text)
                                .font(MihonType.bodyMedium)
                                .foregroundStyle(result.ok ? colors.primary : colors.error)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(colors.surface)
        .onAppear { account = store.komgaAccounts[sourceId] ?? KomgaAccount() }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, secure: Bool = false, isURL: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(MihonType.labelLarge)
                .foregroundStyle(colors.onSurfaceVariant)
            Group {
                if secure {
                    SecureField("", text: text, prompt: Text(prompt).foregroundStyle(colors.onSurfaceVariant))
                } else {
                    TextField("", text: text, prompt: Text(prompt).foregroundStyle(colors.onSurfaceVariant))
                        #if os(iOS)
                        .keyboardType(isURL ? .URL : .emailAddress)
                        #endif
                }
            }
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .textFieldStyle(.plain)
            .font(MihonType.bodyLarge)
            .foregroundStyle(colors.onSurface)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .overlay(RoundedRectangle(cornerRadius: MihonShape.extraSmall).strokeBorder(colors.outline, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            let libraries = try await KomgaLiveEngine(account: account).libraries()
            result = (true, libraries.isEmpty ? "已连接，服务器上还没有书库" : "已连接：\(libraries.joined(separator: "、"))")
        } catch {
            result = (false, error.localizedDescription)
        }
    }
}
