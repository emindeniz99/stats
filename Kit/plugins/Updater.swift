//
//  Updater.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 14/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import SystemConfiguration
import Security

public struct version_s {
    public let current: String
    public let latest: String
    public let newest: Bool
    public let url: String
    public let inCooldown: Bool
    public let daysUntilReady: Int

    public init(current: String, latest: String, newest: Bool, url: String, inCooldown: Bool = false, daysUntilReady: Int = 0) {
        self.current = current
        self.latest = latest
        self.newest = newest
        self.url = url
        self.inCooldown = inCooldown
        self.daysUntilReady = daysUntilReady
    }
}

internal struct Version {
    var major: Int = 0
    var minor: Int = 0
    var patch: Int = 0
    
    var beta: Int? = nil
}

public class Updater {
    private let github: URL
    private let githubList: URL
    private let server: URL
    private let maxPagesToScan = 3

    private let appName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as! String
    private let currentVersion: String = "v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String)"

    private var observation: NSKeyValueObservation?

    private var lastCheckTS: Int {
        get {
            return Store.shared.int(key: "updater_check_ts", defaultValue: -1)
        }
        set {
            Store.shared.set(key: "updater_check_ts", value: newValue)
        }
    }
    private var lastInstallTS: Int {
        get {
            return Store.shared.int(key: "updater_install_ts", defaultValue: -1)
        }
        set {
            Store.shared.set(key: "updater_install_ts", value: newValue)
        }
    }

    public init(github: String, url: String) {
        self.github = URL(string: "https://api.github.com/repos/\(github)/releases/latest")!
        self.githubList = URL(string: "https://api.github.com/repos/\(github)/releases?per_page=30")!
        self.server = URL(string: "\(url)?macOS=\(ProcessInfo().operatingSystemVersion.getFullVersion())")!
    }
    
    deinit {
        observation?.invalidate()
    }
    
    public func check(force: Bool = false, completion: @escaping (_ result: version_s?, _ error: Error?) -> Void) {
        if !isConnectedToNetwork() {
            completion(nil, "No internet connection")
            return
        }

        let diff = (Int(Date().timeIntervalSince1970) - self.lastCheckTS) / 60
        if !force && diff <= 10 {
            completion(nil, "last check was \(diff) minutes ago, stopping...")
            return
        }

        defer {
            self.lastCheckTS = Int(Date().timeIntervalSince1970)
        }

        // When cooldown is enabled, skip the server (it may not return published_at)
        // and go straight to GitHub releases where we can inspect release dates.
        if self.cooldownDays > 0 {
            self.checkGitHubReleases(completion: completion)
            return
        }

        // Try custom server for the latest release first
        self.fetchRelease(uri: self.server) { result, err in
            guard let result = result, err == nil else {
                self.checkGitHubReleases(completion: completion)
                return
            }

            let version = self.buildVersion(result)
            // If the latest release is still in cooldown, search recent releases for one that has aged out
            if version.inCooldown {
                self.checkGitHubReleases(completion: completion)
            } else {
                completion(version, nil)
            }
        }
    }

    // Fetch the GitHub releases list and return the best candidate respecting cooldown.
    // Scans up to maxPagesToScan pages, stopping early once a past-cooldown release is found
    // or once a page contains no newer-than-current release (older pages won't either).
    private func checkGitHubReleases(completion: @escaping (_ result: version_s?, _ error: Error?) -> Void) {
        var bestInCooldown: version_s? = nil

        func scanPage(_ page: Int) {
            self.fetchReleases(page: page) { releases, err in
                guard let releases = releases, err == nil else {
                    if page == 1 {
                        // List endpoint failed on first page — fall back to single-release endpoint
                        self.fetchRelease(uri: self.github) { result, err in
                            guard let result = result, err == nil else {
                                completion(nil, err)
                                return
                            }
                            completion(self.buildVersion(result), nil)
                        }
                    } else {
                        // Later page failed — return what we have
                        completion(bestInCooldown, nil)
                    }
                    return
                }

                let candidate = self.buildBestVersion(from: releases)

                // Check whether this page contained any release newer than current.
                // If not, older pages won't either — stop paginating.
                let hasNewer = releases.contains { isNewestVersion(currentVersion: self.currentVersion, latestVersion: $0.tag) }
                guard hasNewer else {
                    completion(bestInCooldown ?? candidate, nil)
                    return
                }

                if let v = candidate, !v.inCooldown, v.newest {
                    // Found a past-cooldown release — return it immediately
                    completion(v, nil)
                    return
                }

                // Still in cooldown — remember the best candidate and try next page
                if let v = candidate, v.newest {
                    if bestInCooldown == nil {
                        bestInCooldown = v
                    }
                }

                if page < self.maxPagesToScan {
                    scanPage(page + 1)
                } else {
                    completion(bestInCooldown ?? candidate, nil)
                }
            }
        }

        scanPage(1)
    }

