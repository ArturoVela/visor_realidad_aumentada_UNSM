// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CryptoKit
import UniformTypeIdentifiers

private struct ExportResult: Sendable {
    let succeeded: Bool
    let message: String
}

private enum Exporter {
    static var python: String? { Bundle.main.object(forInfoDictionaryKey: "NexusPythonExecutable") as? String }
    static var script: URL? { Bundle.main.url(forResource: "export_pkt", withExtension: "py") }
    static var pairedPhone: String? { Bundle.main.object(forInfoDictionaryKey: "NexusTargetDevice") as? String }
    static var pairedPhoneName: String {
        Bundle.main.object(forInfoDictionaryKey: "NexusTargetDeviceName") as? String ?? "iPhone emparejado"
    }

    /// The child process receives paths as arguments; no shell or Packet Tracer commands are run.
    nonisolated static func run(python: String, script: String, input: String, output: String, replace: Bool) -> ExportResult {
        run(executable: python, arguments: ["-B", script, input, "-o", output] + (replace ? ["--force"] : []))
    }

    static func send(_ source: URL, phone: String) -> ExportResult {
        guard source.isFileURL, source.pathExtension.lowercased() == "pkt",
              let python, FileManager.default.isExecutableFile(atPath: python), let script else {
            return ExportResult(succeeded: false, message: "Selecciona un archivo .pkt y comprueba la instalación de Nexus AR para Mac.")
        }
        let files = FileManager.default
        let temporary = files.temporaryDirectory.appendingPathComponent("nexus-" + UUID().uuidString, isDirectory: true)
        do {
            try files.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: temporary) }
            let output = temporary.appendingPathComponent("export.nexus.json")
            let conversion = run(python: python, script: script.path, input: source.path, output: output.path, replace: false)
            guard conversion.succeeded else { return conversion }

            let data = try Data(contentsOf: output, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let name = String(source.deletingPathExtension().lastPathComponent.unicodeScalars.prefix(36))
            let filename = "\(digest)_\(name).nexus.json"
            let transfer = run(executable: "/usr/bin/xcrun", arguments: [
                "devicectl", "device", "copy", "to", "--device", phone, "--timeout", "30",
                "--domain-type", "appDataContainer", "--domain-identifier", "org.unsm.NexusRoomCapture",
                "--source", output.path, "--destination", "Documents/Labs/received/\(filename)"
            ])
            if transfer.succeeded { return transfer }
            return ExportResult(succeeded: false, message: "Comprueba que el iPhone esté disponible para Xcode. \(transfer.message)")
        } catch {
            return ExportResult(succeeded: false, message: error.localizedDescription)
        }
    }

    nonisolated private static func run(executable: String, arguments: [String]) -> ExportResult {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
            defer { timeout.cancel() }
            // Drain the single combined pipe before waiting, so stderr cannot fill another pipe.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationReason == .uncaughtSignal {
                return ExportResult(succeeded: false, message: "La operación se interrumpió o superó dos minutos. Vuelve a intentarlo.")
            }
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return ExportResult(succeeded: process.terminationStatus == 0,
                                message: String(message.prefix(4096)))
        } catch {
            return ExportResult(succeeded: false, message: error.localizedDescription)
        }
    }
}

