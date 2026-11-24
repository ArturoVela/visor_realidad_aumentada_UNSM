//
//  LabCollaboration.swift
//  NexusRoomCapture
//
//  Created for CISCO NEXUS AR — UNSM.
//  Sesión de trabajo colaborativa AR en tiempo real multi-iPhone (P2P).
//

import Foundation
import MultipeerConnectivity
import ARKit
import RealityKit
import SwiftUI

// MARK: - Protocolo de Mensajes Colaborativos

enum LabSyncMessage: Codable, Sendable {
    case handshake(peerName: String, isHost: Bool, isPresentationMode: Bool)
    case requestInitialState
    case syncTopology(LabTopology, scale: Float)
    case arCollaborationData(Data)
    case acquireLock(targetID: String, peerName: String)
    case releaseLock(targetID: String)
    case movePlacement(placementID: String, x: Float, y: Float, z: Float, yaw: Float)
    case connectCable(sourceID: String, sourcePort: String, targetID: String, targetPort: String, medium: String)
    case disconnectCable(cableID: String)
    case updateDeviceProperty(deviceID: String, key: String, value: String)
    case setDevicePower(deviceID: String, isOn: Bool)
    case alignMarker(transform: [Float])
    case setPresentationMode(enabled: Bool)
    case userPointer(origin: [Float], direction: [Float])
}

// MARK: - Estado de Conexión

enum CollabConnectionStatus: Equatable, Sendable {
    case idle
    case hosting(String)
    case browsing
    case connecting(String)
    case connected(peerName: String, isHost: Bool)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .idle: return "Desconectado"
        case .hosting: return "Transmitiendo sesión..."
        case .browsing: return "Buscando iPhones cercanos..."
        case .connecting(let name): return "Conectando con \(name)..."
        case .connected(let name, let isHost):
            return isHost ? "Anfitrión (conectado a \(name))" : "Conectado a \(name)"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

// MARK: - Gestor de Red Peer-to-Peer (NexusPeerSession)

@Observable
final class NexusPeerSession: NSObject, @unchecked Sendable {
    static let serviceType = "nexus-collab"

    var status: CollabConnectionStatus = .idle
    var discoveredHosts: [MCPeerID] = []
    var isHost: Bool = false
    var isPresentationOnly: Bool = false
    var connectedPeerName: String? = nil
    var activeLocks: [String: String] = [:] // [targetID: peerName]
    var isSpatialAligned: Bool = false
    var spatialAlignmentMethod: String = "Automática (ARKit)"

    // Alertas visuales para el HUD
    var lastActionAlert: String? = nil

    private let myPeerID: MCPeerID
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    var onMessageReceived: ((LabSyncMessage) -> Void)?
    var onCollaborationDataReceived: ((ARSession.CollaborationData) -> Void)?

    override init() {
        let deviceName = UIDevice.current.name
        self.myPeerID = MCPeerID(displayName: deviceName)
        super.init()
        self.session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        self.session.delegate = self
    }

    // MARK: - Control de Sesión

    func startHosting() {
        stopAll()
        isHost = true
        status = .hosting(myPeerID.displayName)

        advertiser = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: ["version": "1.0", "host": myPeerID.displayName],
            serviceType: Self.serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
    }

    func startBrowsing() {
        stopAll()
        isHost = false
        status = .browsing
        discoveredHosts.removeAll()

        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
    }

    func connect(to peer: MCPeerID) {
        guard let browser else { return }
        status = .connecting(peer.displayName)
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 20)
    }

    func disconnect() {
        stopAll()
        status = .idle
    }

    private func stopAll() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil

        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil

