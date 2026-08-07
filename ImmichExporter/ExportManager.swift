import Foundation

@MainActor
final class ExportManager: ObservableObject {
    @Published var language: AppLanguage = .traditionalChinese
    @Published var immichRootURL: URL?
    @Published var availableUsers: [ImmichUserSource] = []
    @Published var selectedUserID: String?
    @Published var immichServerURL = ""
    @Published var immichAPIKey = ""
    @Published var sourceURL: URL?
    @Published var destinationURL: URL?
    @Published var layout: ExportLayout = .flat
    @Published var exportOutput: ExportOutput = .folder
    @Published var includeSidecars = false
    @Published var summary = ScanSummary()
    @Published var scanProgress = ScanProgress()
    @Published var progress = ExportProgress()
    @Published var isScanning = false
    @Published var isDiscoveringUsers = false
    @Published var isLoadingUserNames = false
    @Published var isExporting = false
    @Published var statusMessage = "請選擇 Immich 根目錄。"
    @Published var errorMessage: String?
    @Published var exportedFolderURL: URL?

    private var scannedFiles: [URL] = []
    private var discoveryTask: Task<Void, Never>?
    private var userNamesTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()
    private var wasScanCancelled = false
    private var exportTask: Task<Void, Never>?

    private let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff",
        "dng", "nef", "cr2", "cr3", "arw", "raf", "orf", "rw2", "avif"
    ]

    private let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "3gp", "mts", "m2ts", "webm", "mpg", "mpeg"
    ]

    func setLanguage(_ newLanguage: AppLanguage) {
        language = newLanguage
        refreshStatusForLanguage()
    }

    func configureImmichRoot(_ rootURL: URL) {
        discoveryTask?.cancel()
        scanTask?.cancel()
        scanID = UUID()
        immichRootURL = rootURL.standardizedFileURL
        availableUsers = []
        selectedUserID = nil
        sourceURL = nil
        scannedFiles = []
        summary = ScanSummary()
        scanProgress = ScanProgress()
        wasScanCancelled = false
        isScanning = false
        isDiscoveringUsers = true
        errorMessage = nil
        statusMessage = text("正在尋找 Immich 使用者 UUID…", "Looking for Immich user UUIDs…")

        let selectedRootURL = rootURL.standardizedFileURL
        discoveryTask = Task {
            do {
                let users = try await Task.detached(priority: .userInitiated) {
                    try Self.discoverUserSources(under: selectedRootURL)
                }.value
                guard !Task.isCancelled else { return }
                availableUsers = users
                isDiscoveringUsers = false
                statusMessage = users.isEmpty
                    ? text("找不到使用者 UUID，請確認選擇的是 Immich 根目錄。", "No user UUIDs were found. Make sure you selected the Immich root folder.")
                    : text("找到 \(users.count.formatted()) 位使用者，請選擇要掃描的 UUID。", "Found \(users.count.formatted()) users. Select a UUID to scan.")
            } catch is CancellationError {
                isDiscoveringUsers = false
            } catch {
                isDiscoveringUsers = false
                errorMessage = error.localizedDescription
                statusMessage = text("搜尋使用者 UUID 失敗。", "Failed to find user UUIDs.")
            }
        }
    }

    func selectUser(_ id: String?) {
        selectedUserID = id
        guard let id, let user = availableUsers.first(where: { $0.id == id }) else {
            sourceURL = nil
            return
        }
        sourceURL = user.url
        scan()
    }

    func loadUserNames() {
        guard let endpointURL = Self.usersEndpoint(from: immichServerURL) else {
            errorMessage = text("請輸入有效的 Immich 伺服器網址。", "Enter a valid Immich server URL.")
            return
        }
        let apiKey = immichAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            errorMessage = text("請輸入具有 user.read 權限的 Immich API key。", "Enter an Immich API key with the user.read permission.")
            return
        }

        userNamesTask?.cancel()
        isLoadingUserNames = true
        errorMessage = nil
        statusMessage = text("正在從 Immich 讀取使用者名稱…", "Loading user names from Immich…")

        let selectedLanguage = language
        userNamesTask = Task {
            do {
                let apiUsers = try await Self.fetchUsers(from: endpointURL, apiKey: apiKey, language: selectedLanguage)
                guard !Task.isCancelled else { return }
                let usersByID = Dictionary(uniqueKeysWithValues: apiUsers.map { ($0.id.lowercased(), $0) })
                availableUsers = availableUsers.map { source in
                    guard let apiUser = usersByID[source.id.lowercased()] else { return source }
                    var updatedSource = source
                    updatedSource.userName = apiUser.name
                    updatedSource.email = apiUser.email
                    return updatedSource
                }
                let matchedCount = availableUsers.filter { $0.userName != nil || $0.email != nil }.count
                isLoadingUserNames = false
                statusMessage = text("已取得 \(matchedCount.formatted()) 位使用者的名稱。", "Loaded names for \(matchedCount.formatted()) users.")
            } catch is CancellationError {
                isLoadingUserNames = false
            } catch {
                isLoadingUserNames = false
                errorMessage = error.localizedDescription
                statusMessage = text("讀取使用者名稱失敗。", "Failed to load user names.")
            }
        }
    }

    func scan() {
        guard let sourceURL else {
            errorMessage = ExporterError.sourceMissing.description(for: language)
            return
        }

        scanTask?.cancel()
        let currentScanID = UUID()
        scanID = currentScanID
        isScanning = true
        wasScanCancelled = false
        errorMessage = nil
        statusMessage = text("正在掃描來源資料夾…", "Scanning the source folder…")
        scannedFiles = []
        summary = ScanSummary()
        scanProgress = ScanProgress()

        scanTask = Task.detached(priority: .userInitiated) { [weak self, includeSidecars, imageExtensions, videoExtensions] in
            do {
                let result = try Self.scanFiles(
                    at: sourceURL,
                    includeSidecars: includeSidecars,
                    imageExtensions: imageExtensions,
                    videoExtensions: videoExtensions
                ) { [weak self] progressSummary, progress in
                    Task { @MainActor in
                        guard let self, self.scanID == currentScanID, self.isScanning else { return }
                        self.summary = progressSummary
                        self.scanProgress = progress
                        self.statusMessage = self.text("正在掃描：已掃描 \(progress.examinedCount.formatted()) 個項目，找到 \(progressSummary.fileCount.formatted()) 個檔案。", "Scanning: checked \(progress.examinedCount.formatted()) items and found \(progressSummary.fileCount.formatted()) files.")
                    }
                }

                await MainActor.run {
                    guard let self, self.scanID == currentScanID else { return }
                    self.scannedFiles = result.files
                    self.summary = result.summary
                    self.scanProgress = result.progress
                    self.isScanning = false
                    self.statusMessage = result.files.isEmpty
                        ? self.text("沒有找到可匯出的照片或影片。", "No exportable photos or videos were found.")
                        : self.text("找到 \(result.summary.fileCount.formatted()) 個檔案，共 \(ByteCountFormatter.string(fromByteCount: result.summary.totalBytes, countStyle: .file))。", "Found \(result.summary.fileCount.formatted()) files totaling \(ByteCountFormatter.string(fromByteCount: result.summary.totalBytes, countStyle: .file)).")
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self, self.scanID == currentScanID else { return }
                    self.isScanning = false
                    self.statusMessage = self.text("掃描已停止。", "Scan stopped.")
                }
            } catch {
                await MainActor.run {
                    guard let self, self.scanID == currentScanID else { return }
                    self.isScanning = false
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = self.text("掃描失敗。", "Scan failed.")
                }
            }
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanID = UUID()
        isScanning = false
        scannedFiles = []
        summary = ScanSummary()
        scanProgress = ScanProgress()
        wasScanCancelled = true
        statusMessage = text("掃描已停止，請重新選擇使用者或再次掃描。", "Scan stopped. Select another user or scan again.")
    }

    func startExport() {
        guard let sourceURL else {
            errorMessage = ExporterError.sourceMissing.description(for: language)
            return
        }
        guard let destinationURL else {
            errorMessage = ExporterError.destinationMissing.description(for: language)
            return
        }
        let standardizedSourcePath = sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
        let standardizedDestinationPath = destinationURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard standardizedDestinationPath != standardizedSourcePath,
              !standardizedDestinationPath.hasPrefix(standardizedSourcePath + "/") else {
            errorMessage = ExporterError.destinationInsideSource.description(for: language)
            return
        }
        guard !scannedFiles.isEmpty else {
            errorMessage = ExporterError.noMediaFound.description(for: language)
            return
        }

        isExporting = true
        errorMessage = nil
        exportedFolderURL = nil
        progress = ExportProgress(total: scannedFiles.count, totalBytes: summary.totalBytes)
        statusMessage = text("正在匯出…", "Exporting…")

        let files = scannedFiles
        let selectedLayout = layout
        let selectedOutput = exportOutput
        let exportName = Self.exportFolderName()
        let folderExportRoot = destinationURL.appendingPathComponent(exportName, isDirectory: true)
        let stagingRoot = destinationURL.appendingPathComponent(".\(exportName)-staging-\(UUID().uuidString)", isDirectory: true)

        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            var revealURL: URL?
            var archiveCount = 0
            var currentPartBytes: Int64 = 0
            var currentPartRoot = stagingRoot.appendingPathComponent("part", isDirectory: true)

            defer {
                if selectedOutput.archiveLimitBytes != nil {
                    try? FileManager.default.removeItem(at: stagingRoot)
                }
            }

            do {
                if selectedOutput.archiveLimitBytes == nil {
                    try FileManager.default.createDirectory(at: folderExportRoot, withIntermediateDirectories: true)
                    revealURL = folderExportRoot
                } else {
                    try FileManager.default.createDirectory(at: currentPartRoot, withIntermediateDirectories: true)
                }

                for (index, fileURL) in files.enumerated() {
                    try Task.checkCancellation()
                    let resource = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
                    let fileSize = Int64(resource.fileSize ?? 0)

                    if let archiveLimit = selectedOutput.archiveLimitBytes,
                       currentPartBytes > 0,
                       currentPartBytes + fileSize > archiveLimit {
                        archiveCount += 1
                        let archiveURL = Self.nonConflictingURL(
                            in: destinationURL,
                            preferredName: String(format: "%@ Part %03d.zip", exportName, archiveCount)
                        )
                        await MainActor.run {
                            self?.progress.currentFile = self?.text("正在壓縮第 \(archiveCount) 包…", "Compressing part \(archiveCount)…") ?? ""
                        }
                        try Self.createZipArchive(from: currentPartRoot, at: archiveURL)
                        try Task.checkCancellation()
                        if revealURL == nil { revealURL = archiveURL }
                        try FileManager.default.removeItem(at: currentPartRoot)
                        try FileManager.default.createDirectory(at: currentPartRoot, withIntermediateDirectories: true)
                        currentPartBytes = 0
                    }

                    await MainActor.run {
                        self?.progress.currentFile = fileURL.lastPathComponent
                    }
                    let activeExportRoot = selectedOutput.archiveLimitBytes == nil ? folderExportRoot : currentPartRoot
                    let targetDirectory = try Self.targetDirectory(
                        for: fileURL,
                        sourceRoot: sourceURL,
                        exportRoot: activeExportRoot,
                        layout: selectedLayout,
                        resource: resource
                    )
                    try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
                    let targetURL = Self.nonConflictingURL(in: targetDirectory, preferredName: fileURL.lastPathComponent)
                    try FileManager.default.copyItem(at: fileURL, to: targetURL)

                    await MainActor.run {
                        self?.progress.completed = index + 1
                        self?.progress.copiedBytes += fileSize
                    }
                    currentPartBytes += fileSize
                }

                if selectedOutput.archiveLimitBytes != nil, currentPartBytes > 0 {
                    archiveCount += 1
                    let archiveURL = Self.nonConflictingURL(
                        in: destinationURL,
                        preferredName: String(format: "%@ Part %03d.zip", exportName, archiveCount)
                    )
                    await MainActor.run {
                        self?.progress.currentFile = self?.text("正在壓縮第 \(archiveCount) 包…", "Compressing part \(archiveCount)…") ?? ""
                    }
                    try Self.createZipArchive(from: currentPartRoot, at: archiveURL)
                    try Task.checkCancellation()
                    if revealURL == nil { revealURL = archiveURL }
                }

                await MainActor.run {
                    self?.isExporting = false
                    self?.exportedFolderURL = revealURL
                    self?.statusMessage = archiveCount > 0
                        ? self?.text("匯出完成：\(files.count.formatted()) 個檔案，共 \(archiveCount) 個 ZIP。", "Export complete: \(files.count.formatted()) files in \(archiveCount) ZIP archives.") ?? ""
                        : self?.text("匯出完成：\(files.count.formatted()) 個檔案。", "Export complete: \(files.count.formatted()) files.") ?? ""
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.isExporting = false
                    self?.statusMessage = self?.text("匯出已取消，已完成的檔案會保留。", "Export cancelled. Completed files have been kept.") ?? ""
                }
            } catch {
                await MainActor.run {
                    self?.isExporting = false
                    self?.errorMessage = error.localizedDescription
                    self?.statusMessage = self?.text("匯出失敗。", "Export failed.") ?? ""
                }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func text(_ traditionalChinese: String, _ english: String) -> String {
        language == .traditionalChinese ? traditionalChinese : english
    }

    private func refreshStatusForLanguage() {
        if isDiscoveringUsers {
            statusMessage = text("正在尋找 Immich 使用者 UUID…", "Looking for Immich user UUIDs…")
        } else if isLoadingUserNames {
            statusMessage = text("正在從 Immich 讀取使用者名稱…", "Loading user names from Immich…")
        } else if isScanning {
            statusMessage = text("正在掃描：已掃描 \(scanProgress.examinedCount.formatted()) 個項目，找到 \(summary.fileCount.formatted()) 個檔案。", "Scanning: checked \(scanProgress.examinedCount.formatted()) items and found \(summary.fileCount.formatted()) files.")
        } else if isExporting {
            statusMessage = text("正在匯出…", "Exporting…")
        } else if immichRootURL == nil {
            statusMessage = text("請選擇 Immich 根目錄。", "Select the Immich root folder.")
        } else if availableUsers.isEmpty {
            statusMessage = text("找不到使用者 UUID，請確認選擇的是 Immich 根目錄。", "No user UUIDs were found. Make sure you selected the Immich root folder.")
        } else if sourceURL == nil {
            statusMessage = text("找到 \(availableUsers.count.formatted()) 位使用者，請選擇要掃描的 UUID。", "Found \(availableUsers.count.formatted()) users. Select a UUID to scan.")
        } else if wasScanCancelled {
            statusMessage = text("掃描已停止，請重新選擇使用者或再次掃描。", "Scan stopped. Select another user or scan again.")
        } else if summary.fileCount > 0 {
            statusMessage = text("找到 \(summary.fileCount.formatted()) 個檔案，共 \(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file))。", "Found \(summary.fileCount.formatted()) files totaling \(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file)).")
        } else {
            statusMessage = text("沒有找到可匯出的照片或影片。", "No exportable photos or videos were found.")
        }
    }

    private nonisolated static func discoverUserSources(under rootURL: URL) throws -> [ImmichUserSource] {
        let candidates: [(url: URL, locationName: String)] = [
            (rootURL.appendingPathComponent("library/library", isDirectory: true), "library"),
            (rootURL.appendingPathComponent("library/upload", isDirectory: true), "upload"),
            (rootURL.appendingPathComponent("library", isDirectory: true), "library"),
            (rootURL.appendingPathComponent("upload", isDirectory: true), "upload")
        ]
        var usersByID: [String: ImmichUserSource] = [:]
        let keys: Set<URLResourceKey> = [.isDirectoryKey]

        for candidate in candidates {
            try Task.checkCancellation()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let children = try FileManager.default.contentsOfDirectory(
                at: candidate.url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            for childURL in children {
                try Task.checkCancellation()
                let id = childURL.lastPathComponent
                guard UUID(uuidString: id) != nil,
                      try childURL.resourceValues(forKeys: keys).isDirectory == true,
                      usersByID[id.lowercased()] == nil else { continue }
                usersByID[id.lowercased()] = ImmichUserSource(
                    id: id,
                    url: childURL,
                    locationName: candidate.locationName,
                    userName: nil,
                    email: nil
                )
            }
        }

        return usersByID.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private nonisolated static func usersEndpoint(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/api") { path += "/api" }
        components.path = path + "/users"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private nonisolated static func fetchUsers(from endpointURL: URL, apiKey: String, language: AppLanguage) async throws -> [ImmichAPIUser] {
        var request = URLRequest(url: endpointURL)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(
                domain: "ImmichExporter.API",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: language == .traditionalChinese
                    ? "Immich API 回應錯誤（HTTP \(statusCode)），請檢查網址、API key 與 user.read 權限。"
                    : "Immich API returned HTTP \(statusCode). Check the URL, API key, and user.read permission."]
            )
        }
        return try JSONDecoder().decode([ImmichAPIUser].self, from: data)
    }

    private nonisolated static func createZipArchive(from sourceURL: URL, at archiveURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", sourceURL.path, archiveURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: archiveURL)
            throw ExporterError.archiveFailed
        }
    }

    private nonisolated static func scanFiles(
        at sourceURL: URL,
        includeSidecars: Bool,
        imageExtensions: Set<String>,
        videoExtensions: Set<String>,
        progressHandler: @escaping @Sendable (ScanSummary, ScanProgress) -> Void
    ) throws -> (files: [URL], summary: ScanSummary, progress: ScanProgress) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            throw ExporterError.sourceMissing
        }

        var files: [URL] = []
        var summary = ScanSummary()
        var progress = ScanProgress()
        var lastUpdate = ContinuousClock.now

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            progress.examinedCount += 1
            progress.currentPath = fileURL.path(percentEncoded: false)

            let now = ContinuousClock.now
            if progress.examinedCount == 1 || now - lastUpdate >= .milliseconds(100) {
                progressHandler(summary, progress)
                lastUpdate = now
            }

            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }

            let ext = fileURL.pathExtension.lowercased()
            let isImage = imageExtensions.contains(ext)
            let isVideo = videoExtensions.contains(ext)
            let isSidecar = includeSidecars && ext == "xmp"
            guard isImage || isVideo || isSidecar else { continue }

            files.append(fileURL)
            summary.fileCount += 1
            summary.totalBytes += Int64(values.fileSize ?? 0)
            if isImage { summary.imageCount += 1 }
            if isVideo { summary.videoCount += 1 }
            if isSidecar { summary.sidecarCount += 1 }
        }

        progressHandler(summary, progress)

        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (files, summary, progress)
    }

    private nonisolated static func targetDirectory(
        for fileURL: URL,
        sourceRoot: URL,
        exportRoot: URL,
        layout: ExportLayout,
        resource: URLResourceValues
    ) throws -> URL {
        switch layout {
        case .flat:
            return exportRoot
        case .year, .yearMonth:
            let date = resource.creationDate ?? resource.contentModificationDate ?? Date()
            let calendar = Calendar(identifier: .gregorian)
            let year = String(calendar.component(.year, from: date))
            if layout == .year {
                return exportRoot.appendingPathComponent(year, isDirectory: true)
            }
            let month = String(format: "%02d", calendar.component(.month, from: date))
            return exportRoot
                .appendingPathComponent(year, isDirectory: true)
                .appendingPathComponent(month, isDirectory: true)
        case .preserve:
            let sourceComponents = sourceRoot.standardizedFileURL.pathComponents
            let fileComponents = fileURL.deletingLastPathComponent().standardizedFileURL.pathComponents
            let relativeComponents = Array(fileComponents.dropFirst(sourceComponents.count))
            return relativeComponents.reduce(exportRoot) { partial, component in
                partial.appendingPathComponent(component, isDirectory: true)
            }
        }
    }

    private nonisolated static func nonConflictingURL(in directory: URL, preferredName: String) -> URL {
        let manager = FileManager.default
        let preferred = directory.appendingPathComponent(preferredName)
        guard manager.fileExists(atPath: preferred.path) else { return preferred }

        let nsName = preferredName as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var index = 2

        while true {
            let candidateName = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private nonisolated static func exportFolderName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return "Immich Export \(formatter.string(from: Date()))"
    }
}
