import Foundation

/// A mounted disk image. Records whether this app attached it, so only images it mounted are
/// detached afterwards.
struct DiskImage: Sendable {
    let image: URL
    let mountPoint: URL
    let attachedByUs: Bool

    private static let hdiutil = "/usr/bin/hdiutil"

    static func attach(_ image: URL, log: (String) -> Void) throws -> DiskImage {
        if let existing = try existingMountPoint(for: image) {
            log("Disk image is already mounted at \(existing.path); reusing it.")
            return DiskImage(image: image, mountPoint: existing, attachedByUs: false)
        }
        log("Mounting \(image.lastPathComponent) (read-only)…")
        let result = try Shell.check(hdiutil, ["attach", image.path, "-plist", "-nobrowse", "-readonly", "-noverify"])
        guard let plist = parsePlist(result.stdout),
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw PatchError.io("Could not parse the mount point from hdiutil output.")
        }
        log("Mounted at \(mount)")
        return DiskImage(image: image, mountPoint: URL(fileURLWithPath: mount), attachedByUs: true)
    }

    func detach(log: (String) -> Void) {
        guard attachedByUs else { return }
        if let quiet = try? Shell.run(Self.hdiutil, ["detach", mountPoint.path, "-quiet"]), quiet.status == 0 {
            log("Unmounted \(mountPoint.lastPathComponent)")
            return
        }
        if let forced = try? Shell.run(Self.hdiutil, ["detach", mountPoint.path, "-force", "-quiet"]), forced.status == 0 {
            log("Unmounted \(mountPoint.lastPathComponent) (forced)")
        } else {
            log("Warning: could not unmount \(mountPoint.path); eject it manually.")
        }
    }

    /// Looks through `hdiutil info` for an existing mount of the same image file.
    private static func existingMountPoint(for image: URL) throws -> URL? {
        let result = try Shell.check(hdiutil, ["info", "-plist"])
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