    private var cooldownDays: Int {
        Store.shared.int(key: "update-cooldown-days", defaultValue: 0)
    }

    private func buildVersion(_ result: (tag: String, url: String, publishedAt: Date?)) -> version_s {
        let isNewer = isNewestVersion(currentVersion: self.currentVersion, latestVersion: result.tag)
        var inCooldown = false
        var daysUntilReady = 0

        if isNewer, self.cooldownDays > 0, let publishedAt = result.publishedAt {
            let daysSinceRelease = Calendar.current.dateComponents([.day], from: publishedAt, to: Date()).day ?? 0
            if daysSinceRelease < self.cooldownDays {
                inCooldown = true
                daysUntilReady = self.cooldownDays - daysSinceRelease
            }
        }

        return version_s(
            current: self.currentVersion,
            latest: result.tag,
            newest: isNewer,
            url: result.url,
            inCooldown: inCooldown,
            daysUntilReady: daysUntilReady
        )
    }

    // Walk releases newest-first and return the first one that has aged past the cooldown window.
    // Falls back to the very latest if every newer release is still in cooldown.
    private func buildBestVersion(from releases: [(tag: String, url: String, publishedAt: Date?)]) -> version_s? {
        guard !releases.isEmpty else { return nil }

        let cooldown = self.cooldownDays
        let now = Date()
        var firstNewer: (tag: String, url: String, publishedAt: Date?)? = nil

        for release in releases {
            guard isNewestVersion(currentVersion: self.currentVersion, latestVersion: release.tag) else {
                continue
            }

            if firstNewer == nil { firstNewer = release }

            if cooldown == 0 {
                return buildVersion(release)
            }

            guard let publishedAt = release.publishedAt else {
                // No date — can't check cooldown, treat as ready
                return buildVersion(release)
            }

            let daysSince = Calendar.current.dateComponents([.day], from: publishedAt, to: now).day ?? 0
            if daysSince >= cooldown {
                return buildVersion(release)  // This release has aged past the cooldown window
            }
            // Still in cooldown — try the next (older) release
        }

        // Every newer release is in cooldown (or no newer release exists).
        // Return the latest with inCooldown set so callers can show appropriate UI.
        if let latest = firstNewer {
            return buildVersion(latest)
        }
        return buildVersion(releases[0])  // No newer version at all
    }
    
    // GitHub timestamps are RFC 3339 / ISO 8601. `published_at` normally comes without
    // fractional seconds ("2024-04-14T10:00:00Z"), but a default ISO8601DateFormatter
    // returns nil if fractional seconds ever appear — which would silently bypass the
    // cooldown. Parse defensively by trying both representations.
    private static func parseGitHubDate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    private func fetchRelease(uri: URL, completion: @escaping (_ result: (tag: String, url: String, publishedAt: Date?)?, _ error: Error?) -> Void) {
        let task = URLSession.shared.dataTask(with: uri) { data, _, error in
            guard let data = data, error == nil else {
                completion(nil, "no data")
                return
            }

            do {
                let jsonResponse = try JSONSerialization.jsonObject(with: data, options: [])
                guard let jsonArray = jsonResponse as? [String: Any],
                      let lastVersion = jsonArray["tag_name"] as? String,
                      let assets = jsonArray["assets"] as? [[String: Any]],
                      let asset = assets.first(where: {$0["name"] as? String == "\(self.appName).dmg"}),
                      let downloadURL = asset["browser_download_url"] as? String else {
                    completion(nil, "parse json")
                    return
                }

                let publishedAt = Updater.parseGitHubDate(jsonArray["published_at"] as? String)

                completion((lastVersion, downloadURL, publishedAt), nil)
            } catch let parsingError {
                completion(nil, parsingError)
            }
        }
        task.resume()
    }
    
