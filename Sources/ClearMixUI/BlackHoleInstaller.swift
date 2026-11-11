import ClearMixCore
import CryptoKit
import Foundation

/// Installs the official BlackHole 2ch package from inside the app, so the user
/// never has to open Terminal or Homebrew.
///
/// BlackHole is an audio driver: it lives in `/Library/Audio/Plug-Ins/HAL`, so
/// the install needs root. The package is downloaded to a temporary directory,
/// checked against a pinned version and SHA-256, then handed to `installer` with
/// an admin prompt. The package's own postinstall restarts `coreaudiod`, so the
/// device appears without a reboot.
///
/// BlackHole is GPL-3.0 by Existential Audio and ClearMix does not bundle it:
/// only their signed, notarized installer is downloaded and run.
enum BlackHoleInstaller {
    /// Pinned, so a changed or hijacked download cannot install something else.
    static let version = "0.7.1"
    static let downloadURL = URL(string: "https://existential.audio/downloads/BlackHole2ch-\(version).pkg")!
    static let sha256 = "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf"
    /// Existential Audio's Developer ID Installer team.
    static let teamID = "Q5C99V536K"

    enum InstallError: LocalizedError {
        case download(String)
        case checksumMismatch
        case notSignedByVendor(String)
        case installFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .download(let reason):
                return "BlackHole indirilemedi: \(reason)"
            case .checksumMismatch:
                return "İndirilen paket beklenen sürümle eşleşmiyor."
            case .notSignedByVendor(let signature):
                return "Paket Existential Audio tarafından imzalanmamış:\n\(signature)"
            case .installFailed(let reason):
                return "Kurulum tamamlanamadı: \(reason)"
            case .cancelled:
                return "Kurulum iptal edildi."
            }
        }
    }

    /// Downloads the pinned installer into a temporary directory.
    static func downloadPackage() async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw InstallError.download("HTTP \(http.statusCode)")
        }
        let destination = temporary.deletingLastPathComponent()
            .appendingPathComponent("BlackHole2ch-\(version).pkg")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw InstallError.download(error.localizedDescription)
        }
        return destination
    }

    /// Rejects anything that is not byte-for-byte our pinned package, signed by
    /// Existential Audio's Developer ID Installer certificate.
    static func verify(_ package: URL) throws {
        let data = try Data(contentsOf: package)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw InstallError.checksumMismatch }

        let signature = try run("/usr/sbin/pkgutil", ["--check-signature", package.path])
        guard signature.contains(teamID) else {
            throw InstallError.notSignedByVendor(signature)
        }
    }

    /// Runs the package with administrator rights. macOS shows its own password
    /// dialog; cancelling it is reported as `.cancelled`.
    static func install(_ package: URL) throws {
        let command = "/usr/sbin/installer -pkg \(shellQuote(package.path)) -target /"
        let source = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            throw InstallError.installFailed("AppleScript oluşturulamadı.")
        }
        var info: NSDictionary?
        script.executeAndReturnError(&info)
        guard let info else { return }
        let number = (info[NSAppleScript.errorNumber] as? Int) ?? 0
        if number == -128 { throw InstallError.cancelled }
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "installer \(number)"
        throw InstallError.installFailed(message)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
