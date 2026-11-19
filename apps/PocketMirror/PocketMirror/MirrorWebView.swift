import CoreLocation
import SwiftUI
import WebKit

/// Full-screen browser for the mirror, with a small toolbar.
struct MirrorBrowser: View {
    let url: URL
    let onClose: () -> Void
    @StateObject private var controller = WebController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                Button(action: onClose) { Text("Done").fontWeight(.semibold) }
                Spacer()
                Button(action: { controller.webView.goBack() }) { Image(systemName: "chevron.left") }
                    .disabled(!controller.canGoBack)
                Button(action: { controller.webView.goForward() }) { Image(systemName: "chevron.right") }
                    .disabled(!controller.canGoForward)
                Button(action: { controller.webView.load(URLRequest(url: url)) }) { Image(systemName: "house") }
                Button(action: { controller.webView.reload() }) { Image(systemName: "arrow.clockwise") }
            }
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            Divider()
            WebViewRepresentable(webView: controller.webView)
                .edgesIgnoringSafeArea(.bottom)
        }
        .onAppear { controller.load(url) }
    }
}

private struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class WebController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var canGoBack = false
    @Published var canGoForward = false
    private let location = LocationBridge()
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.userContentController.addUserScript(
            WKUserScript(source: LocationBridge.polyfill, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(location, name: LocationBridge.messageName)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        location.webView = webView
        webView.navigationDelegate = self
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoForward = view.canGoForward }
            },
        ]
    }

    func load(_ url: URL) {
        if webView.url == nil { webView.load(URLRequest(url: url)) }
    }

    /// Links to other hosts (e.g. a web link inside an article) can't work offline; open them
    /// in Safari instead of leaving the mirror.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, let host = url.host,
           host != "127.0.0.1", host != "localhost", url.scheme == "http" || url.scheme == "https" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

/// Supplies the phone's GPS to web pages through `navigator.geolocation`, using Core Location.
/// Web pages served over plain http are not a "secure context" for WebKit's own geolocation,
/// so the standard API is replaced by this bridge (map libraries keep working unchanged).
final class LocationBridge: NSObject, WKScriptMessageHandler, CLLocationManagerDelegate {
    static let messageName = "pocketMirrorLocation"
    weak var webView: WKWebView?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let command = message.body as? String else { return }
        switch command {
        case "start":
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            manager.startUpdatingLocation()
        case "stop":
            manager.stopUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let js = String(format: "window.__pocketMirrorPosition && window.__pocketMirrorPosition(%f,%f,%f,%f,%f,%f,%f,%.0f)",
                        loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy,
                        loc.altitude, loc.verticalAccuracy, loc.course, loc.speed,
                        loc.timestamp.timeIntervalSince1970 * 1000)
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        let js = "window.__pocketMirrorPositionError && window.__pocketMirrorPositionError(\(denied ? 1 : 2))"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            webView?.evaluateJavaScript("window.__pocketMirrorPositionError && window.__pocketMirrorPositionError(1)", completionHandler: nil)
        }
    }

    static let polyfill = """
    (function () {
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageName);
      if (!handler) return;
      var watchers = {}, nextId = 1, last = null;
      function post(cmd) { try { handler.postMessage(cmd); } catch (e) {} }
      function active() { return Object.keys(watchers).length > 0; }
      window.__pocketMirrorPosition = function (lat, lon, acc, alt, altAcc, heading, speed, ts) {
        last = { coords: { latitude: lat, longitude: lon, accuracy: acc,
                           altitude: altAcc >= 0 ? alt : null, altitudeAccuracy: altAcc >= 0 ? altAcc : null,
                           heading: heading >= 0 ? heading : null, speed: speed >= 0 ? speed : null },
                 timestamp: ts };
        Object.keys(watchers).forEach(function (id) {
          var w = watchers[id]; if (!w) return;
          if (w.once) delete watchers[id];
          try { w.success(last); } catch (e) {}
        });
        if (!active()) post('stop');
      };
      window.__pocketMirrorPositionError = function (code) {
        var err = { code: code, message: code === 1 ? 'Location permission denied' : 'Position unavailable',
                    PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 };
        Object.keys(watchers).forEach(function (id) {
          var w = watchers[id]; if (!w) return;
          if (w.once) delete watchers[id];
          if (w.error) try { w.error(err); } catch (e) {}
        });
      };
      var geo = {
        getCurrentPosition: function (success, error) {
          watchers[nextId++] = { success: success, error: error, once: true }; post('start');
        },
        watchPosition: function (success, error) {
          var id = nextId++; watchers[id] = { success: success, error: error, once: false }; post('start');
          if (last) setTimeout(function () { if (watchers[id]) success(last); }, 0);
          return id;
        },
        clearWatch: function (id) { delete watchers[id]; if (!active()) post('stop'); }
      };
      try { Object.defineProperty(navigator, 'geolocation', { value: geo, configurable: true }); } catch (e) {}
    })();
    """
}
