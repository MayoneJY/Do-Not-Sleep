import Foundation
import AppKit

@MainActor
final class UpdateChecker {
    private let releaseAPIURL = URL(string: "https://api.github.com/repos/MayoneJY/Do-Not-Sleep/releases/latest")!
    private let releasesURL = URL(string: "https://github.com/MayoneJY/Do-Not-Sleep/releases")!
    private var isChecking = false

    func checkForUpdates() {
        guard !isChecking else {
            showInfo(title: L10n.text(.updateAlreadyRunningTitle), message: L10n.text(.updateAlreadyRunningMessage))
            return
        }

        guard let appURL = currentAppBundleURL() else {
            showError(AppError(L10n.text(.updateRequiresAppBundle)))
            return
        }

        isChecking = true
        let releaseAPIURL = releaseAPIURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let release = try Self.fetchLatestRelease(apiURL: releaseAPIURL)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isChecking = false
                    self.handleRelease(release, appURL: appURL)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isChecking = false
                    self.showError(error)
                }
            }
        }
    }

    private func currentAppBundleURL() -> URL? {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            return nil
        }
        return appURL
    }

    nonisolated private static func fetchLatestRelease(apiURL: URL) throws -> GitHubRelease {
        let data = try Self.runCurl(arguments: [
            "-fsSL",
            "-H", "Accept: application/vnd.github+json",
            "-H", "X-GitHub-Api-Version: 2022-11-28",
            "-H", "User-Agent: Do Not Sleep",
            apiURL.absoluteString
        ])
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func handleRelease(_ release: GitHubRelease, appURL: URL) {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let latestVersion = release.normalizedVersion

        guard Self.isVersion(latestVersion, newerThan: currentVersion) else {
            showInfo(
                title: L10n.text(.updateNotAvailableTitle),
                message: L10n.format(.updateNotAvailableMessage, currentVersion)
            )
            return
        }

        guard let asset = Self.preferredAsset(in: release.assets) else {
            showError(AppError(L10n.text(.updateNoInstallableAsset)))
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.text(.updateAvailableTitle)
        alert.informativeText = L10n.format(
            .updateAvailableMessage,
            latestVersion,
            currentVersion,
            asset.name
        )
        alert.addButton(withTitle: L10n.text(.downloadAndInstallUpdate))
        alert.addButton(withTitle: L10n.text(.openReleasesPage))
        alert.addButton(withTitle: L10n.text(.cancel))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            downloadAndInstall(asset: asset, appURL: appURL)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.releaseURL ?? releasesURL)
        default:
            break
        }
    }

    private func downloadAndInstall(asset: GitHubReleaseAsset, appURL: URL) {
        isChecking = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let packageURL = try Self.download(asset: asset)
                let scriptURL = try Self.writeInstallerScript(nextTo: packageURL)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isChecking = false
                    self.launchInstaller(scriptURL: scriptURL, packageURL: packageURL, appURL: appURL)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isChecking = false
                    self.showError(error)
                }
            }
        }
    }

    nonisolated private static func download(asset: GitHubReleaseAsset) throws -> URL {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("do-not-sleep-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let packageURL = workDirectory.appendingPathComponent(asset.safeFileName)
        _ = try Self.runCurl(arguments: [
            "-fL",
            "-H", "User-Agent: Do Not Sleep",
            "-o", packageURL.path,
            asset.downloadURL.absoluteString
        ])
        return packageURL
    }

    nonisolated private static func writeInstallerScript(nextTo packageURL: URL) throws -> URL {
        let scriptURL = packageURL.deletingLastPathComponent().appendingPathComponent("install-update.sh")
        try Self.installerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func launchInstaller(scriptURL: URL, packageURL: URL, appURL: URL) {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                scriptURL.path,
                appURL.path,
                packageURL.path,
                appURL.lastPathComponent,
                "\(ProcessInfo.processInfo.processIdentifier)",
                packageURL.deletingLastPathComponent().appendingPathComponent("install.log").path
            ]
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch {
            showError(error)
        }
    }

    private func showInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text(.ok))
        alert.runModal()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.text(.updateFailedTitle)
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.text(.openReleasesPage))
        alert.addButton(withTitle: L10n.text(.cancel))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releasesURL)
        }
    }

    nonisolated private static func runCurl(arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError(message?.isEmpty == false ? message! : L10n.text(.updateNetworkFailed))
        }

        return output
    }

    nonisolated private static func isVersion(_ latestVersion: String, newerThan currentVersion: String) -> Bool {
        latestVersion.compare(currentVersion, options: [.numeric, .caseInsensitive]) == .orderedDescending
    }

    nonisolated private static func preferredAsset(in assets: [GitHubReleaseAsset]) -> GitHubReleaseAsset? {
        assets
            .filter { $0.isInstallablePackage }
            .sorted { $0.installScore > $1.installScore }
            .first
    }

    nonisolated private static let installerScript = #"""
