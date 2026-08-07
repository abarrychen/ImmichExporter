import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case traditionalChinese = "繁體中文"
    case english = "English"

    var id: String { rawValue }
}

enum ExportLayout: String, CaseIterable, Identifiable, Sendable {
    case flat = "全部放在同一個資料夾"
    case year = "依年份分類"
    case yearMonth = "依年份／月份分類"
    case preserve = "保留原始目錄結構"

    var id: String { rawValue }

    func title(for language: AppLanguage) -> String {
        guard language == .english else { return rawValue }
        switch self {
        case .flat: return "Put everything in one folder"
        case .year: return "Organize by year"
        case .yearMonth: return "Organize by year / month"
        case .preserve: return "Preserve the original folder structure"
        }
    }
}

enum ExportOutput: String, CaseIterable, Identifiable, Sendable {
    case folder
    case zip500MB
    case zip1GB
    case zip2GB
    case zip4GB

    var id: String { rawValue }

    var archiveLimitBytes: Int64? {
        switch self {
        case .folder: return nil
        case .zip500MB: return 500 * 1_000_000
        case .zip1GB: return 1 * 1_000_000_000
        case .zip2GB: return 2 * 1_000_000_000
        case .zip4GB: return 4 * 1_000_000_000
        }
    }

    func title(for language: AppLanguage) -> String {
        switch (self, language) {
        case (.folder, .traditionalChinese): return "直接匯出資料夾"
        case (.folder, .english): return "Export as a folder"
        case (.zip500MB, _): return "ZIP — 500 MB / part"
        case (.zip1GB, _): return "ZIP — 1 GB / part"
        case (.zip2GB, _): return "ZIP — 2 GB / part"
        case (.zip4GB, _): return "ZIP — 4 GB / part"
        }
    }
}

struct ImmichUserSource: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let locationName: String
    var userName: String?
    var email: String?

    var displayName: String {
        if let userName, !userName.isEmpty { return "\(userName) — \(id)" }
        if let email, !email.isEmpty { return "\(email) — \(id)" }
        return "\(id) — \(locationName)"
    }
}

struct ImmichAPIUser: Decodable, Sendable {
    let id: String
    let name: String
    let email: String
}

struct ScanSummary: Sendable {
    var fileCount: Int = 0
    var totalBytes: Int64 = 0
    var imageCount: Int = 0
    var videoCount: Int = 0
    var sidecarCount: Int = 0
}

struct ScanProgress: Sendable {
    var examinedCount: Int = 0
    var currentPath: String = ""
}

struct ExportProgress {
    var completed: Int = 0
    var total: Int = 0
    var currentFile: String = ""
    var copiedBytes: Int64 = 0
    var totalBytes: Int64 = 0

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

enum ExporterError: LocalizedError {
    case sourceMissing
    case destinationMissing
    case destinationInsideSource
    case noMediaFound
    case archiveFailed

    var errorDescription: String? {
        switch self {
        case .sourceMissing: return "請先選擇 Immich 使用者的來源資料夾。"
        case .destinationMissing: return "請先選擇匯出目的地。"
        case .destinationInsideSource: return "匯出目的地不能放在來源資料夾裡面。"
        case .noMediaFound: return "來源資料夾中找不到可匯出的照片或影片。"
        case .archiveFailed: return "建立 ZIP 壓縮檔失敗。"
        }
    }

    func description(for language: AppLanguage) -> String {
        guard language == .english else { return errorDescription ?? "未知錯誤" }
        switch self {
        case .sourceMissing: return "Select an Immich user first."
        case .destinationMissing: return "Select an export destination first."
        case .destinationInsideSource: return "The export destination cannot be inside the source folder."
        case .noMediaFound: return "No exportable photos or videos were found in the source folder."
        case .archiveFailed: return "Failed to create the ZIP archive."
        }
    }
}
