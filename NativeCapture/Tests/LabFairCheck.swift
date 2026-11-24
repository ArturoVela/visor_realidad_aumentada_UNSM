import Foundation
import simd

/// Standalone check for the fair mode: packet journeys, challenge faults and the local ranking.
@main
struct LabFairCheck {
    /// Deterministic generator so a failure can be reproduced.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func main() throws {
        let tier = try LabDemo.dataCenter(), home = try LabDemo.homeLab()
        for (label, project) in [("Tier IV", tier), ("HomeLab", home)] {
            try checkJourneys(project.topology, label: label)
            try checkChallenge(project.topology, label: label)
        }
        checkLeaderboard()
        print("LabFairCheck: OK")
    }

    /// Every hop must continue from the device reached by the previous one.
    static func checkJourneys(_ topology: LabTopology, label: String) throws {
        var generator = SeededGenerator(state: 7)
        let routes = LabFairPlanner.routes(in: topology, poweredOff: [], using: &generator)
        precondition(!routes.isEmpty, "\(label): sin rutas para enviar paquetes")
        precondition(LabFairPlanner.showcase(routes, using: &generator) != nil)
        let names = Dictionary(topology.devices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for route in routes {
            precondition(LabFairPlanner.isEndpoint(route.source) || route.source.ipv4 != nil)
            let diagnosis = topology.diagnosePing(from: route.source, to: route.destination, poweredOff: [])
            guard let journey = LabPacketJourney(diagnosis: diagnosis, topology: topology) else {
                preconditionFailure("\(label): ruta sin recorrido animable")
            }
            precondition(!journey.blocked && !journey.hops.contains(where: \.dies))
            precondition(journey.hops.count == route.path.links.count)
            precondition(journey.sourceName == route.source.name)
            if route.path.links.count + 1 == route.path.devices.count {
                precondition(journey.hops.last?.deviceName == route.destination.name,
                             "\(label): el paquete no termina en \(route.destination.name)")
            }
            var current = route.source.id
            for (hop, link) in zip(journey.hops, route.path.links) {
                precondition(hop.linkID == link.id)
                let start = hop.reversed ? link.toDeviceID : link.fromDeviceID
                let end = hop.reversed ? link.fromDeviceID : link.toDeviceID
                // Wireless gaps are allowed; wired hops must chain.
                if start != current, link.fromDeviceID != current, link.toDeviceID != current {
                    current = end
                    continue
                }
                precondition(start == current, "\(label): salto \(link.id) no continúa desde \(names[current] ?? current)")
                precondition(hop.deviceName == names[end])
                current = end
            }
        }
    }

    /// Turning off the chosen device blocks the packet on the cable that leads to it.
    static func checkChallenge(_ topology: LabTopology, label: String) throws {
        var generator = SeededGenerator(state: 42)
        for _ in 0..<12 {
            guard let challenge = LabFairPlanner.challenge(in: topology, poweredOff: [], using: &generator) else {
                preconditionFailure("\(label): no se pudo preparar el reto")
            }
            precondition(challenge.faultID != challenge.source && challenge.faultID != challenge.destination)
            guard let fault = topology.devices.first(where: { $0.id == challenge.faultID }),
                  let source = topology.devices.first(where: { $0.id == challenge.source }),
                  let destination = topology.devices.first(where: { $0.id == challenge.destination }) else {
                preconditionFailure("\(label): reto con equipos inexistentes")
            }
            precondition(LabFairPlanner.canFail(fault) && fault.name == challenge.faultName)
            precondition(fault.placementID == challenge.faultPlacementID)

            let before = topology.diagnosePing(from: source, to: destination, poweredOff: [])
            precondition(before.issue == nil && before.path?.devices.contains(where: { $0.id == fault.id }) == true)

            let broken = topology.diagnosePing(from: source, to: destination, poweredOff: [fault.id])
            precondition(broken.issue != nil, "\(label): apagar \(fault.name) no corta el ping")
            if let journey = LabPacketJourney(diagnosis: broken, topology: topology) {
                precondition(journey.blocked)
                if broken.blockedLink != nil {
                    precondition(journey.hops.last?.dies == true)
                    precondition(journey.hops.dropLast().allSatisfy { !$0.dies })
                }
            }
            precondition(challenge.remaining(at: challenge.started) == LabFairChallenge.duration)
            precondition(challenge.remaining(at: challenge.started.addingTimeInterval(90)) == 0)
        }
    }

    static func checkLeaderboard() {
        let suite = "org.unsm.NexusRoomCapture.fair-check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Sin UserDefaults de prueba") }
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(LabFairLeaderboard.load(defaults).isEmpty)
        for (index, seconds) in [31.0, 12.5, 48.2, 9.1, 22.0, 15.0, 60.0].enumerated() {
            LabFairLeaderboard.record(.init(name: "Jugador \(index)", seconds: seconds, date: .now), in: defaults)
        }
        let scores = LabFairLeaderboard.load(defaults)
        precondition(scores.map(\.seconds) == [9.1, 12.5, 15.0, 22.0, 31.0])
        precondition(LabFairLeaderboard.qualifies(20, in: scores))
        precondition(!LabFairLeaderboard.qualifies(40, in: scores))
        LabFairLeaderboard.reset(defaults)
        precondition(LabFairLeaderboard.load(defaults).isEmpty)
    }
}