@MainActor
private final class ExportApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "")
    private let fileName = NSTextField(wrappingLabelWithString: "Ningún archivo seleccionado")
    private let choose = NSButton(title: "Elegir archivo .pkt…", target: nil, action: nil)
    private let send = NSButton(title: Exporter.pairedPhoneName, target: nil, action: nil)
    private let save = NSButton(title: "Guardar JSON…", target: nil, action: nil)
    private let reveal = NSButton(title: "Mostrar JSON", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var sourceURL: URL?
    private var savedURL: URL?
    private var exporting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = NSView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Nexus AR para Mac"
        window.contentMinSize = NSSize(width: 480, height: 300)
        window.contentView = view
        let icon = NSImageView(image: NSApplication.shared.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56)
        ])
        let title = NSTextField(labelWithString: "Nexus AR")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Laboratorios de Packet Tracer para iPhone")
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 3
        let header = NSStackView(views: [icon, heading])
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 12

        fileName.textColor = .secondaryLabelColor
        fileName.isSelectable = true
        fileName.maximumNumberOfLines = 2
        fileName.lineBreakMode = .byTruncatingMiddle
        status.textColor = .secondaryLabelColor
        for (button, action) in [(choose, #selector(selectFile)), (send, #selector(sendSelectedFile)),
                                 (save, #selector(saveSelectedFile)), (reveal, #selector(showFile))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        send.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        send.imagePosition = .imageLeading
        send.setAccessibilityLabel("Enviar a \(Exporter.pairedPhoneName)")
        send.bezelColor = .systemBlue
        reveal.isHidden = true
        progress.style = .spinning; progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let fileRow = NSStackView(views: [choose, fileName])
        fileRow.orientation = .horizontal; fileRow.alignment = .centerY; fileRow.spacing = 10
        choose.setContentCompressionResistancePriority(.required, for: .horizontal)
        let sendLabel = NSTextField(labelWithString: "Enviar a")
        let actions = NSStackView(views: [sendLabel, send, save, reveal, progress])
        actions.orientation = .horizontal; actions.spacing = 8; actions.alignment = .centerY
        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [header, separator, fileRow, actions, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fileRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateControls()
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.servicesProvider = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !exporting }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard exporting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "La exportación sigue en curso"
        alert.informativeText = "Espera a que termine para cerrar la aplicación. El archivo original se conserva."
        alert.addButton(withTitle: "Continuar exportación")
        alert.runModal()
        return .terminateCancel
    }

    @objc private func selectFile() {
        let panel = NSOpenPanel()
        panel.title = "Elegir laboratorio de Packet Tracer"
        panel.allowedContentTypes = [UTType(filenameExtension: "pkt") ?? .data]
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            selectSource(url)
            status.stringValue = Exporter.pairedPhone == nil
                ? "Elige Guardar JSON para exportar este laboratorio."
                : "Selecciona el iPhone para convertir y enviar el laboratorio."
        }
    }

    @objc private func sendSelectedFile() {
        guard let sourceURL, let phone = Exporter.pairedPhone, !exporting else { return }
        sendFile(sourceURL, to: phone)
    }

    @objc(sendToNexus:userData:error:)
    private func sendToNexus(_ pasteboard: NSPasteboard, userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1, let source = urls.first, source.pathExtension.lowercased() == "pkt" else {
            error?.pointee = "Selecciona un único archivo .pkt."
            return
        }
        guard let phone = Exporter.pairedPhone, !exporting, window.attachedSheet == nil else {
            error?.pointee = "Comprueba la configuración del iPhone y cierra cualquier exportación en curso."
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        selectSource(source)
        sendFile(source, to: phone)
    }

    private func sendFile(_ source: URL, to phone: String) {
        startWork("Convirtiendo y enviando a \(Exporter.pairedPhoneName)…")
        Task {
            let result = await Task.detached(priority: .userInitiated) { Exporter.send(source, phone: phone) }.value
            finishWork()
            if result.succeeded {
                status.stringValue = "Enviado a \(Exporter.pairedPhoneName). Disponible en Laboratorios guardados."
            } else {
                showError(result.message, title: "No se pudo enviar el laboratorio")
            }
        }
    }

    @objc private func saveSelectedFile() {
        guard let source = sourceURL else { return }
        let panel = NSSavePanel()
        panel.title = "Guardar laboratorio para Nexus AR"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".nexus.json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            guard destination.lastPathComponent.lowercased().hasSuffix(".nexus.json") else {
                self?.showError("Usa un nombre que termine en .nexus.json y vuelve a elegir el archivo.")
                return
            }
            self?.export(source: source, destination: destination)
        }
    }

    private func export(source: URL, destination: URL) {
        guard let python = Exporter.python,
              FileManager.default.isExecutableFile(atPath: python),
              let script = Exporter.script else {
            showError("No se encuentra el entorno local o el exportador. Reconstruye esta utilidad con build-mac-app.sh después de preparar el entorno de NexusPacketExporter.")
            return
        }
        // NSSavePanel has already asked for confirmation if this exact destination exists.
        let replace = FileManager.default.fileExists(atPath: destination.path)
        startWork("Guardando JSON…")
        let input = source.path, output = destination.path, scriptPath = script.path
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Exporter.run(python: python, script: scriptPath, input: input, output: output, replace: replace)
            }.value
            guard let self else { return }
            self.finishWork()
            if result.succeeded {
                self.savedURL = destination
                self.status.stringValue = "JSON guardado."
                self.reveal.isHidden = false
            } else {
                self.showError(result.message.isEmpty ? "El exportador terminó sin guardar un archivo. Inténtalo con otro laboratorio .pkt." : result.message)
            }
        }
    }

    private func selectSource(_ source: URL) {
        sourceURL = source
        fileName.stringValue = source.lastPathComponent
        fileName.toolTip = source.path
        savedURL = nil
        reveal.isHidden = true
        updateControls()
    }

    private func updateControls() {
        choose.isEnabled = !exporting
        save.isEnabled = !exporting && sourceURL != nil
        send.isEnabled = save.isEnabled && Exporter.pairedPhone != nil
        reveal.isEnabled = !exporting
        choose.keyEquivalent = send.isEnabled ? "" : "\r"
        send.keyEquivalent = send.isEnabled ? "\r" : ""
    }

    private func startWork(_ message: String) {
        exporting = true
        updateControls()
        window.standardWindowButton(.closeButton)?.isEnabled = false
        status.stringValue = message
        progress.startAnimation(nil)
    }

    private func finishWork() {
        exporting = false
        updateControls()
        window.standardWindowButton(.closeButton)?.isEnabled = true
        progress.stopAnimation(nil)
    }

    @objc private func showFile() {
        if let savedURL { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
    }

    private func showError(_ message: String, title: String = "No se pudo exportar el laboratorio") {
        status.stringValue = title + "."
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Aceptar")
        alert.beginSheetModal(for: window)
    }
}

@main
private enum Main {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--help") {
            print("Nexus AR para Mac: elige un .pkt y envíalo al iPhone configurado o guarda su .nexus.json.")
            return
        }
        if CommandLine.arguments.dropFirst().first == "--register-services" {
            NSUpdateDynamicServices()
            return
        }
        let app = NSApplication.shared, delegate = ExportApp()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
