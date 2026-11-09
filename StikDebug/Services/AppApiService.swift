//
//  AppApiService.swift
//  StikDebug
//
//  精苹果 · 卡密验证 / 会员状态 / 公告 / 免责声明 / 反馈 的网络层与状态管理
//

import Foundation
import SwiftUI
import UIKit

/// 后台服务地址（部署后台后按实际地址修改）
enum AppApiConfig {
    /// 精苹果 App 后台地址（对应「精苹果App后台」部署地址，可带反代子路径）
    static let baseURL = URL(string: "https://www.lovegps.top/appapi")!
    static let timeout: TimeInterval = 15
}

// MARK: - 数据模型

/// 后台下发的全局配置（公告/免责声明/客服/购买入口）
struct AppConfig: Codable, Equatable {
    struct Announcement: Codable, Equatable {
        var enabled: Bool
        var title: String
        var content: String
        var updatedAt: String

        enum CodingKeys: String, CodingKey {
            case enabled, title, content
            case updatedAt = "updated_at"
        }
    }

    struct Disclaimer: Codable, Equatable {
        var content: String
        var version: String
    }

    struct Contact: Codable, Equatable {
        var enabled: Bool
        var title: String
        var url: String
    }

    struct Purchase: Codable, Equatable {
        var enabled: Bool
        var title: String
        var url: String
    }

    var announcement: Announcement
    var disclaimer: Disclaimer
    var contact: Contact
    var purchase: Purchase

    static let empty = AppConfig(
        announcement: .init(enabled: false, title: "", content: "", updatedAt: ""),
        disclaimer: .init(content: "", version: "0"),
        contact: .init(enabled: false, title: "", url: ""),
        purchase: .init(enabled: false, title: "", url: "")
    )
}

/// 会员/授权状态
enum LicenseStatus: Equatable {
    /// 尚未激活（未输入卡密）
    case notActivated
    /// 校验中
    case checking
    /// 有效会员
    case active(expireAt: String)
    /// 已到期，没有权限使用
    case expired(expireAt: String)
    /// 已被封禁
    case banned
    /// 激活信息无效（token 失效等），需重新激活
    case invalid
    /// 网络不可达（放行进入，避免断网时完全不可用；下次回前台再校验）
    case offline
}

// MARK: - API 响应

private struct ActivateResponse: Decodable {
    let code: Int
    let msg: String?
    let token: String?
    let expireAt: String?
    let config: AppConfig?

    enum CodingKeys: String, CodingKey {
        case code, msg, token, config
        case expireAt = "expire_at"
    }
}

private struct VerifyResponse: Decodable {
    let code: Int
    let status: String?
    let msg: String?
    let expireAt: String?
    let config: AppConfig?

    enum CodingKeys: String, CodingKey {
        case code, status, msg, config
        case expireAt = "expire_at"
    }
}

private struct ConfigResponse: Decodable {
    let code: Int
    let config: AppConfig?
}

private struct SimpleResponse: Decodable {
    let code: Int
    let msg: String?
}

// MARK: - 会员管理器

