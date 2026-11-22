import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

struct LabCatalogView: View {
    let onOpen: (LabPublicationCache.Opened, Bool) -> Void
    @State private var cloud = LabCloud.savedSession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var email = ""
    @State private var pin = ""
    @State private var accessRequest: LabCloud.RequestKind?
    @State private var manualCode = ""
    @State private var scanned: String?
    @State private var scanning = false
    @State private var signingIn = false
    @State private var error: String?
    @FocusState private var field: Field?

    private enum Field { case email, pin, asset }

    private var canSignIn: Bool { !signingIn && email.contains("@") && pin.utf8.count == 6 }

    var body: some View {
        NavigationStack {
            Group {
                if let cloud {
                    LabCatalogFolder(cloud: cloud, parent: nil, onOpen: onOpen) {
                        Section("Buscar servidor") {
                            Button("Escanear QR", systemImage: "qrcode.viewfinder", action: scan)
                            TextField("Código impreso", text: $manualCode)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                                .focused($field, equals: .asset).submitLabel(.search)
                                .onSubmit(openManualCode)
                            Button("Buscar por código", systemImage: "magnifyingglass", action: openManualCode)
                                .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Section {
                            LabeledContent(cloud.session.role.name, value: cloud.session.email)
                            if cloud.session.isOwner {
                                NavigationLink("Usuarios y permisos") { LabManageAccess(cloud: cloud) }
                            }
                            Button("Cerrar sesión") {
                                self.cloud = nil
                                pin = ""
                                manualCode = ""
                                scanned = nil
                                Task { await cloud.signOut() }
                            }
                        }
                    }
                } else {
                    Form {
                        Section("Acceso al laboratorio") {
                            TextField("Correo", text: $email)
                                .keyboardType(.emailAddress).textContentType(.username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($field, equals: .email).submitLabel(.next)
                                .onSubmit { field = .pin }
                            SecureField("PIN de 6 dígitos", text: $pin)
                                .keyboardType(.numberPad).textContentType(.password)
                                .focused($field, equals: .pin)
                                .onChange(of: pin) {
                                    pin = String(decoding: pin.utf8.filter { (48...57).contains($0) }.prefix(6), as: UTF8.self)
                                }
                        }
                        Section {
                            Button(action: signIn) {
                                Group {
                                    if signingIn { ProgressView().tint(.white).accessibilityLabel("Iniciando sesión") }
                                    else { Text("Iniciar sesión").fontWeight(.semibold) }
                                }
                                .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSignIn)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }
                        Section {
                            Button("Solicitar cuenta", systemImage: "person.badge.plus") { accessRequest = .alta }
                            Button("Olvidé mi PIN", systemImage: "key") { accessRequest = .restablecer }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .navigationTitle("Catálogo UNSM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DismissButton() }
            .task(id: scenePhase) {
                if scenePhase == .active { await refreshSession() }
            }
            .sheet(item: $accessRequest) { kind in
                NavigationStack { LabAccessRequestForm(kind: kind, email: email) }
            }
            .navigationDestination(item: $scanned) { code in
                if let cloud { LabCatalogServer(cloud: cloud, code: code, name: code, onOpen: onOpen) }
            }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    LabLabelScanner { result in
                        scanning = false
                        switch result {
                        case .success(let code): scanned = code
                        case .failure(let problem): error = problem.localizedDescription
                        }
                    }
                    .navigationTitle("Escanea el QR del servidor")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { DismissButton() }
                }
            }
            .catalogError($error)
        }
    }

    private func signIn() {
        guard canSignIn else { return }
        field = nil
        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                let signed = try await LabCloud.signIn(email: email, pin: pin)
                pin = ""
                do { try await signed.remember() }
                catch { self.error = "Sesión iniciada. El llavero no pudo guardarla en este iPhone." }
                cloud = signed
            } catch { self.error = error.localizedDescription }
        }
    }

    private func refreshSession() async {
        guard let account = cloud else { return }
        do {
            let updated = try await account.refreshedSession()
            guard cloud?.session.sessionID == account.session.sessionID else { return }
            cloud = updated
        } catch let failure as LabCloud.Failure where failure.status == 401 {
            guard cloud?.session.sessionID == account.session.sessionID else { return }
            await account.forget()
            guard cloud?.session.sessionID == account.session.sessionID else { return }
            cloud = nil
            error = failure.message
        } catch {
            // A saved session can still open downloaded labs while offline.
        }
    }

    private func openManualCode() {
        field = nil
        do { scanned = try LabPublication.validateAsset(manualCode) }
        catch { self.error = error.localizedDescription }
    }

    private func scan() {
        guard DataScannerViewController.isSupported else {
            error = "Este dispositivo no permite escanear el QR con la cámara. Escribe el código impreso."
            return
        }
        Task {
            guard await CaptureController.requestCameraAccess(), DataScannerViewController.isAvailable else {
                error = "Autoriza Cámara en Ajustes o escribe el código impreso."
                return
            }
            scanning = true
        }
    }
}

private struct LabAccessRequestForm: View {
    let kind: LabCloud.RequestKind
    @State var email: String
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if sent {
                Section {
                    Label("Solicitud recibida", systemImage: "checkmark.circle")
                    Text("Si corresponde, la administración revisará el correo y te entregará un PIN cuando apruebe la solicitud.")
                    Button("Listo") { dismiss() }
                }
            } else {
                Section {
                    TextField("Correo", text: $email)
                        .keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Enviar solicitud") { Task { await submit() } }
                        .disabled(sending || !email.contains("@"))
                    if sending { ProgressView("Enviando…") }
                } footer: {
                    Text("La administración del laboratorio revisa las solicitudes.")
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DismissButton() }
        .catalogError($error)
    }

    private func submit() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        do {
            try await LabCloud.requestAccess(email: email, kind: kind)
            sent = true
        } catch { self.error = error.localizedDescription }
    }
}

private struct LabCatalogFolder<Header: View>: View {
    let cloud: LabCloud
    let parent: LabCloud.Node?
    let onOpen: (LabPublicationCache.Opened, Bool) -> Void
    @ViewBuilder let header: () -> Header
    @State private var nodes: [LabCloud.Node] = []
    @State private var name = ""
    @State private var creating = false
    @State private var creatingRack = false
    @State private var rackUnits = 42
    @State private var busy = false
    @State private var error: String?

    private var next: LabCloud.Kind { parent?.kind.child ?? .classroom }

    var body: some View {
        List {
            header()
            Section {
                ForEach(nodes) { node in
                    NavigationLink {
                        if let code = node.code {
                            LabCatalogServer(cloud: cloud, code: code, name: node.name, onOpen: onOpen)
                        } else {
                            LabCatalogFolder<EmptyView>(cloud: cloud, parent: node, onOpen: onOpen) { EmptyView() }
                        }
                    } label: {
                        if let version = node.version { LabeledContent(node.name, value: "v\(version)") }
                        else if let units = node.rackUnits { LabeledContent(node.name, value: "\(units) U") }
                        else { Text(node.name) }
                    }
                }
                if busy { ProgressView("Consultando catálogo…") }
                if cloud.session.role != .estudiante {
                    Button(next.addLabel, systemImage: "plus") {
                        name = ""
                        if next == .rack { creatingRack = true }
                        else { creating = true }
                    }.disabled(busy)
                } else if nodes.isEmpty && !busy {
                    Text("Todavía no hay registros en esta ubicación.").foregroundStyle(.secondary)
                }
            } header: {
                if parent == nil { Text("Aulas") }
            }
        }
        .navigationTitle(parent?.name ?? "Catálogo UNSM")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .alert(next.addLabel, isPresented: $creating) {
            TextField("Nombre", text: $name)
            Button("Crear") { Task { await create() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancelar", role: .cancel) {}
        }
        .sheet(isPresented: $creatingRack) {
            NavigationStack {
                Form {
                    TextField("Nombre", text: $name)
                    Picker("Capacidad del rack", selection: $rackUnits) {
                        ForEach([12, 24, 42], id: \.self) { Text("\($0) U").tag($0) }
                    }
                    Button("Crear rack") {
                        Task { if await create(rackUnits: rackUnits) { creatingRack = false } }
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .navigationTitle("Añadir rack")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { DismissButton() }
                .catalogError($error)
            }
        }
        .catalogError($error)
    }

    private func reload() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { nodes = try await cloud.children(of: parent?.id) }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }

    @discardableResult
    private func create(rackUnits: Int? = nil) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let node = try await cloud.create(name: name, parent: parent?.id, rackUnits: rackUnits)
            nodes.append(node)
            nodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

private struct LabCatalogServer: View {
    let cloud: LabCloud
    let code: String
    let name: String
    let onOpen: (LabPublicationCache.Opened, Bool) -> Void
    @State private var opened: LabPublicationCache.Opened?
    @State private var file: URL?
    @State private var showFiles = false
    @State private var showLabel = false
    @State private var device = ""
    @State private var physicalTest = false
    @State private var busy = false
    @State private var requestID = UUID()
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section("Servidor de prácticas") {
                LabeledContent("Código", value: code)
                Button("Etiqueta QR", systemImage: "qrcode") { showLabel = true }
                Button("Buscar última versión", systemImage: "arrow.clockwise") { Task { await reload() } }.disabled(busy)
            }
            if let opened {
                Section("Publicación") {
                    if opened.release.demo == true {
                        Label("Demostración de Packet Tracer", systemImage: "graduationcap")
                    }
                    if let units = opened.release.rackUnits { LabeledContent("Rack", value: "\(units) U") }
                    LabeledContent(opened.fromCache ? "Copia en este iPhone" : "Versión publicada", value: "v\(opened.release.version)")
                    LabeledContent("Fecha", value: opened.release.publishedAt.formatted(date: .abbreviated, time: .shortened))
                    if let equipment = opened.project.topology.devices.first(where: { $0.id == opened.release.deviceID }) {
                        NavigationLink("Ficha de \(equipment.name)") { DeviceInspector(device: equipment, topology: opened.project.topology) }
                    }
                    Button("Abrir en 3D", systemImage: "cube") { onOpen(opened, false) }
                    Button("Guardar copia de práctica", systemImage: "square.on.square") { onOpen(opened, true) }
                }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
            if busy { ProgressView("Procesando catálogo…") }
            if cloud.session.role != .estudiante {
                Section("Publicar una versión") {
                    Button(file?.lastPathComponent ?? "Elegir archivo .pkt", systemImage: "doc.badge.plus") { showFiles = true }
                    TextField("Nombre o ID del equipo en Packet Tracer", text: $device)
                        .autocorrectionDisabled()
                        .onChange(of: device) { requestID = UUID(); physicalTest = false }
                    Toggle("Probado en el equipo físico de prácticas", isOn: $physicalTest)
                    Button("Subir y publicar", systemImage: "square.and.arrow.up") { Task { await publish() } }
                        .disabled(busy || file == nil || !physicalTest || device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .task { await reload() }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                guard url.pathExtension.lowercased() == "pkt" else { error = "Elige un archivo .pkt de Packet Tracer."; return }
                file = url
                requestID = UUID()
                physicalTest = false
            case .failure(let problem): error = problem.localizedDescription
            }
        }
        .sheet(isPresented: $showLabel) { LabPrintableLabel(code: code, name: name) }
        .catalogError($error)
    }

    private func reload() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            opened = try await cloud.latest(code)
            message = opened?.fromCache == true ? "No se pudo confirmar una versión más reciente." : nil
        } catch let failure as LabCloud.Failure where failure.status == 404 {
            message = failure.message
            opened = nil
        } catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }

    private func publish() async {
        guard !busy, let file, physicalTest else { return }
        busy = true
        do {
            let version = try await cloud.publish(file, to: code, device: device, requestID: requestID)
            self.file = nil
            physicalTest = false
            busy = false
            await reload()
            if opened?.fromCache == false { message = "Se publicó la versión \(version)." }
        } catch {
            busy = false
            self.error = error.localizedDescription
        }
    }
}

private struct LabReviewAccess: View {
    let cloud: LabCloud
    let entry: LabCloud.AccessRequest
    @State private var role: LabCloud.Role = .estudiante
    @State private var approved: LabCloud.Account?
    @State private var busy = false
    @State private var confirm = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                LabeledContent("Correo", value: entry.email)
                LabeledContent("Solicitud", value: entry.kind.reason)
                if approved == nil, entry.kind == .alta {
                    Picker("Permiso", selection: $role) {
                        Text("Estudiante · consulta").tag(LabCloud.Role.estudiante)
                        Text("Docente · publicación").tag(LabCloud.Role.docente)
                    }
                }
            }
            if let approved {
                Section {
                    LabeledContent("PIN", value: approved.pin)
                        .monospacedDigit().textSelection(.enabled)
                    Button("Listo") { dismiss() }
                } footer: {
                    Text("Entrega el PIN a \(approved.email) por un canal privado. Podrás generar otro si se pierde.")
                }
            } else {
                Section {
                    Button(entry.kind == .alta ? "Aprobar cuenta" : "Generar nuevo PIN") { confirm = true }
                    Button("Rechazar solicitud", role: .destructive) { Task { await review(approve: false) } }
                }
                .disabled(busy)
                if busy { ProgressView("Guardando…") }
            }
        }
        .navigationTitle("Revisar solicitud")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DismissButton() }
        .confirmationDialog(entry.kind == .alta ? "¿Verificaste la identidad de esta persona?" :
                                "¿Verificaste la identidad de quien pidió el PIN?", isPresented: $confirm, titleVisibility: .visible) {
            Button(entry.kind == .alta ? "Aprobar cuenta" : "Restablecer PIN") { Task { await review(approve: true) } }
        } message: {
            if entry.kind == .restablecer { Text("El PIN anterior y las sesiones activas quedarán revocados.") }
        }
        .catalogError($error)
    }

    private func review(approve: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if approve { approved = try await cloud.approve(entry, role: entry.kind == .alta ? role : nil) }
            else {
                try await cloud.dismiss(entry)
                dismiss()
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct LabManageAccess: View {
    let cloud: LabCloud
    @State private var users: [LabCloud.User] = []
    @State private var pending: [LabCloud.AccessRequest] = []
    @State private var selected: LabCloud.AccessRequest?
    @State private var error: String?

    var body: some View {
        List {
            Section("Solicitudes pendientes") {
                ForEach(pending) { entry in
                    Button { selected = entry } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.email)
                            Text(entry.kind.reason).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if pending.isEmpty { Text("Sin solicitudes pendientes").foregroundStyle(.secondary) }
            }
            Section("Cuentas del laboratorio") {
                ForEach(users) { user in
                    NavigationLink {
                        LabEditAccess(cloud: cloud, user: user) { updated in
                            if let index = users.firstIndex(where: { $0.id == updated.id }) { users[index] = updated }
                        }
                    } label: {
                        LabeledContent(user.email, value: user.active ? user.role.name : "Desactivada")
                    }
                }
            }
        }
        .navigationTitle("Usuarios y permisos")
        .sheet(item: $selected, onDismiss: { Task { await refresh() } }) { entry in
            NavigationStack { LabReviewAccess(cloud: cloud, entry: entry) }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .catalogError($error)
    }

    private func refresh() async {
        do {
            async let accounts = cloud.users()
            async let requests = cloud.pendingRequests()
            (users, pending) = try await (accounts, requests)
        }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}

private struct LabEditAccess: View {
    let cloud: LabCloud
    let user: LabCloud.User
    let onSave: (LabCloud.User) -> Void
    @State var role: LabCloud.Role = .estudiante
    @State var active = false
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Picker("Permiso", selection: $role) {
                Text("Estudiante · consulta").tag(LabCloud.Role.estudiante)
                Text("Docente · publicación").tag(LabCloud.Role.docente)
            }
            Toggle("Cuenta activa", isOn: $active)
            Button("Guardar permisos") { Task { await save() } }
                .disabled(busy || (role == user.role && active == user.active))
        }
        .navigationTitle(user.email)
        .onAppear { role = user.role; active = user.active }
        .catalogError($error)
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            onSave(try await cloud.updateUser(user, role: role, active: active))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct LabLabelScanner: UIViewControllerRepresentable {
    let onResult: (Result<String, any Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let reader = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                               qualityLevel: .balanced, recognizesMultipleItems: false,
                                               isGuidanceEnabled: true, isHighlightingEnabled: true)
        reader.delegate = context.coordinator
        Task { @MainActor [weak reader, weak coordinator = context.coordinator] in
            do { try reader?.startScanning() }
            catch { coordinator?.finish(.failure(error), reader: reader) }
        }
        return reader
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        coordinator.finished = true
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onResult: (Result<String, any Error>) -> Void
        var finished = false

        init(onResult: @escaping (Result<String, any Error>) -> Void) { self.onResult = onResult }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue else { continue }
                finish(Result { try LabPublication.asset(fromQR: payload) }, reader: dataScanner)
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            finish(.failure(error), reader: dataScanner)
        }

        func finish(_ result: Result<String, any Error>, reader: DataScannerViewController?) {
            guard !finished else { return }
            finished = true
            reader?.stopScanning()
            onResult(result)
        }
    }
}

private struct LabPrintableLabel: View {
    let code: String
    let name: String
    @State private var label: LabelPDF?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text(name).font(.headline)
                    if let label {
                        Image(uiImage: label.qr).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 184, height: 184).padding(16).background(.white)
                            .accessibilityLabel("QR del servidor")
                        Text(code).font(.body.monospaced()).textSelection(.enabled)
                        ShareLink(item: label, preview: SharePreview("Etiqueta QR de \(code)", image: Image(uiImage: label.qr))) {
                            Label("Compartir etiqueta PDF", systemImage: "square.and.arrow.up")
                        }
                    } else { Text("No se pudo crear la etiqueta.").foregroundStyle(.secondary) }
                }.padding(20).frame(maxWidth: .infinity)
            }
            .navigationTitle("Etiqueta QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DismissButton() }
        }
        .task { label = LabelPDF(code: code, name: name) }
    }

