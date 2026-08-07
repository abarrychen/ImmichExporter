import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var manager = ExportManager()
    @State private var showUserLookup = false

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    sourceSection
                    userLookupSection
                    summarySection
                    optionsSection
                    destinationSection
                    progressSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 12)
            }

            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
        .alert(tr("發生錯誤", "Error"), isPresented: Binding(
            get: { manager.errorMessage != nil },
            set: { if !$0 { manager.errorMessage = nil } }
        )) {
            Button(tr("好", "OK"), role: .cancel) { manager.errorMessage = nil }
        } message: {
            Text(manager.errorMessage ?? tr("未知錯誤", "Unknown error"))
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Immich 使用者媒體匯出工具", "Immich User Media Exporter"))
                    .font(.largeTitle.bold())
                Text(tr("選擇 NAS 上的 Immich 根目錄，工具會自動找出使用者 UUID；選擇使用者後即可掃描並匯出原始照片與影片。", "Select the Immich root folder on your NAS. The app finds user UUIDs automatically, then scans and exports the selected user's original media."))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { manager.language },
                set: { manager.setLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.rawValue).tag(language)
                }
            }
            .labelsHidden()
            .frame(width: 125)
        }
    }

    private var sourceSection: some View {
        GroupBox(tr("1. Immich 來源", "1. Immich Source")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    pathField(manager.immichRootURL, placeholder: tr("尚未選擇，例如 …/docker/immich", "Not selected, e.g. …/docker/immich"))
                    Button(tr("選擇 Immich 目錄…", "Choose Immich Folder…")) { chooseSource() }
                        .disabled(manager.isExporting || manager.isDiscoveringUsers)
                }

                HStack(spacing: 12) {
                    Picker(tr("使用者 UUID", "User UUID"), selection: Binding(
                        get: { manager.selectedUserID },
                        set: { manager.selectUser($0) }
                    )) {
                        Text(manager.isDiscoveringUsers ? tr("正在搜尋…", "Searching…") : tr("請選擇使用者", "Select a user"))
                            .tag(String?.none)
                        ForEach(manager.availableUsers) { user in
                            Text(user.displayName)
                                .tag(Optional(user.id))
                        }
                    }
                    .disabled(manager.availableUsers.isEmpty || manager.isScanning || manager.isExporting)

                    if manager.isDiscoveringUsers {
                        ProgressView().controlSize(.small)
                    }

                    if !manager.isScanning {
                        Button(tr("重新掃描", "Scan Again")) { manager.scan() }
                            .disabled(manager.sourceURL == nil || manager.isExporting)
                    }
                }

            }
            .padding(.vertical, 6)
        }
    }

    private var userLookupSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $showUserLookup) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        TextField(tr("Immich 網址，例如 http://nas:2283", "Immich URL, e.g. http://nas:2283"), text: $manager.immichServerURL)
                        SecureField(tr("API key（需 user.read）", "API key (requires user.read)"), text: $manager.immichAPIKey)
                        Button(tr("載入名稱", "Load Names")) { manager.loadUserNames() }
                            .disabled(manager.availableUsers.isEmpty || manager.isLoadingUserNames)
                        if manager.isLoadingUserNames {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Text(tr("這是選用功能。若只用 UUID 辨識使用者，不需要輸入網址或 API key。API key 不會寫入磁碟；建議使用 HTTPS。", "Optional: leave this disabled if UUIDs are sufficient. The API key is not saved to disk; HTTPS is recommended."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            } label: {
                Text(tr("選用：顯示 UUID 對應的使用者名稱", "Optional: Show User Names for UUIDs"))
                    .font(.headline)
            }
        }
    }

    private var summarySection: some View {
        GroupBox(tr("2. 掃描結果", "2. Scan Results")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 26) {
                    metric(tr("全部檔案", "All Files"), manager.summary.fileCount.formatted())
                    metric(tr("照片", "Photos"), manager.summary.imageCount.formatted())
                    metric(tr("影片", "Videos"), manager.summary.videoCount.formatted())
                    metric(tr("容量", "Size"), ByteCountFormatter.string(fromByteCount: manager.summary.totalBytes, countStyle: .file))
                    if manager.includeSidecars {
                        metric("XMP", manager.summary.sidecarCount.formatted())
                    }
                    Spacer()
                }

                if manager.isScanning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(tr("已掃描 \(manager.scanProgress.examinedCount.formatted()) 個項目，找到 \(manager.summary.fileCount.formatted()) 個可匯出檔案", "Scanned \(manager.scanProgress.examinedCount.formatted()) items and found \(manager.summary.fileCount.formatted()) exportable files"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(manager.scanProgress.currentPath.isEmpty ? tr("正在讀取來源資料夾…", "Reading source folder…") : manager.scanProgress.currentPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var optionsSection: some View {
        GroupBox(tr("3. 匯出方式", "3. Export Options")) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(tr("輸出形式", "Output Format"), selection: $manager.exportOutput) {
                    ForEach(ExportOutput.allCases) { output in
                        Text(output.title(for: manager.language)).tag(output)
                    }
                }
                .pickerStyle(.menu)
                .disabled(manager.isExporting)

                Picker(tr("資料夾結構", "Folder Structure"), selection: $manager.layout) {
                    ForEach(ExportLayout.allCases) { item in
                        Text(item.title(for: manager.language)).tag(item)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(manager.isExporting)

                Toggle(tr("同時匯出 XMP 中繼資料檔", "Also export XMP metadata files"), isOn: $manager.includeSidecars)
                    .disabled(manager.isExporting)
                    .onChange(of: manager.includeSidecars) { _, _ in
                        if manager.sourceURL != nil { manager.scan() }
                    }

                Text(tr("檔名重複時會自動改成「檔名 (2)」，不會覆蓋任何檔案。", "Duplicate names are changed to “filename (2)” automatically. Existing files are never overwritten."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if manager.exportOutput.archiveLimitBytes != nil {
                    Text(tr("ZIP 會依未壓縮檔案大小分包；實際壓縮檔大小可能略有不同。單一檔案超過上限時會獨立成包。", "ZIP parts are grouped by uncompressed file size, so final archive sizes may vary slightly. A file larger than the limit is placed in its own archive."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var destinationSection: some View {
        GroupBox(tr("4. 匯出目的地", "4. Export Destination")) {
            HStack(spacing: 12) {
                pathField(manager.destinationURL, placeholder: tr("尚未選擇", "Not selected"))
                Button(tr("選擇…", "Choose…")) { chooseDestination() }
                    .disabled(manager.isExporting)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if manager.isExporting || manager.progress.completed > 0 {
            GroupBox(tr("匯出進度", "Export Progress")) {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: manager.progress.fraction)
                    HStack {
                        Text("\(manager.progress.completed.formatted()) / \(manager.progress.total.formatted())")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: manager.progress.copiedBytes, countStyle: .file))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(manager.progress.currentFile)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(manager.statusMessage)
                if let folder = manager.exportedFolderURL {
                    Button(tr("在 Finder 中顯示匯出結果", "Show Export in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    .buttonStyle(.link)
                }
            }
            .foregroundStyle(.secondary)

            Spacer()

            if manager.isExporting {
                Button(tr("取消", "Cancel"), role: .destructive) { manager.cancelExport() }
            } else if manager.isScanning {
                Button(tr("停止掃描", "Stop Scan"), role: .destructive) { manager.cancelScan() }
            } else {
                Button(tr("開始匯出", "Start Export")) { manager.startExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.sourceURL == nil || manager.destinationURL == nil || manager.summary.fileCount == 0 || manager.isScanning)
            }
        }
    }

    private func pathField(_ url: URL?, placeholder: String) -> some View {
        Text(url?.path ?? placeholder)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(url == nil ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title3.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = tr("選擇 Immich 根目錄", "Choose Immich Root Folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            manager.configureImmichRoot(url)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = tr("選擇匯出目的地", "Choose Export Destination")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK {
            manager.destinationURL = panel.url
        }
    }

    private func tr(_ traditionalChinese: String, _ english: String) -> String {
        manager.language == .traditionalChinese ? traditionalChinese : english
    }
}