        session.disconnect()
        discoveredHosts.removeAll()
        activeLocks.removeAll()
        connectedPeerName = nil
        isSpatialAligned = false
        lastActionAlert = nil
    }

    // MARK: - Envío de Mensajes

    func sendReliable(_ message: LabSyncMessage) {
        guard let peer = session.connectedPeers.first else { return }
        do {
            let data = try PropertyListEncoder().encode(message)
            try session.send(data, toPeers: [peer], with: .reliable)
        } catch {
            print("[NexusPeerSession] Error enviando mensaje confiable: \(error.localizedDescription)")
        }
    }

    func sendUnreliable(_ message: LabSyncMessage) {
        guard let peer = session.connectedPeers.first else { return }
        do {
            let data = try PropertyListEncoder().encode(message)
            try session.send(data, toPeers: [peer], with: .unreliable)
        } catch {
            print("[NexusPeerSession] Error enviando mensaje no confiable: \(error.localizedDescription)")
        }
    }

    func sendARCollaborationData(_ data: ARSession.CollaborationData) {
        do {
            let archived = try NSKeyedArchiver.archivedData(withRootObject: data, requiringSecureCoding: true)
            sendUnreliable(.arCollaborationData(archived))
        } catch {
            print("[NexusPeerSession] Error archivando ARCollaborationData: \(error.localizedDescription)")
        }
    }

    // MARK: - Control de Candados Dinámicos (Soft Locking)

    /// Intenta adquirir el candado de un objeto antes de moverlo.
    /// Devuelve true si el objeto está libre para manipularse.
    func requestLock(for targetID: String) -> Bool {
        if isPresentationOnly && !isHost {
            Task { @MainActor in
                self.lastActionAlert = "Modo presentación: solo el anfitrión puede editar."
            }
            return false
        }

        if let holder = activeLocks[targetID], holder != myPeerID.displayName {
            Task { @MainActor in
                self.lastActionAlert = "Elemento en uso por \(holder)."
            }
            return false
        }

        activeLocks[targetID] = myPeerID.displayName
        sendReliable(.acquireLock(targetID: targetID, peerName: myPeerID.displayName))
        return true
    }

    /// Libera el candado tras soltar el objeto manipulado.
    func releaseLock(for targetID: String) {
        if activeLocks[targetID] == myPeerID.displayName {
            activeLocks.removeValue(forKey: targetID)
            sendReliable(.releaseLock(targetID: targetID))
        }
    }

    /// Verifica si un objeto está bloqueado por el compañero.
    func isLockedByPeer(_ targetID: String) -> Bool {
        guard let holder = activeLocks[targetID] else { return false }
        return holder != myPeerID.displayName
    }

    /// Nombre de quién está manipulando el objeto (si lo hay).
    func lockHolder(for targetID: String) -> String? {
        return activeLocks[targetID]
    }
}

// MARK: - Delegados de MultipeerConnectivity

extension NexusPeerSession: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                self.connectedPeerName = peerID.displayName
                self.status = .connected(peerName: peerID.displayName, isHost: self.isHost)
                self.lastActionAlert = "Conectado con \(peerID.displayName)"
                // Enviar handshake inicial
                self.sendReliable(.handshake(
                    peerName: self.myPeerID.displayName,
                    isHost: self.isHost,
                    isPresentationMode: self.isPresentationOnly
                ))
                if !self.isHost {
                    // El cliente solicita el estado actual del laboratorio
                    self.sendReliable(.requestInitialState)
                }
            case .connecting:
                self.status = .connecting(peerID.displayName)
            case .notConnected:
                if self.connectedPeerName == peerID.displayName {
                    self.connectedPeerName = nil
                    self.activeLocks.removeAll()
                    self.status = .idle
                    self.lastActionAlert = "\(peerID.displayName) se ha desconectado."
                }
            @unknown default:
                break
            }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? PropertyListDecoder().decode(LabSyncMessage.self, from: data) else {
            return
        }

        Task { @MainActor in
            self.handleIncomingMessage(message, from: peerID)
        }
    }

    @MainActor
    private func handleIncomingMessage(_ message: LabSyncMessage, from peerID: MCPeerID) {
        switch message {
        case .handshake(let name, let peerIsHost, let isPres):
            self.connectedPeerName = name
            if !self.isHost { self.isPresentationOnly = isPres }

        case .arCollaborationData(let rawData):
            if let collabData = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: ARSession.CollaborationData.self,
                from: rawData
            ) {
                self.isSpatialAligned = true
                self.onCollaborationDataReceived?(collabData)
            }

        case .acquireLock(let targetID, let peerName):
            self.activeLocks[targetID] = peerName
            self.lastActionAlert = "👤 \(peerName) moviendo..."

        case .releaseLock(let targetID):
            self.activeLocks.removeValue(forKey: targetID)

        case .alignMarker(let matrix):
            self.isSpatialAligned = true
            self.spatialAlignmentMethod = "Marcador de referencia"
            self.lastActionAlert = "Alineación espacial completada por marcador."
            self.onMessageReceived?(message)

        case .setPresentationMode(let enabled):
            if !self.isHost {
                self.isPresentationOnly = enabled
                self.lastActionAlert = enabled ? "El anfitrión activó modo exposición." : "Edición libre habilitada."
            }

        default:
            self.onMessageReceived?(message)
        }
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {}
}

extension NexusPeerSession: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Aceptación automática entre dispositivos Nexus AR autorizados
        invitationHandler(true, self.session)
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        Task { @MainActor in
            self.status = .error("No se pudo iniciar transmisión: \(error.localizedDescription)")
        }
    }
}

extension NexusPeerSession: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        Task { @MainActor in
            if !self.discoveredHosts.contains(peerID) {
                self.discoveredHosts.append(peerID)
            }
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.discoveredHosts.removeAll { $0 == peerID }
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        Task { @MainActor in
            self.status = .error("No se pudo buscar iPhones: \(error.localizedDescription)")
        }
    }
}
