import SafariServices

/// Fork: the Safari extension only runs a content script (Resources/content.js) and never messages
/// the app, so this just completes any native request with no reply.
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: [], completionHandler: nil)
    }
}
