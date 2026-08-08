import Foundation

@MainActor
final class ExportManager: ObservableObject {
    static let allAPIUsersID = "__all_immich_users__"
    @Published var language: AppLanguage = .traditionalChinese
    @Published var sourceMode: ExportSourceMode = .fileSystem
    @Published var immichRootURL: URL?
    @Published var availableUsers: [ImmichUserSource] = []
    @Published var selectedUserID: String?
    @Published var immichServerURL = ""
    @Published var immichAPIKey = ""
    @Published var apiUsers: [ImmichAPIUser] = []
    @Published var selectedAPIUserID: String?
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
    private var userNamesRequestID = UUID()
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()
    private var wasScanCancelled = false
    private var exportTask: Task<Void, Never>?
    private var apiDownloadPlans: [ImmichUserDownloadPlan] = []

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

    func setSourceMode(_ mode: ExportSourceMode) {
        guard sourceMode != mode else { return }
        scanTask?.cancel()
        sourceMode = mode
        summary = ScanSummary()
        scanProgress = ScanProgress()
        progress = ExportProgress()
        errorMessage = nil
        if mode == .fileSystem {
            apiDownloadPlans = []
            statusMessage = immichRootURL == nil
                ? text("請選擇 Immich 根目錄。", "Select the Immich root folder.")
                : text("請選擇要掃描的使用者 UUID。", "Select a user UUID to scan.")
        } else {
            scannedFiles = []
            statusMessage = text("請輸入 Immich 網址與 API key，再載入使用者。", "Enter the Immich URL and API key, then load users.")
        }
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

    func selectAPIUser(_ id: String?) {
        selectedAPIUserID = id
        apiDownloadPlans = []
        summary = ScanSummary()
        guard id != nil else { return }
        prepareAPIExport()
    }

    func loadUserNames() {
        guard let endpointURL = Self.usersEndpoint(from: immichServerURL) else {
            errorMessage = text("請輸入有效的 Immich 伺服器網址。", "Enter a valid Immich server URL.")
            return
        }
        let apiKey = immichAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            errorMessage = text("請輸入 Immich API key。", "Enter an Immich API key.")
            return
        }

        userNamesTask?.cancel()
        let requestID = UUID()
        userNamesRequestID = requestID
        isLoadingUserNames = true
        errorMessage = nil
        statusMessage = text("正在從 Immich 讀取使用者名稱…", "Loading user names from Immich…")

        let selectedLanguage = language
        userNamesTask = Task {
            do {
                let apiUsers = try await Self.fetchUsers(from: endpointURL, apiKey: apiKey, language: selectedLanguage)
                guard !Task.isCancelled, self.userNamesRequestID == requestID else { return }
                self.apiUsers = apiUsers.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
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
                guard self.userNamesRequestID == requestID else { return }
                isLoadingUserNames = false
                statusMessage = text("已停止載入使用者。", "Stopped loading users.")
            } catch {
                guard self.userNamesRequestID == requestID else { return }
                isLoadingUserNames = false
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    statusMessage = text("已停止載入使用者。", "Stopped loading users.")
                } else {
                    if let urlError = error as? URLError, urlError.code == .timedOut {
                        errorMessage = text("連線逾時，請檢查 Immich 網址與伺服器是否可連線。", "The connection timed out. Check the Immich URL and server availability.")
                    } else {
                        errorMessage = error.localizedDescription
                    }
                    statusMessage = text("讀取使用者名稱失敗。", "Failed to load user names.")
                }
            }
        }
    }

    func cancelLoadingUsers() {
        guard isLoadingUserNames else { return }
        userNamesRequestID = UUID()
        userNamesTask?.cancel()
        isLoadingUserNames = false
        statusMessage = text("已停止載入使用者。", "Stopped loading users.")
    }

    func prepareAPIExport() {
        guard sourceMode == .immichAPI,
              let selectedUserID = selectedAPIUserID,
              let endpointURL = Self.apiEndpoint(from: immichServerURL, path: "download/info") else {
            errorMessage = ExporterError.apiConfigurationMissing.description(for: language)
            return
        }
        let apiKey = immichAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            errorMessage = ExporterError.apiConfigurationMissing.description(for: language)
            return
        }

        scanTask?.cancel()
        isScanning = true
        errorMessage = nil
        apiDownloadPlans = []
        summary = ScanSummary()
        scanProgress = ScanProgress()
        statusMessage = text("正在向 Immich 取得檔案清單…", "Requesting the file list from Immich…")
        let archiveSize = exportOutput.archiveLimitBytes ?? 1_000_000_000
        let selectedLanguage = language
        let usersToExport: [ImmichAPIUser]
        if selectedUserID == Self.allAPIUsersID {
            usersToExport = apiUsers
        } else if let user = apiUsers.first(where: { $0.id == selectedUserID }) {
            usersToExport = [user]
        } else {
            isScanning = false
            errorMessage = ExporterError.apiConfigurationMissing.description(for: language)
            return
        }

        scanTask = Task {
            do {
                var plans: [ImmichUserDownloadPlan] = []
                var totalFiles = 0
                var totalBytes: Int64 = 0
                for (index, user) in usersToExport.enumerated() {
                    try Task.checkCancellation()
                    statusMessage = text("正在取得第 \(index + 1)／\(usersToExport.count) 位使用者的檔案清單…", "Loading file list for user \(index + 1) of \(usersToExport.count)…")
                    let info = try await Self.fetchDownloadInfo(
                        from: endpointURL,
                        apiKey: apiKey,
                        userID: user.id,
                        archiveSize: archiveSize,
                        language: selectedLanguage
                    )
                    plans.append(ImmichUserDownloadPlan(user: user, info: info))
                    totalFiles += info.assetCount
                    totalBytes += info.totalSize
                    summary = ScanSummary(fileCount: totalFiles, totalBytes: totalBytes)
                }
                guard !Task.isCancelled else { return }
                apiDownloadPlans = plans
                isScanning = false
                let archiveCount = plans.reduce(0) { $0 + $1.info.archives.count }
                statusMessage = totalFiles == 0
                    ? text("所選使用者沒有可下載的檔案。", "The selected users have no downloadable files.")
                    : text("找到 \(totalFiles.formatted()) 個檔案，共 \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))，將分成 \(archiveCount.formatted()) 包。", "Found \(totalFiles.formatted()) files totaling \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) in \(archiveCount.formatted()) parts.")
            } catch is CancellationError {
                isScanning = false
            } catch {
                isScanning = false
                errorMessage = error.localizedDescription
                statusMessage = text("取得 Immich 檔案清單失敗。", "Failed to get the Immich file list.")
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

        scanTask = Task.detached(priority: .userInitiated) { [self, includeSidecars, imageExtensions, videoExtensions] in
            do {
                let result = try Self.scanFiles(
                    at: sourceURL,
                    includeSidecars: includeSidecars,
                    imageExtensions: imageExtensions,
                    videoExtensions: videoExtensions
                ) { [self] progressSummary, progress in
                    Task { @MainActor [self] in
                        guard self.scanID == currentScanID, self.isScanning else { return }
                        self.summary = progressSummary
                        self.scanProgress = progress
                        self.statusMessage = self.text("正在掃描：已掃描 \(progress.examinedCount.formatted()) 個項目，找到 \(progressSummary.fileCount.formatted()) 個檔案。", "Scanning: checked \(progress.examinedCount.formatted()) items and found \(progressSummary.fileCount.formatted()) files.")
                    }
                }

                await MainActor.run {
                    guard self.scanID == currentScanID else { return }
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
                    guard self.scanID == currentScanID else { return }
                    self.isScanning = false
                    self.statusMessage = self.text("掃描已停止。", "Scan stopped.")
                }
            } catch {
                await MainActor.run {
                    guard self.scanID == currentScanID else { return }
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
        if sourceMode == .immichAPI {
            startAPIExport()
            return
        }
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

        exportTask = Task.detached(priority: .userInitiated) { [self] in
            var revealURL: URL?
            var archiveCount = 0
            var currentPartBytes: Int64 = 0
            let currentPartRoot = stagingRoot.appendingPathComponent("part", isDirectory: true)

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
                        let partNumber = archiveCount
                        let archiveURL = Self.nonConflictingURL(
                            in: destinationURL,
                            preferredName: String(format: "%@ Part %03d.zip", exportName, partNumber)
                        )
                        await MainActor.run {
                            self.progress.currentFile = self.text("正在壓縮第 \(partNumber) 包…", "Compressing part \(partNumber)…")
                        }
                        try Self.createZipArchive(from: currentPartRoot, at: archiveURL)
                        try Task.checkCancellation()
                        if revealURL == nil { revealURL = archiveURL }
                        try FileManager.default.removeItem(at: currentPartRoot)
                        try FileManager.default.createDirectory(at: currentPartRoot, withIntermediateDirectories: true)
                        currentPartBytes = 0
                    }

                    await MainActor.run {
                        self.progress.currentFile = fileURL.lastPathComponent
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
                        self.progress.completed = index + 1
                        self.progress.copiedBytes += fileSize
                    }
                    currentPartBytes += fileSize
                }

                if selectedOutput.archiveLimitBytes != nil, currentPartBytes > 0 {
                    archiveCount += 1
                    let partNumber = archiveCount
                    let archiveURL = Self.nonConflictingURL(
                        in: destinationURL,
                        preferredName: String(format: "%@ Part %03d.zip", exportName, partNumber)
                    )
                    await MainActor.run {
                        self.progress.currentFile = self.text("正在壓縮第 \(partNumber) 包…", "Compressing part \(partNumber)…")
                    }
                    try Self.createZipArchive(from: currentPartRoot, at: archiveURL)
                    try Task.checkCancellation()
                    if revealURL == nil { revealURL = archiveURL }
                }

                let finalRevealURL = revealURL
                let finalArchiveCount = archiveCount
                await MainActor.run {
                    self.isExporting = false
                    self.exportedFolderURL = finalRevealURL
                    self.statusMessage = finalArchiveCount > 0
                        ? self.text("匯出完成：\(files.count.formatted()) 個檔案，共 \(finalArchiveCount) 個 ZIP。", "Export complete: \(files.count.formatted()) files in \(finalArchiveCount) ZIP archives.")
                        : self.text("匯出完成：\(files.count.formatted()) 個檔案。", "Export complete: \(files.count.formatted()) files.")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isExporting = false
                    self.statusMessage = self.text("匯出已取消，已完成的檔案會保留。", "Export cancelled. Completed files have been kept.")
                }
            } catch {
                let exportErrorMessage = error.localizedDescription
                await MainActor.run {
                    self.isExporting = false
                    self.errorMessage = exportErrorMessage
                    self.statusMessage = self.text("匯出失敗。", "Export failed.")
                }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func startAPIExport() {
        guard let destinationURL,
              let endpointURL = Self.apiEndpoint(from: immichServerURL, path: "download/archive"),
              selectedAPIUserID != nil else {
            errorMessage = destinationURL == nil
                ? ExporterError.destinationMissing.description(for: language)
                : ExporterError.apiConfigurationMissing.description(for: language)
            return
        }
        let plans = apiDownloadPlans
        let totalFiles = plans.reduce(0) { $0 + $1.info.assetCount }
        let totalBytes = plans.reduce(Int64(0)) { $0 + $1.info.totalSize }
        let totalArchives = plans.reduce(0) { $0 + $1.info.archives.count }
        guard totalFiles > 0 else {
            errorMessage = ExporterError.noMediaFound.description(for: language)
            return
        }
        let apiKey = immichAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            errorMessage = ExporterError.apiConfigurationMissing.description(for: language)
            return
        }

        isExporting = true
        errorMessage = nil
        exportedFolderURL = nil
        progress = ExportProgress(total: totalFiles, totalBytes: totalBytes)
        statusMessage = text("正在從 Immich 下載…", "Downloading from Immich…")

        let selectedOutput = exportOutput
        let selectedLanguage = language
        let isAllUsersExport = selectedAPIUserID == Self.allAPIUsersID
        let exportName = Self.exportFolderName()
        let folderRoot = destinationURL.appendingPathComponent(exportName, isDirectory: true)
        let stagingRoot = destinationURL.appendingPathComponent(".\(exportName)-api-\(UUID().uuidString)", isDirectory: true)

        exportTask = Task.detached(priority: .userInitiated) { [self] in
            var firstResultURL: URL?
            var completedArchiveBytes: Int64 = 0
            var globalPartNumber = 0
            do {
                try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
                if selectedOutput == .folder {
                    try FileManager.default.createDirectory(at: folderRoot, withIntermediateDirectories: true)
                    firstResultURL = folderRoot
                }

                for plan in plans {
                    let userLabel = Self.safeUserLabel(for: plan.user)
                    let userFolder = isAllUsersExport
                        ? folderRoot.appendingPathComponent(userLabel, isDirectory: true)
                        : folderRoot
                    if selectedOutput == .folder {
                        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
                    }

                    for (userPartIndex, archive) in plan.info.archives.enumerated() {
                        try Task.checkCancellation()
                        globalPartNumber += 1
                        let currentGlobalPart = globalPartNumber
                        let partNumber = userPartIndex + 1
                        await MainActor.run {
                            self.progress.currentFile = self.text("正在下載第 \(currentGlobalPart)／\(totalArchives) 包（\(plan.user.name)）…", "Downloading part \(currentGlobalPart) of \(totalArchives) (\(plan.user.name))…")
                        }
                        let temporaryURL = stagingRoot.appendingPathComponent(String(format: "part-%03d.zip", currentGlobalPart))
                        let bytesBeforeArchive = completedArchiveBytes
                        try await Self.downloadArchive(
                            from: endpointURL,
                            apiKey: apiKey,
                            assetIDs: archive.assetIds,
                            to: temporaryURL,
                            language: selectedLanguage
                        ) { writtenBytes, _ in
                            Task { @MainActor [self] in
                                self.progress.copiedBytes = min(totalBytes, bytesBeforeArchive + writtenBytes)
                            }
                        }
                        try Task.checkCancellation()

                        if selectedOutput == .folder {
                            await MainActor.run {
                                self.progress.currentFile = self.text("正在解壓縮第 \(currentGlobalPart) 包…", "Extracting part \(currentGlobalPart)…")
                            }
                            try Self.extractZipArchive(from: temporaryURL, to: userFolder)
                            try FileManager.default.removeItem(at: temporaryURL)
                        } else {
                            let preferredName = isAllUsersExport
                                ? String(format: "%@ %@ Part %03d.zip", exportName, userLabel, partNumber)
                                : String(format: "%@ Part %03d.zip", exportName, partNumber)
                            let finalURL = Self.nonConflictingURL(in: destinationURL, preferredName: preferredName)
                            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
                            if firstResultURL == nil { firstResultURL = finalURL }
                        }

                        await MainActor.run {
                            self.progress.completed += archive.assetIds.count
                            self.progress.copiedBytes = min(totalBytes, bytesBeforeArchive + archive.size)
                        }
                        completedArchiveBytes += archive.size
                    }
                }

                try? FileManager.default.removeItem(at: stagingRoot)
                let resultURL = firstResultURL
                await MainActor.run {
                    self.isExporting = false
                    self.exportedFolderURL = resultURL
                    self.statusMessage = self.text("API 匯出完成：\(totalFiles.formatted()) 個檔案，\(plans.count.formatted()) 位使用者。", "API export complete: \(totalFiles.formatted()) files from \(plans.count.formatted()) users.")
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: stagingRoot)
                await MainActor.run {
                    self.isExporting = false
                    self.statusMessage = self.text("API 匯出已取消，已完成的檔案會保留。", "API export cancelled. Completed files have been kept.")
                }
            } catch {
                try? FileManager.default.removeItem(at: stagingRoot)
                let message = error.localizedDescription
                await MainActor.run {
                    self.isExporting = false
                    self.errorMessage = message
                    self.statusMessage = self.text("API 匯出失敗。", "API export failed.")
                }
            }
        }
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
        } else if sourceMode == .immichAPI {
            if selectedAPIUserID == nil {
                statusMessage = apiUsers.isEmpty
                    ? text("請輸入 Immich 網址與 API key，再載入使用者。", "Enter the Immich URL and API key, then load users.")
                    : text("請選擇要匯出的 Immich 使用者。", "Select the Immich user to export.")
            } else if summary.fileCount > 0 {
                statusMessage = text("找到 \(summary.fileCount.formatted()) 個檔案，共 \(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file))。", "Found \(summary.fileCount.formatted()) files totaling \(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file)).")
            } else {
                statusMessage = text("這位使用者沒有可下載的檔案。", "This user has no downloadable files.")
            }
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
        apiEndpoint(from: input, path: "users")
    }

    private nonisolated static func apiEndpoint(from input: String, path endpointPath: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/api") { path += "/api" }
        components.path = path + "/" + endpointPath
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private nonisolated static func fetchDownloadInfo(
        from endpointURL: URL,
        apiKey: String,
        userID: String,
        archiveSize: Int64,
        language: AppLanguage
    ) async throws -> ImmichDownloadInfo {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "userId": userID,
            "archiveSize": archiveSize
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateAPIResponse(response, data: data, language: language)
        return try JSONDecoder().decode(ImmichDownloadInfo.self, from: data)
    }

    private nonisolated static func downloadArchive(
        from endpointURL: URL,
        apiKey: String,
        assetIDs: [String],
        to destinationURL: URL,
        language: AppLanguage,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["assetIds": assetIDs])
        let downloader = ArchiveDownloader(
            request: request,
            destinationURL: destinationURL,
            language: language,
            progress: progress
        )
        try await withTaskCancellationHandler {
            try await downloader.start()
        } onCancel: {
            downloader.cancel()
        }
    }

    private nonisolated static func validateAPIResponse(
        _ response: URLResponse,
        data: Data?,
        language: AppLanguage
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let serverMessage = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["message"] as? String
            let base = language == .traditionalChinese
                ? "Immich API 回應錯誤（HTTP \(statusCode)）。請檢查 API key、帳號角色與伺服器存取設定。"
                : "Immich API returned HTTP \(statusCode). Check the API key, account role, and server access settings."
            throw NSError(
                domain: "ImmichExporter.API",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: serverMessage.map { "\(base) \($0)" } ?? base]
            )
        }
    }

    private nonisolated static func fetchUsers(from endpointURL: URL, apiKey: String, language: AppLanguage) async throws -> [ImmichAPIUser] {
        var request = URLRequest(url: endpointURL)
        request.timeoutInterval = 15
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
                    ? "Immich API 回應錯誤（HTTP \(statusCode)），請檢查網址、API key 與伺服器的存取設定。"
                    : "Immich API returned HTTP \(statusCode). Check the URL, API key, and server access settings."]
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

    private nonisolated static func extractZipArchive(from archiveURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExporterError.archiveFailed }
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

    private nonisolated static func safeUserLabel(for user: ImmichAPIUser) -> String {
        let preferredName = user.name.isEmpty ? (user.email.isEmpty ? user.id : user.email) : user.name
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let sanitized = preferredName.components(separatedBy: invalidCharacters).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = sanitized.isEmpty ? "User" : sanitized
        return "\(name) — \(user.id.prefix(8))"
    }

    private nonisolated static func exportFolderName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return "Immich Export \(formatter.string(from: Date()))"
    }
}

private final class ArchiveDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let destinationURL: URL
    private let language: AppLanguage
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false

    init(
        request: URLRequest,
        destinationURL: URL,
        language: AppLanguage,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.request = request
        self.destinationURL = destinationURL
        self.language = language
        self.progress = progress
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.downloadTask(with: request)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        let activeTask = task
        lock.unlock()
        activeTask?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                let message = language == .traditionalChinese
                    ? "Immich 下載失敗（HTTP \(statusCode)）。請檢查 API key、帳號角色與伺服器存取設定。"
                    : "Immich download failed with HTTP \(statusCode). Check the API key, account role, and server access settings."
                throw NSError(domain: "ImmichExporter.API", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            finish(with: .success(()))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(with: .failure(error)) }
    }

    private func finish(with result: Result<Void, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        task = nil
        lock.unlock()

        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
}
