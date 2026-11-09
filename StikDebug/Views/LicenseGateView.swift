//
//  LicenseGateView.swift
//  StikDebug
//
//  爱定位 · 启动门禁：免责声明 → 卡密激活 → 会员状态拦截（到期/封禁）→ 公告 → 主界面
//

import SwiftUI

struct LicenseGateView: View {
    @StateObject private var license = LicenseManager.shared

    var body: some View {
        ZStack {
            switch license.status {
            case .checking:
                checkingView
            case .notActivated, .invalid:
                ActivationView(license: license)
            case .active, .offline:
                MainTabView()
            case .expired(let expireAt):
                ExpiredView(license: license, expireAt: expireAt)
            case .banned:
                BannedView(license: license)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: gateStateID)
        .task {
            await license.verify()
        }
        // 免责声明（首次启动 / 后台更新文本后重新弹出）
        .fullScreenCover(isPresented: $license.showDisclaimer) {
            DisclaimerView(license: license)
        }
        // 公告（有新公告时弹一次）
        .sheet(item: $license.announcementToShow) { ann in
            AnnouncementView(license: license, announcement: ann)
        }
    }

    private var gateStateID: Int {
        switch license.status {
        case .checking: return 0
        case .notActivated, .invalid: return 1
        case .active, .offline: return 2
        case .expired: return 3
        case .banned: return 4
        }
    }

    private var checkingView: some View {
        VStack(spacing: 16) {
            Image("StikDebug")
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            ProgressView()
            Text("正在验证会员状态…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - 卡密激活页

struct ActivationView: View {
    @ObservedObject var license: LicenseManager
    @State private var cardKey = ""
    @State private var activating = false
    @State private var errorMessage: String?
    @FocusState private var cardFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 10) {
                Image("StikDebug")
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("爱定位")
                    .font(.title.weight(.semibold))
                Text("请输入卡密激活后使用")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            VStack(alignment: .leading, spacing: 14) {
                Text("卡密激活")
                    .font(.headline)
                TextField("请输入卡密（如 AL3F9A1B2C4D5E6F7）", text: $cardKey)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .focused($cardFocused)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    activate()
                } label: {
                    HStack {
                        if activating {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(activating ? "正在激活…" : "立即激活")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(cardKey.trimmingCharacters(in: .whitespaces).isEmpty || activating)

                HStack {
                    Spacer()
                    Text("设备码：\(license.shortDeviceID)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private func activate() {
        cardFocused = false
        activating = true
        errorMessage = nil
        Task {
            do {
                _ = try await license.activate(cardKey: cardKey)
                // 激活成功后立即校验一次，同步配置并进入主界面
                await license.verify()
            } catch {
                errorMessage = error.localizedDescription
            }
            activating = false
        }
    }
}

// MARK: - 会员到期页

struct ExpiredView: View {
    @ObservedObject var license: LicenseManager
    let expireAt: String
    @State private var cardKey = ""
    @State private var activating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "hourglass.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                Text("会员已到期")
                    .font(.title.weight(.semibold))
                Text("没有权限使用，请续费后继续")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !expireAt.isEmpty {
                    Text("到期时间：\(expireAt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            VStack(alignment: .leading, spacing: 14) {
                Text("输入新卡密续费")
                    .font(.headline)
                TextField("请输入卡密", text: $cardKey)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    renew()
                } label: {
                    HStack {
                        if activating {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(activating ? "正在激活…" : "续费并继续使用")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(cardKey.trimmingCharacters(in: .whitespaces).isEmpty || activating)

                // 后台开启购买入口时显示
                if license.config.purchase.enabled,
                   let url = URL(string: license.config.purchase.url), url.scheme != nil {
                    Link(destination: url) {
                        Text(license.config.purchase.title.isEmpty ? "开通会员" : license.config.purchase.title)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private func renew() {
        activating = true
        errorMessage = nil
        Task {
            do {
                _ = try await license.activate(cardKey: cardKey)
                await license.verify()
            } catch {
                errorMessage = error.localizedDescription
            }
            activating = false
        }
    }
}

// MARK: - 封禁页

struct BannedView: View {
    @ObservedObject var license: LicenseManager

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "nosign.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("设备已被封禁")
                .font(.title.weight(.semibold))
            Text("如有疑问请联系客服")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if license.config.contact.enabled,
               let url = URL(string: license.config.contact.url), url.scheme != nil {
                Link(destination: url) {
                    Text(license.config.contact.title.isEmpty ? "联系客服" : license.config.contact.title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}

// MARK: - 免责声明页

struct DisclaimerView: View {
    @ObservedObject var license: LicenseManager

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
                Text("免责声明")
                    .font(.title2.weight(.semibold))
            }
            .padding(.top, 40)

            ScrollView {
                Text(license.config.disclaimer.content)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
            }
            .padding(.vertical, 20)

            VStack(spacing: 10) {
                Button {
                    license.agreeDisclaimer()
                } label: {
                    Text("我已阅读并同意")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 32)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}

// MARK: - 公告弹窗

struct AnnouncementView: View {
    @ObservedObject var license: LicenseManager
    let announcement: AppConfig.Announcement

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !announcement.title.isEmpty {
                        Text(announcement.title)
                            .font(.title3.weight(.semibold))
                    }
                    Text(announcement.content)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("公告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("我知道了") {
                        license.markAnnouncementRead()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 公告可 Identifiable（用于 sheet(item:)）

extension AppConfig.Announcement: Identifiable {
    var id: String { updatedAt + title + content }
}