@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    // MARK: 持久化键
    private enum Store {
        static let deviceUUID = "aiLocation.deviceUUID"
        static let token = "aiLocation.licenseToken"
        static let expireAt = "aiLocation.expireAt"
        static let agreedDisclaimerVersion = "aiLocation.agreedDisclaimerVersion"
        static let readAnnouncementAt = "aiLocation.readAnnouncementAt"
    }

    // MARK: 发布状态
    @Published var status: LicenseStatus = .checking
    @Published var config: AppConfig = .empty
    /// 免责声明是否需要展示（首次启动或声明版本更新后）
    @Published var showDisclaimer = false
    /// 需要展示的公告（新公告时弹一次）
    @Published var announcementToShow: AppConfig.Announcement?

    private let defaults = UserDefaults.standard
    private var session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = AppApiConfig.timeout
        cfg.timeoutIntervalForResource = 120
        session = URLSession(configuration: cfg)
    }

    // MARK: 设备标识

    /// 设备唯一标识：首次启动生成并持久化，用于卡密绑定设备
    var deviceUUID: String {
        if let saved = defaults.string(forKey: Store.deviceUUID), !saved.isEmpty {
            return saved
        }
        let uuid = UUID().uuidString
        defaults.set(uuid, forKey: Store.deviceUUID)
        return uuid
    }

    /// 设备名称（方便后台/客服核对）
    var deviceName: String {
        UIDevice.current.name
    }

    var token: String? {
        let t = defaults.string(forKey: Store.token)
        return (t?.isEmpty == false) ? t : nil
    }

    var expireAtText: String {
        defaults.string(forKey: Store.expireAt) ?? ""
    }

    /// 设备 UUID 末 8 位（给用户看/客服核对用）
    var shortDeviceID: String {
        String(deviceUUID.suffix(8)).uppercased()
    }

    // MARK: 激活 / 校验

    /// 卡密激活（也用于到期后续费）
    func activate(cardKey: String) async throws -> String {
        let body: [String: String] = [
            "card_key": cardKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "device_uuid": deviceUUID,
            "device_name": deviceName,
        ]
        let resp: ActivateResponse = try await post(path: "/api/app/license/activate", body: body)
        switch resp.code {
        case 0:
            if let token = resp.token {
                defaults.set(token, forKey: Store.token)
            }
            if let expire = resp.expireAt {
                defaults.set(expire, forKey: Store.expireAt)
            }
            if let cfg = resp.config {
                config = cfg
            }
            status = .active(expireAt: resp.expireAt ?? "")
            return resp.msg ?? "激活成功"
        default:
            throw LicenseError.activationFailed(resp.msg ?? "激活失败，请稍后重试")
        }
    }

    /// 启动/回前台校验会员状态并同步后台配置
    func verify() async {
        guard let token = token else {
            status = .notActivated
            await syncConfigOnly()
            evaluateDisclaimer()
            return
        }
        let body: [String: String] = [
            "device_uuid": deviceUUID,
            "token": token,
            "device_name": deviceName,
        ]
        do {
            let resp: VerifyResponse = try await post(path: "/api/app/license/verify", body: body)
            if let cfg = resp.config {
                config = cfg
            }
            switch (resp.code, resp.status) {
            case (0, "active"):
                if let expire = resp.expireAt {
                    defaults.set(expire, forKey: Store.expireAt)
                }
                status = .active(expireAt: resp.expireAt ?? "")
            case (0, "expired"):
                status = .expired(expireAt: resp.expireAt ?? "")
            case (0, "banned"):
                status = .banned
            default:
                // token 失效等 → 需要重新激活
                defaults.removeObject(forKey: Store.token)
                status = .invalid
            }
        } catch {
            // 网络异常：已激活用户放行使用，避免弱网下完全不可用
            if case .notActivated = status {
                status = .notActivated
            } else if case .checking = status {
                status = .offline
            }
        }
        evaluateDisclaimer()
        evaluateAnnouncement()
    }

    /// 未激活时也拉一次配置（免责声明/公告需要）
    private func syncConfigOnly() async {
        do {
            let resp: ConfigResponse = try await get(path: "/api/app/config")
            if let cfg = resp.config {
                config = cfg
            }
        } catch {
            // 忽略，使用默认配置
        }
    }

    /// 退出登录（清除本地激活信息，重新弹激活页）
    func resetLocalActivation() {
        defaults.removeObject(forKey: Store.token)
        defaults.removeObject(forKey: Store.expireAt)
        status = .notActivated
    }

    // MARK: 免责声明

    private func evaluateDisclaimer() {
        let agreedVersion = defaults.string(forKey: Store.agreedDisclaimerVersion) ?? ""
        let currentVersion = config.disclaimer.version
        showDisclaimer = (agreedVersion != currentVersion) && !config.disclaimer.content.isEmpty
    }

    /// 用户同意免责声明
    func agreeDisclaimer() {
        defaults.set(config.disclaimer.version, forKey: Store.agreedDisclaimerVersion)
        showDisclaimer = false
    }

    // MARK: 公告

    private func evaluateAnnouncement() {
        let ann = config.announcement
        guard ann.enabled, !ann.content.isEmpty else { return }
        let readAt = defaults.string(forKey: Store.readAnnouncementAt) ?? ""
        if readAt != ann.updatedAt {
            announcementToShow = ann
        }
    }

    /// 公告已读
    func markAnnouncementRead() {
        defaults.set(config.announcement.updatedAt, forKey: Store.readAnnouncementAt)
        announcementToShow = nil
    }

    // MARK: 反馈

    /// 提交反馈（文本 + 图片/视频文件）
    func submitFeedback(content: String, fileURLs: [URL]) async throws -> String {
        guard let token = token else {
            throw LicenseError.activationFailed("请先激活后再提交反馈")
        }
        let boundary = "AILocation-\(UUID().uuidString)"
        var request = URLRequest(url: AppApiConfig.baseURL.appendingPathComponent("/api/app/feedback"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        appendField("device_uuid", deviceUUID)
        appendField("token", token)
        appendField("content", content)

        for url in fileURLs {
            let fileName = url.lastPathComponent
            let ext = (fileName as NSString).pathExtension.lowercased()
            let mime: String
            switch ext {
            case "jpg", "jpeg", "png", "gif", "webp", "heic":
                mime = "image/\(ext == "jpg" ? "jpeg" : ext)"
            case "mp4": mime = "video/mp4"
            case "mov": mime = "video/quicktime"
            case "m4v": mime = "video/x-m4v"
            default: mime = "application/octet-stream"
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, _) = try await session.upload(for: request, from: body)
        let resp = try? JSONDecoder().decode(SimpleResponse.self, from: data)
        if let resp, resp.code == 0 {
            return resp.msg ?? "提交成功"
        }
        throw LicenseError.activationFailed(resp?.msg ?? "提交失败，请稍后重试")
    }

    /// 本设备的单条历史反馈（含客服回复）
    struct FeedbackHistoryItem: Identifiable {
        let id: Int
        let content: String
        let createdAt: String
        let replied: Bool
        let replyNote: String
    }

    /// 拉取本设备的历史反馈与客服回复
    func fetchFeedbackHistory() async throws -> [FeedbackHistoryItem] {
        guard let token = token else {
            throw LicenseError.activationFailed("请先激活后再提交反馈")
        }
        var request = URLRequest(url: AppApiConfig.baseURL.appendingPathComponent("/api/app/feedback/list"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_uuid": deviceUUID,
            "token": token,
        ])
        let (data, _) = try await session.data(for: request)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["code"] as? Int, code == 0,
              let items = obj["items"] as? [[String: Any]] else {
            throw LicenseError.activationFailed("获取客服回复失败，请稍后重试")
        }
        return items.compactMap { d in
            guard let id = d["id"] as? Int else { return nil }
            return FeedbackHistoryItem(
                id: id,
                content: d["content"] as? String ?? "",
                createdAt: d["created_at"] as? String ?? "",
                replied: d["replied"] as? Bool ?? false,
                replyNote: d["reply_note"] as? String ?? ""
            )
        }
    }

    // MARK: 底层请求

    private func post<Response: Decodable>(path: String, body: [String: String]) async throws -> Response {
        var request = URLRequest(url: AppApiConfig.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func get<Response: Decodable>(path: String) async throws -> Response {
        let request = URLRequest(url: AppApiConfig.baseURL.appendingPathComponent(path))
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

// MARK: - 错误

enum LicenseError: LocalizedError {
    case activationFailed(String)

    var errorDescription: String? {
        switch self {
        case .activationFailed(let message):
            return message
        }
    }
}
