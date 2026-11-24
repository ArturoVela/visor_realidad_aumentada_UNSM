import Foundation

// MARK: - Packet journey

/// Ordered route of one simulated ping, ready to animate in the scene and describe hop by hop.
nonisolated struct LabPacketJourney: Equatable, Sendable {
    struct Hop: Equatable, Sendable {
        /// Cable traversed in this hop.
        let linkID: String
        /// True when the packet travels from the link's `to` end to its `from` end.
        let reversed: Bool
        /// Device reached at the end of the hop.
        let deviceName: String
        /// Patch panels and other passive pieces are animated but not announced.
        let passive: Bool
        /// The packet stops halfway on this cable because the next device or port fails.
        let dies: Bool
    }

    let sourceName: String
    let hops: [Hop]
    let blocked: Bool

    init?(diagnosis: LabTopology.PingDiagnosis, topology: LabTopology) {
        guard let path = diagnosis.path, let source = path.devices.first else { return nil }
        let order = Dictionary(path.devices.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let inventory = Dictionary(topology.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func stop(_ id: String) -> (name: String, passive: Bool) {
            let device = inventory[id]
            return (device?.name ?? id, device?.modelID.hasPrefix("patch-") == true)
        }
        var hops: [Hop] = []
        var current = source.id
        for link in path.links {
            let reversed: Bool
            if link.fromDeviceID == current { reversed = false }
            else if link.toDeviceID == current { reversed = true }
            else { reversed = (order[link.fromDeviceID] ?? 0) > (order[link.toDeviceID] ?? 0) }
            current = reversed ? link.fromDeviceID : link.toDeviceID
            let reached = stop(current)
            hops.append(.init(linkID: link.id, reversed: reversed, deviceName: reached.name, passive: reached.passive, dies: false))
        }
        if let blockedLink = diagnosis.blockedLink {
            let last = path.devices.last?.id ?? current
            let reversed = blockedLink.toDeviceID == last
            let next = stop(reversed ? blockedLink.fromDeviceID : blockedLink.toDeviceID)
            hops.append(.init(linkID: blockedLink.id, reversed: reversed, deviceName: next.name, passive: next.passive, dies: true))
        }
        guard !hops.isEmpty else { return nil }
        sourceName = source.name
        self.hops = hops
        blocked = diagnosis.issue != nil
    }
}

// MARK: - Fair planner

/// Picks demonstration routes and faults for the fair mode.
nonisolated enum LabFairPlanner {
    struct Route {
        let source: LabTopology.Device
        let destination: LabTopology.Device
        let path: LabTopology.PingPath
    }

    static func isEndpoint(_ device: LabTopology.Device) -> Bool {
        guard device.ipv4 != nil, !device.isAccessPoint, !device.isFanTray else { return false }
        return !["switch-", "router-", "patch-", "firewall-"].contains { device.modelID.hasPrefix($0) }
    }

    /// Devices that can fail in the challenge: anything active between both endpoints.
    static func canFail(_ device: LabTopology.Device) -> Bool {
        !device.modelID.hasPrefix("patch-") && !device.isFanTray
    }

    static func routes<R: RandomNumberGenerator>(in topology: LabTopology, poweredOff: Set<String>,
                                                 attempts: Int = 60, limit: Int = 8, using generator: inout R) -> [Route] {
        func online(_ device: LabTopology.Device) -> Bool {
            !poweredOff.contains(device.id) && !poweredOff.contains(device.placementID)
        }
        var endpoints = topology.devices.filter { isEndpoint($0) && online($0) }
        if endpoints.count < 2 { endpoints = topology.devices.filter { $0.ipv4 != nil && online($0) } }
        guard endpoints.count >= 2 else { return [] }
        var found: [Route] = []
        var tried = Set<String>()
        for _ in 0..<attempts {
            guard let a = endpoints.randomElement(using: &generator) else { break }
            // Same-VLAN pairs reach each other in every demo; other pairs depend on the imported routing.
            let peers = endpoints.filter { $0.id != a.id && (a.vlan == nil || $0.vlan == a.vlan) }
            guard let b = (peers.isEmpty ? endpoints.filter { $0.id != a.id } : peers).randomElement(using: &generator),
                  tried.insert(a.id + "→" + b.id).inserted else { continue }
            let diagnosis = topology.diagnosePing(from: a, to: b, poweredOff: poweredOff)
            guard diagnosis.issue == nil, let path = diagnosis.path, path.devices.count >= 3, !path.links.isEmpty else { continue }
            found.append(.init(source: a, destination: b, path: path))
            if found.count >= limit { break }
        }
        return found
    }

    /// Prefers long routes: they cross more equipment and read better at a distance.
    static func showcase<R: RandomNumberGenerator>(_ routes: [Route], using generator: inout R) -> Route? {
        let ranked = routes.sorted { $0.path.devices.count > $1.path.devices.count }
        return ranked.prefix(3).randomElement(using: &generator)
    }

    static func challenge<R: RandomNumberGenerator>(in topology: LabTopology, poweredOff: Set<String>,
                                                    using generator: inout R) -> LabFairChallenge? {
        let candidates = routes(in: topology, poweredOff: poweredOff, attempts: 160, limit: 24, using: &generator).shuffled(using: &generator)
        for route in candidates.sorted(by: { $0.path.devices.count > $1.path.devices.count }) {
            // Redundant designs survive some failures. Only a device whose loss cuts the ping makes a fair puzzle.
            let middle = route.path.devices.dropFirst().dropLast().filter(canFail).shuffled(using: &generator)
            guard let fault = middle.first(where: { device in
                topology.diagnosePing(from: route.source, to: route.destination,
                                      poweredOff: poweredOff.union([device.id])).issue != nil
            }) else { continue }
            return LabFairChallenge(source: route.source.id, destination: route.destination.id, faultID: fault.id,
                                    faultName: fault.name, faultPlacementID: fault.placementID, started: .now)
        }
        return nil
    }
}

// MARK: - Challenge and ranking

nonisolated struct LabFairChallenge: Equatable, Sendable {
    static let duration: TimeInterval = 60

    let source: String
    let destination: String
    let faultID: String
    let faultName: String
    let faultPlacementID: String
    let started: Date
    var misses = 0

    func remaining(at date: Date) -> TimeInterval { max(0, Self.duration - date.timeIntervalSince(started)) }
}

nonisolated enum LabFairOutcome: Equatable, Sendable {
    case found(seconds: Double, faultName: String, misses: Int)
    case timeout(faultName: String)
}

nonisolated struct LabFairScore: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let name: String
    let seconds: Double
    let date: Date
}

nonisolated enum LabFairLeaderboard {
    static let key = "labFairLeaderboard.v1"
    static let size = 5

    static func load(_ defaults: UserDefaults = .standard) -> [LabFairScore] {
        guard let data = defaults.data(forKey: key),
              let scores = try? JSONDecoder().decode([LabFairScore].self, from: data) else { return [] }
        return scores
    }

    @discardableResult
    static func record(_ score: LabFairScore, in defaults: UserDefaults = .standard) -> [LabFairScore] {
        let scores = Array((load(defaults) + [score]).sorted { $0.seconds < $1.seconds }.prefix(size))
        if let data = try? JSONEncoder().encode(scores) { defaults.set(data, forKey: key) }
        return scores
    }

    static func qualifies(_ seconds: Double, in scores: [LabFairScore]) -> Bool {
        scores.count < size || scores.contains { seconds < $0.seconds }
    }

    static func reset(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
