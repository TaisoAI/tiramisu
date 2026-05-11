import Foundation

/// Per-day call counter for AI providers. Drives the color-coded cost
/// line in the Reimagine sheet ("Free 487/500 used today" → 🟢🟡🔴).
///
/// Honest scope: this is a LOCAL approximation. No major AI API exposes
/// live remaining-quota in response headers, so we count what we send
/// and assume that's the whole story. Cross-app calls (gemini.google.com
/// web, other tools sharing the same project) drift the count — the
/// provider's own dashboard remains authoritative. The Reimagine sheet
/// surfaces this caveat via a small disclaimer.
///
/// Keys: `ai.taiso.tiramisu.quota.{providerID}.{modelID}.{YYYY-MM-DD}`
/// Garbage-collected on app launch (drops keys older than 3 days).
final class QuotaTracker: @unchecked Sendable {
    static let shared = QuotaTracker()

    private let prefix = "ai.taiso.tiramisu.quota."
    private let calendar: Calendar
    private let dateFormatter: DateFormatter

    init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        self.calendar = cal
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        self.dateFormatter = f
        garbageCollect()
    }

    /// Increment today's count for (providerID, modelID). Called by each
    /// provider service immediately after a successful generation.
    func record(providerID: String, modelID: String) {
        let key = todayKey(providerID: providerID, modelID: modelID)
        let n = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(n + 1, forKey: key)
    }

    /// How many calls today (resets at local midnight).
    func count(providerID: String, modelID: String) -> Int {
        UserDefaults.standard.integer(forKey: todayKey(providerID: providerID, modelID: modelID))
    }

    /// Convenience: is this provider/model under its free quota right now?
    /// Returns true if the cost model isn't quota-based (always-free,
    /// pay-per-call, unknown — none of those have a "free quota" to be
    /// under). False once the per-day count hits the limit.
    func underFreeQuota(provider: any AIImageProvider,
                        capability: AIImageCapability,
                        modelID: String) -> Bool {
        switch provider.costModel(for: capability, model: modelID) {
        case .alwaysFree, .payPerCall, .unknown:
            return true
        case .freeQuotaThenPaid(let perDay, _):
            return count(providerID: provider.id, modelID: modelID) < perDay
        }
    }

    // MARK: - Internals

    private func todayKey(providerID: String, modelID: String) -> String {
        "\(prefix)\(providerID).\(modelID).\(dateFormatter.string(from: Date()))"
    }

    /// Drop quota-counter keys for dates more than 3 days ago. Tiny — a
    /// few dozen integers max — but cleaner than letting UserDefaults
    /// accumulate forever.
    private func garbageCollect() {
        let cutoff = calendar.date(byAdding: .day, value: -3, to: Date()) ?? Date()
        let cutoffStamp = dateFormatter.string(from: cutoff)
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            // Key shape: prefix.{providerID}.{modelID}.{YYYY-MM-DD}
            // Date is the last dot-separated segment.
            guard let dateStamp = key.split(separator: ".").last.map(String.init) else { continue }
            if dateStamp < cutoffStamp {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
