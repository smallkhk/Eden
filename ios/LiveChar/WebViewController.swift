import UIKit
import WebKit
import Photos
import SafariServices

/// The LiveChar web app in a full-screen WKWebView: camera for the server only, photos/recordings go to Photos,
/// links to other sites open in Safari. Shake the phone for "Change server" / "Reload".
final class WebViewController: UIViewController {
    private var webView: WKWebView!
    private var serverURL: URL?
    private var downloads: [ObjectIdentifier: URL] = [:]
    private var alertUp = false
    private let background = UIColor(red: 0.043, green: 0.051, blue: 0.071, alpha: 1)

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var canBecomeFirstResponder: Bool { true }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()           // keeps the login between launches
        config.applicationNameForUserAgent = "LiveCharIOS/1.0"
        // the page handles pinch-to-zoom on the output itself; stop the whole page from zooming
        let noZoom = """
        (function(){var m=document.querySelector('meta[name=viewport]');
        if(!m){m=document.createElement('meta');m.name='viewport';document.head.appendChild(m);}
        m.content='width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no';})();
        """
        config.userContentController.addUserScript(WKUserScript(source: noZoom, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        webView.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        serverURL = Server.current
        if let url = serverURL { webView.load(URLRequest(url: url)) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        if serverURL == nil { askForServer(message: "Enter your LiveChar server address.") }
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake, !alertUp else { return }
        let a = UIAlertController(title: "LiveChar", message: serverURL?.absoluteString, preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "Reload", style: .default) { _ in self.alertUp = false; self.reload() })
        a.addAction(UIAlertAction(title: "Change server…", style: .default) { _ in self.alertUp = false; self.askForServer() })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in self.alertUp = false })
        a.popoverPresentationController?.sourceView = view
        a.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        a.popoverPresentationController?.permittedArrowDirections = []
        alertUp = true
        present(a, animated: true)
    }

    private func reload() {
        if webView.url == nil, let url = serverURL { webView.load(URLRequest(url: url)) } else { webView.reload() }
    }

    private func askForServer(message: String = "Leave empty to use the built-in address.") {
        guard !alertUp else { return }
        let a = UIAlertController(title: "LiveChar server", message: message, preferredStyle: .alert)
        a.addTextField { f in
            f.text = Server.saved
            f.placeholder = Server.builtIn?.absoluteString ?? "https://your-server"
            f.keyboardType = .URL
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
            f.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            self.alertUp = false
            let raw = a.textFields?.first?.text ?? ""
            guard let url = Server.save(raw) else {
                self.askForServer(message: "That is not a valid https:// address. Try again.")
                return
            }
            self.serverURL = url
            self.webView.load(URLRequest(url: url))
        })
        if serverURL != nil { a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in self.alertUp = false }) }
        alertUp = true
        present(a, animated: true)
    }

    private func isServer(_ url: URL?) -> Bool {
        guard let url = url, let s = serverURL else { return false }
        return url.scheme == s.scheme && url.host == s.host && (url.port ?? defaultPort(url)) == (s.port ?? defaultPort(s))
    }
    private func defaultPort(_ u: URL) -> Int { u.scheme == "http" ? 80 : 443 }

    private func openOutside(_ url: URL) {
        guard ["http", "https"].contains(url.scheme ?? "") else { UIApplication.shared.open(url); return }
        present(SFSafariViewController(url: url), animated: true)
    }

    private func showLoadError(_ error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled || (ns.domain == "WebKitErrorDomain" && ns.code == 102) { return }
        guard !alertUp else { return }
        let a = UIAlertController(title: "Could not reach the LiveChar server",
                                  message: "\(serverURL?.absoluteString ?? "")\n\(ns.localizedDescription)", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Retry", style: .default) { _ in self.alertUp = false; self.reload() })
        a.addAction(UIAlertAction(title: "Change server", style: .default) { _ in self.alertUp = false; self.askForServer() })
        alertUp = true
        present(a, animated: true)
    }

    // MARK: saving photos and recordings

    private func handleDownloaded(_ file: URL) {
        let ext = file.pathExtension.lowercased()
        let isImage = ["png", "jpg", "jpeg", "heic", "gif"].contains(ext)
        let isVideo = ["mp4", "mov", "m4v"].contains(ext)
        guard isImage || isVideo else { share(file); return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.share(file) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                if isImage { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file) }
                else { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file) }
            }) { ok, _ in
                DispatchQueue.main.async {
                    if ok { self.toast(isImage ? "Saved to Photos" : "Video saved to Photos"); try? FileManager.default.removeItem(at: file) }
                    else { self.share(file) }
                }
            }
        }
    }

    private func share(_ file: URL) {
        let vc = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = view
        vc.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 0, height: 0)
        present(vc, animated: true)
    }

    private func toast(_ text: String) {
        let l = PaddedLabel()
        l.text = text
        l.textColor = .white
        l.font = .systemFont(ofSize: 15, weight: .semibold)
        l.backgroundColor = UIColor(white: 0.1, alpha: 0.92)
        l.layer.cornerRadius = 18
        l.layer.masksToBounds = true
        l.alpha = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        UIView.animate(withDuration: 0.2, animations: { l.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.3, delay: 1.6, options: [], animations: { l.alpha = 0 }) { _ in l.removeFromSuperview() }
        }
    }
}

private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 18, dy: 10)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 36, height: s.height + 20)
    }
}

// MARK: - navigation

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { decisionHandler(.download); return }
        guard let url = action.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme ?? ""
        if ["blob", "data", "about"].contains(scheme) { decisionHandler(.allow); return }
        // stay on the LiveChar server; anything else in the main frame opens outside the app
        if action.targetFrame?.isMainFrame != false, !isServer(url) {
            decisionHandler(.cancel)
            openOutside(url)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }
}

// MARK: - camera permission + popups

extension WebViewController: WKUIDelegate {
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        var c = URLComponents()
        c.scheme = origin.protocol; c.host = origin.host
        if origin.port != 0 { c.port = origin.port }
        decisionHandler(isServer(c.url) ? .grant : .deny)
    }

    // target=_blank links
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isServer(url) { webView.load(action.request) } else { openOutside(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        if presentedViewController == nil { present(a, animated: true) } else { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        if presentedViewController == nil { present(a, animated: true) } else { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        if presentedViewController == nil { present(a, animated: true) } else { completionHandler(nil) }
    }
}

// MARK: - downloads (photo / recording buttons)

extension WebViewController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let name = suggestedFilename.isEmpty ? "livechar-\(Int(Date().timeIntervalSince1970))" : suggestedFilename
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        downloads[ObjectIdentifier(download)] = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        handleDownloaded(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        toast("Save failed: \(error.localizedDescription)")
    }
}