    private func fetchReleases(page: Int = 1, completion: @escaping (_ result: [(tag: String, url: String, publishedAt: Date?)]?, _ error: Error?) -> Void) {
        guard var components = URLComponents(url: self.githubList, resolvingAgainstBaseURL: false) else {
            completion(nil, "invalid URL")
            return
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "page" }
        queryItems.append(URLQueryItem(name: "page", value: "\(page)"))
        components.queryItems = queryItems
        guard let url = components.url else {
            completion(nil, "invalid URL after page param")
            return
        }

        let task = URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data, error == nil else {
                completion(nil, "no data")
                return
            }

            do {
                let jsonResponse = try JSONSerialization.jsonObject(with: data, options: [])
                guard let items = jsonResponse as? [[String: Any]] else {
                    completion(nil, "parse json")
                    return
                }

                var results: [(tag: String, url: String, publishedAt: Date?)] = []

                for item in items {
                    if item["prerelease"] as? Bool == true { continue }
                    if item["draft"] as? Bool == true { continue }
                    guard let tag = item["tag_name"] as? String,
                          let assets = item["assets"] as? [[String: Any]],
                          let asset = assets.first(where: { $0["name"] as? String == "\(self.appName).dmg" }),
                          let downloadURL = asset["browser_download_url"] as? String else {
                        continue
                    }
                    let publishedAt = Updater.parseGitHubDate(item["published_at"] as? String)
                    results.append((tag, downloadURL, publishedAt))
                }

                guard !results.isEmpty else {
                    completion(nil, "no valid releases found")
                    return
                }

                completion(results, nil)
            } catch let parsingError {
                completion(nil, parsingError)
            }
        }
        task.resume()
    }

    public func download(_ url: URL, progress: @escaping (_ progress: Progress) -> Void = {_ in }, completion: @escaping (_ path: String) -> Void = {_ in }) {
        let downloadTask = URLSession.shared.downloadTask(with: url) { urlOrNil, _, _ in
            guard let fileURL = urlOrNil else { return }
            do {
                let downloadsURL = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                let destinationURL = downloadsURL.appendingPathComponent(url.lastPathComponent)
                
                self.copyFile(from: fileURL, to: destinationURL) { (path, error) in
                    if error != nil {
                        print("copy file error: \(error ?? "copy error")")
                        return
                    }
                    
                    completion(path)
                }
            } catch {
                print("file error: \(error)")
            }
        }
        
        self.observation = downloadTask.progress.observe(\.fractionCompleted) { value, _ in
            progress(value)
        }
        
        downloadTask.resume()
    }
    
    public func install(path: String, completion: @escaping (_ error: String?) -> Void) {
        let dmg = path.replacingOccurrences(of: "file://", with: "")
        let pwd = Bundle.main.bundleURL.deletingLastPathComponent().path
        
        guard FileManager.default.fileExists(atPath: dmg) else {
            completion("DMG not found at \(dmg)")
            return
        }
        let needsElevation = !FileManager.default.isWritableFile(atPath: pwd)
        
        let diff = (Int(Date().timeIntervalSince1970) - self.lastInstallTS) / 60
        if diff <= 3 {
            completion("last install was \(diff) minutes ago, stopping...")
            return
        }
        
        print("Started new version installation...")
        
        let mountPoint: String
        do {
            mountPoint = try self.makeUniqueMountPoint()
        } catch {
            completion("failed to create mount point: \(error)")
            return
        }
        
        var attach = self.runProcess("/usr/bin/hdiutil", [
            "attach", dmg, "-mountpoint", mountPoint, "-nobrowse", "-noautoopen", "-readonly"
        ])
        if attach.exit != 0, (attach.error + attach.output).contains("is busy") {
            print("DMG is busy, remounting")
            _ = self.runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-force"])
            attach = self.runProcess("/usr/bin/hdiutil", [
                "attach", dmg, "-mountpoint", mountPoint, "-nobrowse", "-noautoopen", "-readonly"
            ])
        }
        if attach.exit != 0 {
            let msg = (attach.error + attach.output).replacingOccurrences(of: "hdiutil: attach failed - ", with: "")
            completion("Could not mount DMG (attach failed) - \(msg)")
            try? FileManager.default.removeItem(atPath: dmg)
            try? FileManager.default.removeItem(atPath: mountPoint)
            return
        }
        
        print("DMG is mounted at \(mountPoint)")
        
        let mountedApp = (mountPoint as NSString).appendingPathComponent("Stats.app")
        if let err = self.validateAppSignature(at: mountedApp) {
            _ = self.runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-force"])
            try? FileManager.default.removeItem(atPath: mountPoint)
            try? FileManager.default.removeItem(atPath: dmg)
            completion("DMG signature validation failed: \(err)")
            return
        }
        
        print("DMG signature validated")
        
        let scriptSrc = (mountedApp as NSString).appendingPathComponent("Contents/Resources/Scripts/updater.sh")
        let scriptDst = (NSTemporaryDirectory() as NSString).appendingPathComponent("stats-updater-\(UUID().uuidString).sh")
        do {
            if FileManager.default.fileExists(atPath: scriptDst) {
                try FileManager.default.removeItem(atPath: scriptDst)
            }
            try FileManager.default.copyItem(atPath: scriptSrc, toPath: scriptDst)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptDst)
        } catch {
            _ = self.runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-force"])
            completion("failed to stage updater script: \(error)")
            return
        }
        
        print("Script staged at \(scriptDst)")
        
        let scriptArgs = [scriptDst, "--app", pwd, "--dmg", dmg, "--mount", mountPoint, "--user", String(getuid())]

        if needsElevation {
            if let err = self.runElevated("/bin/bash", args: scriptArgs) {
                _ = self.runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-force"])
                try? FileManager.default.removeItem(atPath: scriptDst)
                try? FileManager.default.removeItem(atPath: mountPoint)
                completion("elevated install failed: \(err)")
                return
            }
        } else {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = scriptArgs
            do {
                try task.run()
            } catch {
                completion("failed to launch updater: \(error)")
                return
            }
        }

        print("Run updater.sh with app: \(pwd) and dmg: \(dmg)")
        
        self.lastInstallTS = Int(Date().timeIntervalSince1970)
        
        exit(0)
    }
    
    private func makeUniqueMountPoint() throws -> String {
        let template = (NSTemporaryDirectory() as NSString).appendingPathComponent("Stats-update-XXXXXX")
        var bytes = Array(template.utf8).map { Int8($0) } + [Int8(0)]
        guard let dir = mkdtemp(&bytes) else {
            throw NSError(domain: "Updater", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        return String(cString: dir)
    }
    
    private func validateAppSignature(at path: String) -> String? {
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        var status = SecStaticCodeCreateWithPath(url, [], &staticCode)
        guard status == errSecSuccess, let code = staticCode else {
            return "SecStaticCodeCreateWithPath failed (\(status))"
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidity(code, flags, nil)
        guard status == errSecSuccess else {
            return "SecStaticCodeCheckValidity failed (\(status))"
        }
        
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
            return "SecCodeCopySelf failed"
        }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic else {
            return "SecCodeCopyStaticCode failed"
        }
        guard let selfTeam = self.teamID(for: selfStatic) else {
            return "could not read current team ID"
        }
        guard let dmgTeam = self.teamID(for: code) else {
            return "could not read DMG team ID"
        }
        if selfTeam != dmgTeam {
            return "team ID mismatch: \(selfTeam) vs \(dmgTeam)"
        }
        return nil
    }
    
    private func teamID(for code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return nil
        }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
    
    private func runElevated(_ tool: String, args: [String]) -> String? {
        var authRef: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authRef)
        guard createStatus == errAuthorizationSuccess, let authRef else {
            return "AuthorizationCreate failed (\(createStatus))"
        }
        defer { AuthorizationFree(authRef, [.destroyRights]) }

        // AuthorizationExecuteWithPrivileges is deprecated since 10.7 but still functional;
        // resolve via dlsym to avoid the compile-time deprecation warning.
        typealias AEWPFn = @convention(c) (
            AuthorizationRef,
            UnsafePointer<CChar>,
            AuthorizationFlags,
            UnsafePointer<UnsafeMutablePointer<CChar>?>,
            UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
        ) -> OSStatus
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges") else {
            return "AuthorizationExecuteWithPrivileges unavailable"
        }
        let aewp = unsafeBitCast(sym, to: AEWPFn.self)

        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }

        let result: OSStatus = tool.withCString { toolPtr in
            cArgs.withUnsafeMutableBufferPointer { buf in
                aewp(authRef, toolPtr, [], buf.baseAddress!, nil)
            }
        }

        if result == errAuthorizationCanceled {
            return "user canceled"
        }
        if result != errAuthorizationSuccess {
            return "AuthorizationExecuteWithPrivileges failed (\(result))"
        }
        return nil
    }

    private func runProcess(_ launch: String, _ args: [String]) -> (output: String, error: String, exit: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launch)
        task.arguments = args
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
        } catch {
            return ("", "runProcess: \(error.localizedDescription)", -1)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            task.terminationStatus
        )
    }
    
    private func copyFile(from: URL, to: URL, completionHandler: @escaping (_ path: String, _ error: Error?) -> Void) {
        var toPath = to
        let fileName = (URL(fileURLWithPath: to.absoluteString)).lastPathComponent
        let fileExt  = (URL(fileURLWithPath: to.absoluteString)).pathExtension
        var fileNameWithoutSuffix: String!
        var newFileName: String!
        var counter = 0
        
        if fileName.hasSuffix(fileExt) {
            fileNameWithoutSuffix = String(fileName.prefix(fileName.count - (fileExt.count+1)))
        }
        
        while toPath.checkFileExist() {
            counter += 1
            newFileName =  "\(fileNameWithoutSuffix!)-\(counter).\(fileExt)"
            toPath = to.deletingLastPathComponent().appendingPathComponent(newFileName)
        }
        
        do {
            try FileManager.default.moveItem(at: from, to: toPath)
            completionHandler(toPath.absoluteString, nil)
        } catch {
            completionHandler("", error)
        }
    }
    
    // https://stackoverflow.com/questions/30743408/check-for-internet-connection-with-swift
    private func isConnectedToNetwork() -> Bool {
        var zeroAddress = sockaddr_in(sin_len: 0, sin_family: 0, sin_port: 0, sin_addr: in_addr(s_addr: 0), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
        zeroAddress.sin_family = sa_family_t(AF_INET)
        
        let defaultRouteReachability = withUnsafePointer(to: &zeroAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {zeroSockAddress in
                SCNetworkReachabilityCreateWithAddress(nil, zeroSockAddress)
            }
        }
        
        var flags: SCNetworkReachabilityFlags = SCNetworkReachabilityFlags(rawValue: 0)
        if SCNetworkReachabilityGetFlags(defaultRouteReachability!, &flags) == false {
            return false
        }
        
        let isReachable = (flags.rawValue & UInt32(kSCNetworkFlagsReachable)) != 0
        let needsConnection = (flags.rawValue & UInt32(kSCNetworkFlagsConnectionRequired)) != 0
        let ret = (isReachable && !needsConnection)
        
        return ret
    }
}
