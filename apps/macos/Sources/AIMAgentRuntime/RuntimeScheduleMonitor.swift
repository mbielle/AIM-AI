import AIMApplication
import AIMMacPlatform
import Foundation

@MainActor
package final class RuntimeScheduleMonitor {
    private let monitor: TaskTriggerMonitor
    private var signature: Data?
    package init(scheduler: DurableScheduleCoordinator) {
        monitor = TaskTriggerMonitor(persistObservation: { id, source, output, newMail in
            try? await scheduler.observe(taskID: id, source: source, output: output, newMail: newMail)
        }) { id, reason, payload in
            Task { try? await scheduler.enqueue(taskID: id, reason: reason, payload: payload) }
        }
    }
    package func update(_ tasks: [ScheduledTask]) throws {
        // Running tasks keep their watch: occupied resources must not drop ingress.
        // Ignore volatile dates to avoid resetting a script's baseline every tick.
        let stable = tasks.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            [$0.id.uuidString, String(decoding: (try? JSONEncoder().encode($0.spec?.trigger)) ?? Data(), as: UTF8.self)]
        }
        let next = try JSONEncoder().encode(stable)
        guard next != signature else { return }
        signature = next; monitor.update(tasks)
    }
    package func stop() { monitor.stopAll(); signature = nil }
}
