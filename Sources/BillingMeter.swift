import AppKit
import ServiceManagement
import SwiftUI

enum BillingPeriod: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "This week"
    case invoice = "Billing period"

    var id: Self { self }

    func contains(_ snapshotDate: Date, at now: Date) -> Bool {
        let calendar = BillingSource.pacificCalendar
        switch self {
        case .today: return calendar.isDate(snapshotDate, inSameDayAs: now)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: now)?.contains(snapshotDate) == true
        case .invoice: return calendar.isDate(snapshotDate, equalTo: now, toGranularity: .month)
        }
    }

    func lines(in snapshot: BillingSnapshot, at now: Date) -> [BillingLine] {
        guard contains(snapshot.fetchedAt, at: now) else { return [] }
        return switch self {
        case .today: snapshot.today
        case .week: snapshot.week
        case .invoice: snapshot.period
        }
    }

    func dateLabel(at date: Date) -> String {
        let calendar = BillingSource.pacificCalendar
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone

        switch self {
        case .today:
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            return "\(formatter.string(from: date)) · Pacific"
        case .week:
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            guard let monday = calendar.dateInterval(of: .weekOfYear, for: date)?.start else {
                return "Monday to today · Pacific"
            }
            let first = formatter.string(from: monday)
            let last = formatter.string(from: date)
            return first == last ? "\(first) · Pacific" : "\(first) – \(last) · Pacific"
        case .invoice:
            formatter.setLocalizedDateFormatFromTemplate("MMMMy")
            return "\(formatter.string(from: date)) invoice"
        }
    }
}

struct CurrencyTotal: Identifiable {
    let currency: String
    let amount: Decimal
    var id: String { currency }

    static func from(_ lines: [BillingLine]) -> [CurrencyTotal] {
        Dictionary(grouping: lines, by: \.currency)
            .map { currency, entries in
                CurrencyTotal(currency: currency, amount: entries.reduce(0) { $0 + $1.amount })
            }
            .sorted { $0.currency < $1.currency }
    }

    var formatted: String { amount.formatted(.currency(code: currency)) }
}

@MainActor
final class BillingModel: ObservableObject {
    static let configKey = "BillingConfiguration"
    private let defaults: UserDefaults
    private let fetch: @Sendable (BillingConfiguration) async throws -> BillingSnapshot
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var lastAttemptAt: Date?

    @Published private(set) var configuration: BillingConfiguration?
    @Published private(set) var snapshot: BillingSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginError: String?

    init(defaults: UserDefaults = .standard, initial: BillingSnapshot? = nil,
         fetch: @escaping @Sendable (BillingConfiguration) async throws -> BillingSnapshot = { configuration in
             try await BillingSource.fetch(configuration)
         }) {
        self.defaults = defaults
        self.fetch = fetch
        self.snapshot = initial
        if let data = defaults.data(forKey: Self.configKey),
           let saved = try? JSONDecoder().decode(BillingConfiguration.self, from: data) {
            configuration = try? BillingConfiguration(table: saved.table, queryProject: saved.queryProject,
                                                      location: saved.location)
        }
        syncLoginStatus()
    }

    func configure(_ configuration: BillingConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: Self.configKey)
        if self.configuration != configuration {
            self.configuration = configuration
            generation += 1
            refreshTask?.cancel()
            refreshTask = nil
            snapshot = nil
            lastAttemptAt = nil
            error = nil
            isLoading = false
        }
        refresh()
    }

    func refreshIfDue() {
        if let lastAttemptAt, Date.now.timeIntervalSince(lastAttemptAt) < 30 * 60 { return }
        refresh()
    }

    func refresh() {
        guard let configuration, refreshTask == nil else { return }
        let requestedGeneration = generation
        lastAttemptAt = .now
        isLoading = true
        refreshTask = Task { [weak self, fetch] in
            let result = await Result { try await fetch(configuration) }
            guard let self, self.generation == requestedGeneration else { return }
            self.refreshTask = nil
            self.isLoading = false
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                self.error = nil
            case .failure(let error):
                self.error = error.localizedDescription
            }
        }
    }

    var menuAmount: String? {
        guard let snapshot, snapshot.exportedAt != nil,
              BillingSource.pacificCalendar.isDateInToday(snapshot.fetchedAt) else { return nil }
        let totals = CurrencyTotal.from(snapshot.today)
        return totals.count == 1 ? totals.first?.formatted : nil
    }

    func syncLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func toggleLogin() {
        do {
            if loginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            syncLoginStatus()
            loginError = loginEnabled || SMAppService.mainApp.status != .requiresApproval
                ? nil : "Allow GCP Billing Meter in System Settings → Login Items."
        } catch {
            loginError = "macOS could not change Open at Login. Check System Settings → Login Items."
        }
    }
}

private extension Result where Failure == Error {
    init(_ operation: () async throws -> Success) async {
        do { self = .success(try await operation()) }
        catch { self = .failure(error) }
    }
}
