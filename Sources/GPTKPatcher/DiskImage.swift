import Foundation

/// A mounted disk image. Records whether this app attached it, so only images it mounted are
/// detached afterwards.
struct DiskImage: Sendable {
    let image: URL
    let mountPoint: URL
    let attachedByUs: Bool

    private static let hdiutil = "/usr/bin/hdiutil"

    static func attach(_ image: URL, token: CancellationToken? = nil, log: (String) -> Void) throws -> DiskImage {
        try token?.checkpoint()
        if let existing = try existingMountPoint(for: image) {
            log("Disk image is already mounted at \(existing.path); reusing it.")
            return DiskImage(image: image, mountPoint: existing, attachedByUs: false)
        }
        log("Mounting \(image.lastPathComponent) (read-only)…")
        // Parse the result before propagating cancellation, so an image mounted just before
        // cancellation is still recorded and detached by the caller.
        let result: CommandResult
        do {
            result = try Shell.run(hdiutil, ["attach", image.path, "-plist", "-nobrowse", "-readonly"], token: token, timeout: 180)
        } catch {
            if let mounted = try? existingMountPoint(for: image) {
                DiskImage(image: image, mountPoint: mounted, attachedByUs: true).detach(log: log)
            }
            throw error
        }
        guard let plist = parsePlist(result.stdout),
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            if let mounted = try existingMountPoint(for: image) {
                DiskImage(image: image, mountPoint: mounted, attachedByUs: true).detach(log: log)
            }
            try token?.checkpoint()
            if result.status != 0 { throw PatchError.command("hdiutil attach", result) }
            throw PatchError.io("Could not parse the mount point from hdiutil output.")
        }
        log("Mounted at \(mount)")
        return DiskImage(image: image, mountPoint: URL(fileURLWithPath: mount), attachedByUs: true)
    }

    func detach(log: (String) -> Void) {
        guard attachedByUs else { return }
        if let quiet = try? Shell.run(Self.hdiutil, ["detach", mountPoint.path, "-quiet"], timeout: 30), quiet.status == 0 {
            log("Unmounted \(mountPoint.lastPathComponent)")
            return
        }
        if let forced = try? Shell.run(Self.hdiutil, ["detach", mountPoint.path, "-force", "-quiet"], timeout: 30), forced.status == 0 {
            log("Unmounted \(mountPoint.lastPathComponent) (forced)")
        } else {
            log("Warning: could not unmount \(mountPoint.path); eject it manually.")
        }
    }

    /// Looks through `hdiutil info` for an existing mount of the same image file.
    private static func existingMountPoint(for image: URL) throws -> URL? {
        let result = try Shell.check(hdiutil, ["info", "-plist"], timeout: 30)
        guard let plist = parsePlist(result.stdout),
              let images = plist["images"] as? [[String: Any]] else { return nil }
        let target = canonical(image)
        for entry in images {
            guard let path = entry["image-path"] as? String,
                  canonical(URL(fileURLWithPath: path)) == target,
                  let entities = entry["system-entities"] as? [[String: Any]] else { continue }
            if let mount = entities.compactMap({ $0["mount-point"] as? String }).first {
                return URL(fileURLWithPath: mount)
            }
        }
        return nil
    }

    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func parsePlist(_ text: String) -> [String: Any]? {
        // hdiutil occasionally prints a warning line before the plist; start at the XML header.
        guard let range = text.range(of: "<?xml") else { return nil }
        let xml = String(text[range.lowerBound...])
        guard let data = xml.data(using: .utf8) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}
