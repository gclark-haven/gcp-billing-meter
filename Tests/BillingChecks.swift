import Foundation

@main
enum BillingChecks {
    @MainActor
    static func main() async throws {
        let configuration = try BillingConfiguration(table: "example-project.billing_export.gcp_billing_export_v1_EXAMPLE")
        precondition(configuration.queryProject == "example-project")
        precondition((try? BillingConfiguration(table: "missing-project.table")) == nil)

        let pacificSunday = date("2026-11-02T07:59:59Z")
        let pacificMonday = date("2026-11-02T08:00:00Z")
        let december = date("2026-12-01T08:00:00Z")
        precondition(!BillingPeriod.today.contains(pacificSunday, at: pacificMonday))
        precondition(!BillingPeriod.week.contains(pacificSunday, at: pacificMonday))
        precondition(BillingPeriod.invoice.contains(pacificSunday, at: pacificMonday))
        precondition(!BillingPeriod.invoice.contains(pacificMonday, at: december))

        let response = """
        [
          {"kind":"summary","exported_at":"2026-11-01T22:32:00.000000Z"},
          {"kind":"service","service_name":"Cloud Run","currency":"USD","today":"12.3456789","week":"34.50","period":"12.34"},
          {"kind":"service","service_name":"Cloud SQL","currency":"USD","today":"-0.3456789","week":"3.17","period":"5.09"},
          {"kind":"service","service_name":"Cloud Run","currency":"CAD","today":"7.25","week":"20.00","period":"15.00"},
          {"kind":"service","service_name":"Tax","currency":"USD","period":"1.78"}
        ]
        """
        let snapshot = try BillingSource.decode(Data(response.utf8), fetchedAt: pacificSunday)
        let totals = CurrencyTotal.from(snapshot.today)
        precondition(totals.map(\.currency) == ["CAD", "USD"])
        precondition(totals.map(\.amount) == [7.25, 12])
        precondition(BillingPeriod.today.lines(in: snapshot, at: pacificMonday).isEmpty)
        precondition(BillingPeriod.week.lines(in: snapshot, at: pacificMonday).isEmpty)
        precondition(BillingPeriod.invoice.lines(in: snapshot, at: pacificMonday).contains { $0.service == "Tax" })
        let empty = try BillingSource.decode(Data(#"[{"kind":"summary","exported_at":null}]"#.utf8))
        precondition(empty.exportedAt == nil && empty.today.isEmpty)
        precondition(BillingSource.classifyFailure("Not found: Table") == .tableNotFound)

        let suite = "GCPBillingMeter.BillingChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stub = Stub(snapshot: snapshot)
        let model = BillingModel(defaults: defaults, fetch: { _ in try await stub.fetch() })
        try model.configure(configuration)
        await finish(model)
        precondition(model.snapshot == snapshot && model.error == nil)
        precondition(BillingModel(defaults: defaults).configuration == configuration)

        await stub.setOffline(true)
        model.refresh()
        await finish(model)
        precondition(model.snapshot == snapshot && model.error != nil)

        await stub.setOffline(false)
        model.refresh()
        await finish(model)
        precondition(model.snapshot == snapshot && model.error == nil)
        print("Billing checks passed")
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @MainActor private static func finish(_ model: BillingModel) async {
        for _ in 0..<100 where model.isLoading {
            try? await Task.sleep(for: .milliseconds(10))
        }
        precondition(!model.isLoading)
    }
}

private actor Stub {
    let snapshot: BillingSnapshot
    var offline = false

    init(snapshot: BillingSnapshot) { self.snapshot = snapshot }

    func setOffline(_ offline: Bool) { self.offline = offline }

    func fetch() throws -> BillingSnapshot {
        if offline { throw BillingSourceError.queryFailed }
        return snapshot
    }
}
