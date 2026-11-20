import Darwin
import Foundation

struct BillingConfiguration: Codable, Sendable, Equatable {
    let table: String
    let queryProject: String
    let location: String

    init(table: String, queryProject: String = "", location: String = "US") throws {
        let table = table.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = table.split(separator: ".", omittingEmptySubsequences: false)
        let project = parts.dropLast(2).joined(separator: ".")
        let projectPattern = #"\A(?:[a-z0-9][a-z0-9.-]*:)?[a-z][a-z0-9-]{0,62}\z"#
        guard parts.count >= 3,
              project.range(of: projectPattern, options: .regularExpression) != nil,
              parts[parts.count - 2].range(of: #"\A[A-Za-z0-9_]{1,1024}\z"#,
                                           options: .regularExpression) != nil,
              parts[parts.count - 1].range(of: #"\A[A-Za-z0-9_][A-Za-z0-9_-]{0,1023}\z"#,
                                           options: .regularExpression) != nil else {
            throw BillingSourceError.invalidTable
        }

        let queryProject = queryProject.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedProject = queryProject.isEmpty ? project : queryProject
        guard selectedProject.range(of: projectPattern, options: .regularExpression) != nil else {
            throw BillingSourceError.invalidProject
        }
        let location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard location.range(of: #"\A[A-Za-z][A-Za-z0-9-]{0,62}\z"#, options: .regularExpression) != nil else {
            throw BillingSourceError.invalidLocation
        }

        self.table = table
        self.queryProject = selectedProject
        self.location = location
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(table: values.decode(String.self, forKey: .table),
                      queryProject: values.decodeIfPresent(String.self, forKey: .queryProject) ?? "",
                      location: values.decodeIfPresent(String.self, forKey: .location) ?? "US")
    }
}

struct BillingLine: Codable, Sendable, Equatable {
    let service: String
    let currency: String
    let amount: Decimal
}

struct BillingSnapshot: Codable, Sendable, Equatable {
    let fetchedAt: Date
    let exportedAt: Date?
    let today: [BillingLine]
    let week: [BillingLine]
    let period: [BillingLine]
}

enum BillingSourceError: LocalizedError, Equatable {
    case invalidTable
    case invalidProject
    case invalidLocation
    case cliUnavailable
    case cliFailedToStart
    case loginRequired
    case accessDenied
    case tableNotFound
    case byteLimit
    case timeout
    case invalidResponse
    case queryFailed

    var errorDescription: String? {
        switch self {
        case .invalidTable: "Enter a BigQuery table as project.dataset.table."
        case .invalidProject: "Enter a valid Google Cloud project ID."
        case .invalidLocation: "Enter the dataset location, such as US or us-central1."
        case .cliUnavailable: "Install the Google Cloud CLI with BigQuery support."
        case .cliFailedToStart: "The BigQuery CLI could not start. Check that it runs in Terminal."
        case .loginRequired: "Run gcloud auth login in Terminal, then refresh."
        case .accessDenied: "Your Google Cloud account needs read access to the export and permission to run BigQuery jobs."
        case .tableNotFound: "BigQuery could not find the export. Check the table and dataset location. New exports can take hours to appear."
        case .byteLimit: "This refresh exceeds the 1 GiB BigQuery scan limit."
        case .timeout: "BigQuery took too long to respond. Try refreshing again."
        case .invalidResponse: "BigQuery returned billing data the app could not read."
        case .queryFailed: "BigQuery could not refresh costs. Check your connection and billing settings."
        }
    }
}

enum BillingSource {
    static var pacificCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private static let maximumRows = 10_000
    private static let maximumBytesBilled = 1_073_741_824

