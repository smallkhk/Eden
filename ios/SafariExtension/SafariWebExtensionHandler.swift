import Foundation
import SafariServices

/// Safari web extension host. The extension (shared with Chrome, in /extension) does all its work in the page;
/// nothing is sent to the app.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
