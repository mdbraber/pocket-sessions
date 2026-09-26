import UIKit
import UniformTypeIdentifiers
import Social

class ShareViewController: UIViewController {

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        let content = extensionContext?.inputItems.first as? NSExtensionItem

        // Fork: a shared web link. Pocket Casts links open in the app, other links are tried as a feed URL.
        if let linkAttachment = content?.attachments?.first(where: isWebLink) {
            loadWebLink(from: linkAttachment)
            return
        }

        guard let attachment = content?.attachments?.first as? NSItemProvider else {
            close()
            return
        }

        let acceptedTypes: [UTType] = [.audio, .movie, .data]

        if let type = acceptedTypes.first(where: { attachment.hasItemConformingToTypeIdentifier($0.identifier) }) {
            loadFile(from: attachment, identifier: type.identifier)
        }
    }

    func redirectToHostApp(_ url: String) {
        guard let url = URL(string: "pktc://import-file/\(url)") else {
            return
        }

        openHostApp(url)
    }

    private func openHostApp(_ url: URL) {
        let context = NSExtensionContext()
        context.open(url as URL, completionHandler: nil)
        var responder = self as UIResponder?

        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
            }
            responder = responder?.next
        }
    }

    private func loadFile(from attachment: NSItemProvider, identifier: String) {
        attachment.loadItem(forTypeIdentifier: identifier, options: nil) { [weak self] data, _ in
            guard let url = data as? URL else {
                return
            }

            // Save the file to the shared group directory
            let fileManager = FileManager.default
            guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.GroupUserDefaults.groupContainerId) else {
                return
            }

            let destURL: URL
            if identifier == UTType.data.identifier {
                destURL = container.appendingPathComponent("opml.opml")
            } else {
                destURL = container.appendingPathComponent(url.lastPathComponent)
            }

            do { try FileManager.default.copyItem(at: url, to: destURL) } catch { }

            self?.close()

            // Redirect to Pocket Casts to handle the file
            self?.redirectToHostApp(destURL.absoluteString)
        }
    }

    /// A web link, not a file: files keep going through `loadFile` exactly as before.
    private func isWebLink(_ attachment: NSItemProvider) -> Bool {
        let fileTypes = [UTType.fileURL.identifier, UTType.audio.identifier, UTType.movie.identifier, "public.opml", "unofficial.opml", "org.opml.opml"]
        guard attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return false }
        return !fileTypes.contains { attachment.hasItemConformingToTypeIdentifier($0) }
    }

    private func loadWebLink(from attachment: NSItemProvider) {
        attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] data, _ in
            let sharedURL: URL? = {
                switch data {
                case let url as URL: return url
                case let string as String: return URL(string: string)
                case let data as Data: return URL(dataRepresentation: data, relativeTo: nil)
                default: return nil
                }
            }()

            DispatchQueue.main.async {
                self?.close()

                guard let sharedURL, var components = URLComponents(url: sharedURL, resolvingAgainstBaseURL: false),
                      let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }

                let route: String
                if PocketCastsWebLink.isPocketCastsHost(components.host) {
                    route = "weblink"
                    components.scheme = "https" // the app only opens https Pocket Casts links
                } else {
                    route = "subscribe"
                }
                guard let webURL = components.url, let appURL = URL(string: "pktc://\(route)/\(webURL.absoluteString)") else { return }

                self?.openHostApp(appURL)
            }
        }
    }

    private func close() {
        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