    private struct LabelPDF: Transferable {
        let data: Data
        let qr: UIImage

        init?(code: String, name: String) {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(LabPublication.qrPayload(for: code).utf8)
            filter.correctionLevel = "M"
            guard let image = filter.outputImage, let bitmap = CIContext().createCGImage(image, from: image.extent) else { return nil }
            qr = UIImage(cgImage: bitmap)
            let page = CGRect(x: 0, y: 0, width: 216, height: 225)
            let renderer = UIGraphicsPDFRenderer(bounds: page)
            let view = qr
            data = renderer.pdfData { context in
                context.beginPage()
                UIColor.white.setFill(); context.cgContext.fill(page)
                context.cgContext.interpolationQuality = .none
                view.draw(in: CGRect(x: 39, y: 19, width: 138, height: 138))
                let centered = NSMutableParagraphStyle()
                centered.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10), .paragraphStyle: centered]
                (code as NSString).draw(in: CGRect(x: 12, y: 164, width: 192, height: 20), withAttributes: attributes)
                ("Laboratorio de pruebas UNSM" as NSString).draw(in: CGRect(x: 12, y: 184, width: 192, height: 18), withAttributes: attributes)
                (name as NSString).draw(in: CGRect(x: 12, y: 201, width: 192, height: 22), withAttributes: attributes)
            }
        }

        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(exportedContentType: .pdf) { $0.data }.suggestedFileName("Nexus-QR")
        }
    }
}

private extension View {
    func catalogError(_ error: Binding<String?>) -> some View {
        alert("Catálogo UNSM", isPresented: Binding(get: { error.wrappedValue != nil }, set: {
            if !$0 { error.wrappedValue = nil }
        })) { Button("Cerrar", role: .cancel) {} } message: { Text(error.wrappedValue ?? "") }
    }
}
