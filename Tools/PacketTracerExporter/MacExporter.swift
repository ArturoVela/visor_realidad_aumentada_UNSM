// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import UniformTypeIdentifiers

private struct ExportResult: Sendable {
    let succeeded: Bool
    let message: String
}

private enum Exporter {
    /// The child process receives paths as arguments; no shell or Packet Tracer commands are run.
    nonisolated static func run(python: String, script: String, input: String, output: String, replace: Bool) -> ExportResult {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", script, input, "-o", output] + (replace ? ["--force"] : [])
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
                return ExportResult(succeeded: false, message: "La exportación se interrumpió o superó dos minutos. El archivo original se conserva. Prueba con un laboratorio menor.")
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
    private let status = NSTextField(wrappingLabelWithString: "Elige un laboratorio para comenzar.")
    private let fileName = NSTextField(wrappingLabelWithString: "Sólo laboratorios .pkt; las actividades .pka no se exportan.")
    private let choose = NSButton(title: "Elegir archivo .pkt…", target: nil, action: nil)
    private let reveal = NSButton(title: "Mostrar archivo", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var savedURL: URL?
    private var exporting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = NSView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Nexus Packet Exporter"
        window.contentMinSize = NSSize(width: 500, height: 440)
        window.contentView = view
        let title = NSTextField(labelWithString: "Tu laboratorio, en Nexus AR")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "Convierte un archivo de Packet Tracer a .nexus.json para abrirlo en el iPhone. Funciona localmente, sin conexión.")
        description.font = .systemFont(ofSize: 14)
        fileName.textColor = .secondaryLabelColor
        fileName.isSelectable = true
        fileName.maximumNumberOfLines = 2
        fileName.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(wrappingLabelWithString: "La configuración se conserva como texto. Revisa el archivo antes de compartirlo; los servicios y protocolos no se ejecutan.")
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12)
        choose.target = self; choose.action = #selector(selectFile)
        choose.bezelStyle = .rounded; choose.keyEquivalent = "\r"
        reveal.target = self; reveal.action = #selector(showFile)
        reveal.bezelStyle = .rounded; reveal.isHidden = true
        progress.style = .spinning; progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let buttons = NSStackView(views: [choose, reveal, progress])
        buttons.orientation = .horizontal; buttons.spacing = 12; buttons.alignment = .centerY
        let stack = NSStackView(views: [title, description, fileName, status, buttons, detail])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24)
        ])
        for label in [description, fileName, status, detail] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
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
            guard response == .OK, let url = panel.url else { return }
            self?.selectDestination(for: url)
        }
    }

    private func selectDestination(for source: URL) {
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
        guard let python = Bundle.main.object(forInfoDictionaryKey: "NexusPythonExecutable") as? String,
              FileManager.default.isExecutableFile(atPath: python),
              let script = Bundle.main.url(forResource: "export_pkt", withExtension: "py") else {
            showError("No se encuentra el entorno local o el exportador. Reconstruye esta utilidad con build-mac-app.sh después de preparar el entorno de NexusPacketExporter.")
            return
        }
        // NSSavePanel has already asked for confirmation if this exact destination exists.
        let replace = FileManager.default.fileExists(atPath: destination.path)
        exporting = true; choose.isEnabled = false; reveal.isHidden = true
        window.standardWindowButton(.closeButton)?.isEnabled = false
        savedURL = nil; fileName.stringValue = source.lastPathComponent
        status.stringValue = "Exportando laboratorio…"
        progress.startAnimation(nil)
        let input = source.path, output = destination.path, scriptPath = script.path
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Exporter.run(python: python, script: scriptPath, input: input, output: output, replace: replace)
            }.value
            guard let self else { return }
            self.exporting = false; self.choose.isEnabled = true
            self.window.standardWindowButton(.closeButton)?.isEnabled = true
            self.progress.stopAnimation(nil)
            if result.succeeded {
                self.savedURL = destination
                self.fileName.stringValue = destination.path
                self.fileName.toolTip = destination.path
                self.status.stringValue = "Archivo guardado. Envíalo por AirDrop al iPhone y abre Importar en Nexus AR."
                self.choose.title = "Exportar otro .pkt…"
                self.reveal.isHidden = false
            } else {
                self.showError(result.message.isEmpty ? "El exportador terminó sin guardar un archivo. Inténtalo con otro laboratorio .pkt." : result.message)
            }
        }
    }

    @objc private func showFile() {
        if let savedURL { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
    }

    private func showError(_ message: String) {
        status.stringValue = "No se pudo exportar. Revisa el error y vuelve a intentarlo."
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No se pudo exportar el laboratorio"
        alert.informativeText = message
        alert.addButton(withTitle: "Aceptar")
        alert.beginSheetModal(for: window)
    }
}

@main
private enum Main {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--help") {
            print("Nexus Packet Exporter: abre esta app para elegir .pkt y guardar .nexus.json. Requiere el entorno local configurado al compilar; no instala paquetes ni accede a redes.")
            return
        }
        let app = NSApplication.shared, delegate = ExportApp()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
