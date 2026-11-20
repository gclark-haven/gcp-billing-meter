import AppKit
import Combine
import SwiftUI

@main
enum GCPBillingMeter {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        if arguments.count == 3, ["--preview", "--preview-dark"].contains(arguments[1]) {
            renderPreview(at: arguments[2], dark: arguments[1] == "--preview-dark")
            return
        }
        let delegate = MenuBarController()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    @MainActor private static func renderPreview(at destination: String, dark: Bool) {
        let date = ISO8601DateFormatter().date(from: "2026-06-18T20:30:00Z")!
        let lines: [(String, String)] = [
            ("Cloud Run", "6.28"), ("Cloud SQL", "4.12"), ("Cloud Storage", "1.72"),
            ("BigQuery", "0.24"), ("Artifact Registry", "0.12"), ("Cloud Logging", "-0.06")
        ]
        func fixture(_ multiplier: Decimal) -> [BillingLine] {
            lines.map { service, amount in
                BillingLine(service: service, currency: "USD", amount: Decimal(string: amount)! * multiplier)
            }
        }
        let sample = BillingSnapshot(fetchedAt: date, exportedAt: date,
                                     today: fixture(1), week: fixture(4.2), period: fixture(17.3))
        let view = BillingView(model: BillingModel(initial: sample), isSample: true)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "en_US"))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            fputs("Could not render preview.\n", stderr)
            exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: destination), options: .atomic) }
        catch {
            fputs("Could not write preview.\n", stderr)
            exit(1)
        }
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    let model = BillingModel()
    let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var observers = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.autosaveName = "GCPBillingMeter"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.contentSize = NSSize(width: BillingView.width, height: BillingView.height)
        popover.contentViewController = NSHostingController(rootView: BillingView(model: model))

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatusItem() }
            .store(in: &observers)
        Timer.publish(every: 30 * 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.model.refreshIfDue() }
            .store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.model.refreshIfDue() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &observers)

        updateStatusItem()
        model.refresh()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        MenuBarSpend(snapshot: model.snapshot).apply(to: button)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        model.syncLoginStatus()
        model.refreshIfDue()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
