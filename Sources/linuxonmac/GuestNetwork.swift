import Foundation

/// Looks up the guest's address in the vmnet DHCP lease table.
///
/// The host has no direct way to ask a VM its IP, but `VZNATNetworkDeviceAttachment`
/// leases through vmnet, whose lease file is world-readable. Matching on our own
/// pinned MAC is exact — which is only possible because the MAC no longer changes
/// on every launch.
enum GuestNetwork {
    private static let leasesPath = "/var/db/dhcpd_leases"

    static func ipAddress(forMAC mac: String) -> String? {
        guard let contents = try? String(contentsOfFile: leasesPath, encoding: .utf8) else {
            return nil
        }
        // The lease file strips leading zeros from each octet: f6:05:... is
        // written as f6:5:..., so a literal comparison never matches.
        let normalized = mac.split(separator: ":")
            .map { String(Int($0, radix: 16) ?? 0, radix: 16) }
            .joined(separator: ":")

        var candidate: String?
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ip_address=") {
                candidate = String(trimmed.dropFirst("ip_address=".count))
            } else if trimmed.hasPrefix("hw_address="), let ip = candidate {
                let value = trimmed.dropFirst("hw_address=".count)
                if value.hasSuffix(",\(normalized)") || value.hasSuffix("," + normalized) {
                    return ip
                }
                if value.contains(normalized) { return ip }
            }
        }
        return nil
    }

    static var storedMAC: String? {
        try? String(contentsOf: Paths.macAddress, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var guestIP: String? {
        guard let mac = storedMAC else { return nil }
        return ipAddress(forMAC: mac)
    }
}