    static func fetch(_ configuration: BillingConfiguration) async throws -> BillingSnapshot {
        try Task.checkCancellation()
        let snapshot = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try runQuery(configuration) })
            }
        }
        try Task.checkCancellation()
        return snapshot
    }

    static func query(for configuration: BillingConfiguration, at reference: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = pacificCalendar
        formatter.timeZone = pacificCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let usageDate = formatter.string(from: reference)
        return """
        WITH dates AS (
          SELECT DATE '\(usageDate)' AS today
        ),
        windows AS (
          SELECT
            TIMESTAMP(today, 'America/Los_Angeles') AS day_start,
            TIMESTAMP(DATE_TRUNC(today, WEEK(MONDAY)), 'America/Los_Angeles') AS week_start,
            TIMESTAMP(DATE_ADD(today, INTERVAL 1 DAY), 'America/Los_Angeles') AS day_end,
            FORMAT_DATE('%Y%m', today) AS invoice_month
          FROM dates
        ),
        charges AS (
          SELECT
            CASE cost_type
              WHEN 'tax' THEN 'Tax'
              WHEN 'adjustment' THEN 'Billing adjustments'
              WHEN 'rounding_error' THEN 'Rounding'
              ELSE COALESCE(NULLIF(service.description, ''), 'Other charges')
            END AS service_name,
            currency,
            COALESCE(cost_type, 'regular') = 'regular'
              AND usage_start_time >= day_start AND usage_start_time < day_end AS in_today,
            COALESCE(cost_type, 'regular') = 'regular'
              AND usage_start_time >= week_start AND usage_start_time < day_end AS in_week,
            invoice.month = invoice_month AS in_period,
            COALESCE(CAST(cost AS NUMERIC), NUMERIC '0')
              + COALESCE((SELECT SUM(CAST(credit.amount AS NUMERIC)) FROM UNNEST(credits) AS credit),
                         NUMERIC '0') AS net_cost
          FROM `\(configuration.table)`
          CROSS JOIN windows
          WHERE (usage_start_time >= week_start AND usage_start_time < day_end) OR invoice.month = invoice_month
        )
        SELECT
          'summary' AS kind,
          CAST(NULL AS STRING) AS service_name,
          CAST(NULL AS STRING) AS currency,
          FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%E6SZ', MAX(export_time), 'UTC') AS exported_at,
          CAST(NULL AS STRING) AS today,
          CAST(NULL AS STRING) AS week,
          CAST(NULL AS STRING) AS period
        FROM `\(configuration.table)`
        UNION ALL
        SELECT
          'service' AS kind,
          service_name,
          currency,
          CAST(NULL AS STRING) AS exported_at,
          CAST(SUM(IF(in_today, net_cost, NULL)) AS STRING) AS today,
          CAST(SUM(IF(in_week, net_cost, NULL)) AS STRING) AS week,
          CAST(SUM(IF(in_period, net_cost, NULL)) AS STRING) AS period
        FROM charges
        GROUP BY service_name, currency
        HAVING LOGICAL_OR(in_today OR in_week OR in_period)
        ORDER BY kind DESC, service_name, currency
        """
    }

    static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> BillingSnapshot {
        struct Row: Decodable {
            let kind: String
            let serviceName: String?
            let currency: String?
            let exportedAt: String?
            let today: String?
            let week: String?
            let period: String?
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let rows = try? decoder.decode([Row].self, from: data),
              rows.count < maximumRows,
              let summary = rows.first, summary.kind == "summary" else {
            throw BillingSourceError.invalidResponse
        }

        let exportedAt: Date?
        if let timestamp = summary.exportedAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: timestamp) else { throw BillingSourceError.invalidResponse }
            exportedAt = date
        } else {
            exportedAt = nil
        }

        var today: [BillingLine] = []
        var week: [BillingLine] = []
        var period: [BillingLine] = []
        for row in rows.dropFirst() {
            guard row.kind == "service",
                  let service = row.serviceName, !service.isEmpty,
                  let currency = row.currency, currency.range(of: #"\A[A-Z]{3}\z"#,
                                                               options: .regularExpression) != nil else {
                throw BillingSourceError.invalidResponse
            }
            if let value = row.today { today.append(try line(value, service: service, currency: currency)) }
            if let value = row.week { week.append(try line(value, service: service, currency: currency)) }
            if let value = row.period { period.append(try line(value, service: service, currency: currency)) }
        }
        return BillingSnapshot(fetchedAt: fetchedAt, exportedAt: exportedAt, today: today, week: week, period: period)
    }

    private static func line(_ text: String, service: String, currency: String) throws -> BillingLine {
        guard text.range(of: #"\A-?[0-9]+(?:\.[0-9]{1,9})?\z"#, options: .regularExpression) != nil,
              let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            throw BillingSourceError.invalidResponse
        }
        return BillingLine(service: service, currency: currency, amount: amount)
    }

    private static func runQuery(_ configuration: BillingConfiguration) throws -> BillingSnapshot {
        let fileManager = FileManager.default
        var environment = ProcessInfo.processInfo.environment
        let home = fileManager.homeDirectoryForCurrentUser.path
        let paths = [
            "/opt/homebrew/share/google-cloud-sdk/bin", "/usr/local/share/google-cloud-sdk/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/google-cloud-sdk/bin", "\(home)/.local/bin"
        ] + (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        guard let executable = paths.map({ "\($0)/bq" }).first(where: fileManager.isExecutableFile(atPath:)) else {
            throw BillingSourceError.cliUnavailable
        }
        environment["PATH"] = paths.joined(separator: ":")

        // Private temporary files let bq write results without filling a pipe buffer while we wait.
        let outputDirectory = fileManager.temporaryDirectory.appendingPathComponent("billing-meter-\(UUID())")
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: outputDirectory) }
        let stdoutURL = outputDirectory.appendingPathComponent("result")
        let stderrURL = outputDirectory.appendingPathComponent("error")
        for url in [stdoutURL, stderrURL] {
            guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw BillingSourceError.cliFailedToStart
            }
        }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let fetchedAt = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "--bigqueryrc=/dev/null", "--quiet=true", "--headless=true", "--format=json",
            "--project_id=\(configuration.queryProject)", "--location=\(configuration.location)",
            "query", "--use_legacy_sql=false", "--maximum_bytes_billed=\(maximumBytesBilled)",
            "--max_rows=\(maximumRows)", "--job_timeout_ms=60000", query(for: configuration, at: fetchedAt)
        ]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw BillingSourceError.cliFailedToStart
        }
        guard finished.wait(timeout: .now() + 75) == .success else {
            if process.isRunning {
                let pid = process.processIdentifier
                if getpgid(pid) == pid {
                    // The bq launcher and its Python child share this process group.
                    kill(-pid, SIGTERM)
                } else {
                    process.terminate()
                }
            }
            throw BillingSourceError.timeout
        }

        let output = try Data(contentsOf: stdoutURL)
        guard process.terminationStatus == 0 else {
            let error = try Data(contentsOf: stderrURL)
            if let details = String(data: error + output, encoding: .utf8) {
                throw classifyFailure(details)
            }
            throw BillingSourceError.queryFailed
        }
        return try decode(output, fetchedAt: fetchedAt)
    }

    static func classifyFailure(_ details: String) -> BillingSourceError {
        let details = details.lowercased()
        if details.contains("exceeded limit for bytes billed") { return .byteLimit }
        if details.contains("timed out") || details.contains("deadline exceeded") { return .timeout }
        if details.contains("reauthentication") || details.contains("gcloud auth login") ||
            details.contains("invalid_grant") || details.contains("no active account") {
            return .loginRequired
        }
        if details.contains("access denied") || details.contains("permission denied") || details.contains("forbidden") {
            return .accessDenied
        }
        if details.contains("not found: table") || details.contains("not found: dataset") ||
            details.contains("was not found in location") {
            return .tableNotFound
        }
        return .queryFailed
    }
}
