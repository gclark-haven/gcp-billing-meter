import SwiftUI

struct BillingView: View {
    @ObservedObject var model: BillingModel
    var isSample = false
    @State private var period: BillingPeriod = .today
    @State private var showingSettings = false
    @State private var table = ""
    @State private var queryProject = ""
    @State private var location = "US"
    @State private var validation: String?

    static let width: CGFloat = 402
    static let height: CGFloat = 444
    private let accent = Color(nsColor: .systemTeal)
    private let billingExport = URL(string: "https://console.cloud.google.com/billing/export")!
    private let billingReports = URL(string: "https://console.cloud.google.com/billing")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if showingSettings {
                settings
            } else if let snapshot = model.snapshot, snapshot.exportedAt != nil {
                dashboard(snapshot)
            } else {
                placeholder
            }
            Divider()
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "cloud")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 36, height: 36)
                .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Google Cloud").font(.system(size: 15, weight: .semibold))
                Text(showingSettings ? "Billing source" : "Net spend after credits")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isSample {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Refreshing billing data")
                } else if model.configuration != nil && !showingSettings {
                    Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
                        .labelStyle(.iconOnly)
                        .help("Refresh billing data")
                }
                Menu {
                    Button(showingSettings ? "Back to billing" : "Settings…") {
                        if showingSettings { showingSettings = false } else { editSettings() }
                    }
                    Link("Open Google Cloud Billing", destination: billingReports)
                    Button(model.loginEnabled ? "Disable Open at Login" : "Open at Login", action: model.toggleLogin)
                    Divider()
                    Button("Quit GCP Billing Meter") { NSApplication.shared.terminate(nil) }
                } label: {
                    Label("Billing meter options", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .fixedSize()
                .help("Billing meter options")
                .accessibilityLabel("Billing meter options")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private func dashboard(_ snapshot: BillingSnapshot) -> some View {
        let now = isSample ? snapshot.fetchedAt : Date.now
        let periodIsCurrent = period.contains(snapshot.fetchedAt, at: now)
        let invoicePending = model.usingReportSnapshot && period == .invoice
        let lines = period.lines(in: snapshot, at: now).sorted {
            if $0.currency != $1.currency { return $0.currency < $1.currency }
            if abs($0.amount) != abs($1.amount) { return abs($0.amount) > abs($1.amount) }
            return $0.service < $1.service
        }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach(BillingPeriod.allCases) { option in
                    let totals = CurrencyTotal.from(option.lines(in: snapshot, at: now))
                    rangeButton(option, totals: totals)
                }
            }
            .padding(.bottom, 16)

            ViewThatFits(in: .horizontal) {
                scopeHeading(at: now)
                VStack(alignment: .leading, spacing: 4) {
                    Text("By service").font(.system(size: 12, weight: .semibold))
                    Text(period.dateLabel(at: now))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 5)

            if lines.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(invoicePending ? "Waiting for the BigQuery billing period." :
                         periodIsCurrent ? "No charges exported for this range yet." : "Waiting for a refresh for this range.")
                        .font(.system(size: 12, weight: .medium))
                    Text(invoicePending ? "Today's and this week's totals come from Google Cloud Reports." :
                         "Google Cloud can report charges after the usage date.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 16)
                Spacer(minLength: 0)
            } else if isSample {
                serviceList(lines)
                Spacer(minLength: 0)
            } else {
                ScrollView { serviceList(lines) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 9)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func serviceList(_ lines: [BillingLine]) -> some View {
        let grouped = Dictionary(grouping: lines, by: \.currency)
        let totals = CurrencyTotal.from(lines)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(totals) { total in
                let entries = grouped[total.currency, default: []]
                if totals.count > 1 {
                    Text("\(total.currency)  \(total.formatted)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                let largest = entries.map { abs($0.amount) }.max() ?? 0
                ForEach(entries, id: \.service) { line in
                    serviceRow(line, largest: largest)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 2)
    }

    private func scopeHeading(at now: Date) -> some View {
        HStack {
            Text("By service").font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(period.dateLabel(at: now))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private func rangeButton(_ option: BillingPeriod, totals: [CurrencyTotal]) -> some View {
        let selected = period == option
        let emptyState = model.usingReportSnapshot && option == .invoice
            ? "Waiting for BigQuery" : "No charges exported"
        let amount = totals.isEmpty ? "—" : totals.count == 1 ? totals[0].formatted : "Multiple currencies"
        return Button { period = option } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(option.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(amount)
                    .font(.system(size: totals.count > 1 ? 12 : 19, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .background(selected ? accent.opacity(0.11) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? accent.opacity(0.43) : Color.clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.rawValue)
        .accessibilityValue(totals.isEmpty ? emptyState : amount)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func serviceRow(_ line: BillingLine, largest: Decimal) -> some View {
        let fraction = largest == 0 ? 0 : NSDecimalNumber(decimal: abs(line.amount) / largest).doubleValue
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(line.service)
                    .font(.system(size: 12))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(line.amount.formatted(.currency(code: line.currency)))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .fixedSize()
            }
            GeometryReader { proxy in
                Capsule().fill(Color.primary.opacity(0.065))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(line.amount < 0 ? Color.green.opacity(0.65) : accent.opacity(0.65))
                            .frame(width: proxy.size.width * fraction)
                    }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: model.configuration == nil ? "cylinder" : "clock.arrow.circlepath")
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
                .padding(.bottom, 5)
            if model.configuration == nil {
                Text("Connect your billing export").font(.title3.bold())
                Text("Choose the BigQuery table for your Google Cloud Billing export.")
                    .foregroundStyle(.secondary)
                Button("Set Up Billing Source", action: editSettings)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            } else if let error = model.error {
                Text("Waiting for billing data").font(.title3.bold())
                Text(error).foregroundStyle(.secondary)
                Button("Billing Source Settings", action: editSettings).padding(.top, 4)
            } else if model.isLoading {
                Text("Checking billing export…").font(.title3.bold())
                Text("Reading your latest reported Google Cloud charges.").foregroundStyle(.secondary)
            } else {
                Text("Waiting for the first export").font(.title3.bold())
                Text("Spend will appear here after Google Cloud exports your charges to BigQuery.")
                    .foregroundStyle(.secondary)
                Button("Billing Source Settings", action: editSettings).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 25)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("BigQuery export table", example: "project.dataset.gcp_billing_export_v1_…", value: $table)
            field("Query project (optional)", example: "Uses the export table’s project", value: $queryProject)
            field("Dataset location", example: "US", value: $location)
            if let validation {
                Text(validation).font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            HStack {
                Link("Google Cloud export setup", destination: billingExport)
                Spacer()
                Button("Cancel", role: .cancel) { showingSettings = false }
                Button("Save", action: saveSettings)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity)
    }

    private func field(_ title: String, example: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold))
            TextField(title, text: value, prompt: Text(example))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 6) {
            if isSample {
                Text("Sample data")
                Spacer()
                Text("Google Cloud export can lag")
            } else if let loginError = model.loginError {
                Text(loginError)
                Spacer()
            } else if model.usingReportSnapshot, let snapshot = model.snapshot {
                Text("Reports snapshot · \(snapshot.fetchedAt.formatted(.dateTime.hour().minute()))")
                Spacer()
                Text("Waiting for BigQuery")
            } else if let snapshot = model.snapshot, let exportedAt = snapshot.exportedAt {
                if let error = model.error {
                    Text("Refresh failed · \(error)")
                    Spacer()
                } else if Date.now.timeIntervalSince(exportedAt) > 36 * 3600 {
                    Text("Export delayed")
                    Spacer()
                }
                Text("Exported \(exportedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .help("Latest export timestamp returned by BigQuery")
                if model.error == nil && Date.now.timeIntervalSince(exportedAt) <= 36 * 3600 {
                    Spacer()
                    Text("Google Cloud export can lag")
                }
            } else {
                Text(model.configuration == nil ? "Uses your local Google Cloud CLI" : "Google Cloud export can lag")
                Spacer()
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .frame(minHeight: 24, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    private func editSettings() {
        table = model.configuration?.table ?? ""
        queryProject = model.configuration?.queryProject ?? ""
        location = model.configuration?.location ?? "US"
        validation = nil
        showingSettings = true
    }

    private func saveSettings() {
        do {
            try model.configure(BillingConfiguration(table: table, queryProject: queryProject, location: location))
            showingSettings = false
        } catch {
            validation = error.localizedDescription
        }
    }
}