#!/bin/zsh
set -euo pipefail

APP_PATH="$1"
PACKAGE_PATH="$2"
APP_NAME="$3"
APP_PID="$4"
LOG_PATH="$5"

exec >> "$LOG_PATH" 2>&1
echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] Do Not Sleep 업데이트 설치를 시작합니다."

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/do-not-sleep-install.XXXXXX")"
MOUNT_DIR=""

cleanup() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet || true
  fi
  /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

SOURCE_ROOT="$WORK_DIR"
case "${PACKAGE_PATH:l}" in
  *.zip)
    /usr/bin/ditto -x -k "$PACKAGE_PATH" "$WORK_DIR"
    ;;
  *.dmg)
    MOUNT_DIR="$WORK_DIR/mount"
    /bin/mkdir -p "$MOUNT_DIR"
    /usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$PACKAGE_PATH"
    SOURCE_ROOT="$MOUNT_DIR"
    ;;
  *)
    echo "지원하지 않는 업데이트 패키지입니다: $PACKAGE_PATH"
    exit 1
    ;;
esac

NEW_APP="$(/usr/bin/find "$SOURCE_ROOT" -maxdepth 4 -name "$APP_NAME" -type d -print -quit)"
if [[ -z "$NEW_APP" ]]; then
  echo "패키지 안에서 $APP_NAME 앱 번들을 찾지 못했습니다."
  exit 1
fi

echo "기존 앱 종료를 기다립니다: pid=$APP_PID"
for _ in {1..120}; do
  if /bin/kill -0 "$APP_PID" 2>/dev/null; then
    /bin/sleep 0.5
  else
    break
  fi
done

if /bin/kill -0 "$APP_PID" 2>/dev/null; then
  echo "기존 앱이 종료되지 않아 업데이트를 중단합니다."
  exit 1
fi

BACKUP_PATH="${APP_PATH}.previous-update"
/bin/rm -rf "$BACKUP_PATH"
if [[ -d "$APP_PATH" ]]; then
  /bin/mv "$APP_PATH" "$BACKUP_PATH"
fi

if ! /usr/bin/ditto "$NEW_APP" "$APP_PATH"; then
  echo "새 앱 복사에 실패했습니다. 이전 앱으로 복구합니다."
  /bin/rm -rf "$APP_PATH"
  if [[ -d "$BACKUP_PATH" ]]; then
    /bin/mv "$BACKUP_PATH" "$APP_PATH"
  fi
  exit 1
fi

/usr/bin/xattr -dr com.apple.quarantine "$APP_PATH" || true
/bin/rm -rf "$BACKUP_PATH"
/usr/bin/open "$APP_PATH"
echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] Do Not Sleep 업데이트 설치를 완료했습니다."
"""#
}

private struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlURL: String
    let assets: [GitHubReleaseAsset]

    var normalizedVersion: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    var releaseURL: URL? {
        URL(string: htmlURL)
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: String

    var downloadURL: URL {
        URL(string: browserDownloadURL)!
    }

    var safeFileName: String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ "))
        let replacement = UnicodeScalar("-")
        let scalars = String.UnicodeScalarView(name.unicodeScalars.map { allowedCharacters.contains($0) ? $0 : replacement })
        let sanitized = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "DoNotSleepUpdate.zip" : sanitized
    }

    var isInstallablePackage: Bool {
        let lowercasedName = name.lowercased()
        return (lowercasedName.hasSuffix(".zip") || lowercasedName.hasSuffix(".dmg"))
            && !lowercasedName.contains("dsym")
            && !lowercasedName.contains("source")
    }

    var installScore: Int {
        let lowercasedName = name.lowercased()
        var score = 0
        if lowercasedName.contains("do-not-sleep") || lowercasedName.contains("do not sleep") {
            score += 30
        }
        if lowercasedName.contains("mac") || lowercasedName.contains("darwin") {
            score += 10
        }
        if lowercasedName.contains("universal") || lowercasedName.contains("arm64") {
            score += 5
        }
        if lowercasedName.hasSuffix(".zip") {
            score += 3
        }
        if lowercasedName.hasSuffix(".dmg") {
            score += 2
        }
        return score
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
