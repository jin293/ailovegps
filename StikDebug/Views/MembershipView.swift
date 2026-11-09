//
//  MembershipView.swift
//  StikDebug
//
//  爱定位 · 会员中心：会员状态、卡密兑换、开通会员入口、联系客服
//

import SwiftUI

struct MembershipView: View {
    @ObservedObject private var license = LicenseManager.shared
    @State private var cardKey = ""
    @State private var redeeming = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        Form {
            // 会员状态
            Section("会员状态") {
                HStack {
                    Text("当前状态")
                    Spacer()
                    switch license.status {
                    case .active, .offline:
                        Text("有效").foregroundStyle(.green)
                    case .expired:
                        Text("已到期").foregroundStyle(.orange)
                    case .banned:
                        Text("已封禁").foregroundStyle(.red)
                    case .notActivated, .invalid:
                        Text("未激活").foregroundStyle(.secondary)
                    case .checking:
                        ProgressView().controlSize(.small)
                    }
                }
                if !license.expireAtText.isEmpty {
                    HStack {
                        Text("到期时间")
                        Spacer()
                        Text(license.expireAtText).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("设备码")
                    Spacer()
                    Text(license.shortDeviceID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // 卡密兑换
            Section("兑换会员") {
                TextField("请输入卡密", text: $cardKey)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                Button {
                    redeem()
                } label: {
                    HStack {
                        if redeeming {
                            ProgressView().controlSize(.small)
                        }
                        Text(redeeming ? "正在兑换…" : "立即兑换")
                    }
                }
                .disabled(cardKey.trimmingCharacters(in: .whitespaces).isEmpty || redeeming)
                if let message {
                    Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(message.isError ? .red : .green)
                }
                Text("兑换成功后会员时长自动累加，一卡一设备。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 开通会员入口（后台可开关并配置跳转链接）
            if license.config.purchase.enabled,
               let url = URL(string: license.config.purchase.url), url.scheme != nil {
                Section {
                    Link(destination: url) {
                        HStack {
                            Label(license.config.purchase.title.isEmpty ? "开通会员" : license.config.purchase.title,
                                  systemImage: "crown.fill")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // 联系客服（后台可开关并配置按钮名称与跳转链接）
            if license.config.contact.enabled,
               let url = URL(string: license.config.contact.url), url.scheme != nil {
                Section {
                    Link(destination: url) {
                        HStack {
                            Label(license.config.contact.title.isEmpty ? "联系客服" : license.config.contact.title,
                                  systemImage: "headphones")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("会员中心")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func redeem() {
        redeeming = true
        message = nil
        Task {
            do {
                let msg = try await license.activate(cardKey: cardKey)
                message = (msg, false)
                cardKey = ""
            } catch {
                message = (error.localizedDescription, true)
            }
            redeeming = false
        }
    }
}
