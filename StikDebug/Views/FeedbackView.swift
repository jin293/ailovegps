//
//  FeedbackView.swift
//  StikDebug
//
//  精苹果 · 意见反馈：问题描述 + 图片/视频附件提交到后台
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct FeedbackView: View {
    @ObservedObject private var license = LicenseManager.shared
    @State private var content = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var pendingFileURLs: [URL] = []
    @State private var submitting = false
    @State private var submitted = false
    @State private var errorMessage: String?
    @State private var history: [LicenseManager.FeedbackHistoryItem] = []
    @State private var historyLoading = false

    var body: some View {
        Form {
            Section("问题描述") {
                TextEditor(text: $content)
                    .frame(minHeight: 120)
            }

            Section("添加附件（图片/视频，最多 6 个）") {
                PhotosPicker(
                    selection: $selectedItems,
                    maxSelectionCount: 6,
                    matching: .any(of: [.images, .videos])
                ) {
                    Label("从相册选择", systemImage: "photo.badge.plus")
                }

                if !pendingFileURLs.isEmpty {
                    ForEach(pendingFileURLs, id: \.self) { url in
                        HStack {
                            Image(systemName: isVideo(url) ? "video.fill" : "photo.fill")
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                pendingFileURLs.removeAll { $0 == url }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    submit()
                } label: {
                    HStack {
                        if submitting {
                            ProgressView().controlSize(.small)
                        }
                        Text(submitting ? "正在提交…" : "提交反馈")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(submitting || (content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingFileURLs.isEmpty))
            }

            if submitted {
                Section {
                    Label("提交成功，感谢您的反馈！客服回复后会显示在下方。", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }

            Section("客服回复") {
                if historyLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("加载中…")
                            .foregroundStyle(.secondary)
                    }
                } else if history.isEmpty {
                    Text("暂无历史反馈。提交反馈后，客服的回复会显示在这里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.content)
                                .font(.subheadline)
                            Text(item.createdAt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if item.replied, !item.replyNote.isEmpty {
                                Divider()
                                Label {
                                    Text(item.replyNote)
                                        .font(.footnote)
                                } icon: {
                                    Image(systemName: "bubble.left.and.text.bubble.right")
                                }
                                .foregroundStyle(.green)
                            } else {
                                Text("待客服回复")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Button {
                    loadHistory()
                } label: {
                    Label("刷新回复", systemImage: "arrow.clockwise")
                }
            }
        }
        .navigationTitle("意见反馈")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadHistory() }
        .onChange(of: selectedItems) { _, newItems in
            loadPickedItems(newItems)
        }
    }

    /// 拉取本设备的历史反馈与客服回复
    private func loadHistory() {
        historyLoading = true
        Task {
            defer { historyLoading = false }
            do {
                history = try await license.fetchFeedbackHistory()
            } catch {
                // 静默失败：不干扰提交流程，仅保留空列表
            }
        }
    }

    private func isVideo(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    /// 把相册选中的项目拷贝为临时文件（上传用）
    private func loadPickedItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        selectedItems = []
        Task {
            var loaded: [URL] = []
            for item in items where pendingFileURLs.count + loaded.count < 6 {
                if let url = try? await copyToTemp(item) {
                    loaded.append(url)
                }
            }
            pendingFileURLs.append(contentsOf: loaded)
        }
    }

    private func copyToTemp(_ item: PhotosPickerItem) async throws -> URL {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw LicenseError.activationFailed("附件读取失败，请重试")
        }
        // 从内容类型推断扩展名（图片/视频均适用）
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? ""
        // 用随机名避免冲突，保留原扩展名
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "dat" : ext)
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest)
        return dest
    }

    private func submit() {
        submitting = true
        errorMessage = nil
        let files = pendingFileURLs
        let text = content
        Task {
            do {
                _ = try await license.submitFeedback(content: text, fileURLs: files)
                submitted = true
                content = ""
                pendingFileURLs = []
                // 清理临时文件
                files.forEach { try? FileManager.default.removeItem(at: $0) }
                loadHistory()
            } catch {
                errorMessage = error.localizedDescription
            }
            submitting = false
        }
    }
}
