//
//  ContentView.swift
//  MedTecApp
//

import SwiftUI
import WebKit
import AppKit
import AVFoundation
import CoreLocation
import Combine
import Cocoa
// MARK: - Unsafe TLS Delegate

class UnsafeSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Global App Permissions Manager (Production Style)

class AppPermissions: NSObject, ObservableObject, CLLocationManagerDelegate {
    
    static let shared = AppPermissions()
    
    private let locationManager = CLLocationManager()
    
    @Published var cameraGranted = false
    @Published var micGranted = false
    @Published var locationGranted = false
    
    @Published var latitude: Double = 0
    @Published var longitude: Double = 0
    
    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    func requestAllPermissions() {
        
        // Камера
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.cameraGranted = granted
            }
        }
        
        // Микрофон
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.micGranted = granted
            }
        }
        
        // Геолокация
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }
    
    // MARK: - CLLocation Delegate
    
    func locationManager(_ manager: CLLocationManager,
                         didChangeAuthorization status: CLAuthorizationStatus) {
        
        DispatchQueue.main.async {
            self.locationGranted = (status == .authorized)
        }
    }
    
    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        
        guard let loc = locations.last else { return }
        
        DispatchQueue.main.async {
            self.latitude = loc.coordinate.latitude
            self.longitude = loc.coordinate.longitude
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    
    @StateObject private var permissions = AppPermissions.shared
    
    @State private var statusText = "Проверка подключения..."
    @State private var activeURL: URL? = nil
    @State private var webViewID = UUID()
    @State private var connectionLost = false
    @State private var showHelp = false
    @State private var pageReady = false
    var body: some View {
        Group {
            if let url = activeURL {

                ZStack {

                    WebView(url: url,
                            onConnectionLost: {
                                    connectionLost = true
                                    pageReady = false
                                },
                                onConnectionRestored: {
                                    connectionLost = false
                                },
                                onPageReady: {
                                    pageReady = true
                                }
                    ) {
                        webViewID = UUID()
                    }
                    .id(webViewID)
                    .opacity(pageReady ? 1 : 0)

                    if connectionLost {

                        VStack(spacing: 16) {

                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 40))

                            Text("Соединение разорвано")
                                .font(.headline)

                            Text("Пытаемся восстановить поток...")
                                .foregroundColor(.secondary)

                            HStack {

                                ProgressView()

                                Button("Подробно") {
                                    showHelp = true
                                }

                            }

                        }
                        .padding(30)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)

                    }

                }
                .sheet(isPresented: $showHelp) {
                    ConnectionHelpView()
                }

            } else {
                VStack(spacing: 20) {
                    Image(systemName: "network")
                    Text(statusText)
                }
                .padding()
                .onAppear {
                    permissions.requestAllPermissions()
                    startConnectionLoop()
                }
            }
        }
    }
    
    let servers = [
        "https://vpn.myapp.local:5236",
        "https://10.8.0.1:5236"
    ]
    
    func startConnectionLoop() {
        tryConnect()
    }
    
    func tryConnect() {
        
        statusText = "🔄 Проверка подключения..."
        
        checkNext(urls: servers) { successURL in
            if let url = successURL {
                DispatchQueue.main.async {
                    activeURL = url
                }
            } else {
                DispatchQueue.main.async {
                    statusText = "⏳ Повтор через 3 секунды..."
                }
                
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    tryConnect()
                }
            }
        }
    }
    
    func checkNext(urls: [String], completion: @escaping (URL?) -> Void) {
        
        guard let first = urls.first,
              let url = URL(string: first) else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        
        let session = URLSession(configuration: .default,
                                 delegate: UnsafeSessionDelegate(),
                                 delegateQueue: nil)
        
        session.dataTask(with: request) { _, response, _ in
            
            if let httpResponse = response as? HTTPURLResponse,
               (200...399).contains(httpResponse.statusCode) {
                completion(url)
            } else {
                checkNext(urls: Array(urls.dropFirst()), completion: completion)
            }
            
        }.resume()
    }
}

// MARK: - WebView

struct WebView: NSViewRepresentable {

    let url: URL
    var onConnectionLost: (() -> Void)?
    var onConnectionRestored: (() -> Void)?
    var onPageReady: (() -> Void)?
    var parentReload: (() -> Void)?
    @ObservedObject var permissions = AppPermissions.shared
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> ZoomableWebView {
        
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .default()
        config.limitsNavigationsToAppBoundDomains = false
        
        let webView = ZoomableWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        
        webView.load(URLRequest(url: url))
        
        return webView
    }
    
    func updateNSView(_ nsView: ZoomableWebView, context: Context) {}
    
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        
        var parent: WebView
        
        init(_ parent: WebView) {
            self.parent = parent
        }
        
        // TLS bypass
        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
        
        // Когда страница загрузилась — передаём координаты в JS
        func webView(_ webView: WKWebView,
                     didFinish navigation: WKNavigation!) {

            DispatchQueue.main.async {
                self.parent.onConnectionRestored?()
                self.parent.onPageReady?()
            }

            let lat = parent.permissions.latitude
            let lon = parent.permissions.longitude

            let script = """
            window.appDevice = {
                latitude: \(lat),
                longitude: \(lon),
                cameraGranted: \(parent.permissions.cameraGranted),
                micGranted: \(parent.permissions.micGranted)
            };
            """

            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {

            reloadLater(webView)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {

            reloadLater(webView)
        }

        func reloadLater(_ webView: WKWebView) {

            DispatchQueue.main.async {

                self.parent.onConnectionLost?()

            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {

                self.parent.parentReload?()

            }

        }

        
    }
}
class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {

        DispatchQueue.main.async {
            self.window = NSApp.windows.first
            self.window?.delegate = self
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "network", accessibilityDescription: "MedTec")
            button.action = #selector(toggleWindow)
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Открыть", action: #selector(showWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleWindow() {
        if let window = window {
            if window.isVisible {
                window.orderOut(nil)
            } else {
                showWindow()
            }
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSWindowDelegate {

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

}
// MARK: - Zoomable WebView

class ZoomableWebView: WKWebView {
    
    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 24: pageZoom += 0.1
            case 27: pageZoom -= 0.1
            case 29: pageZoom = 1.0
            default: super.keyDown(with: event)
            }
            return
        }
        super.keyDown(with: event)
    }
}

struct ConnectionHelpView: View {

    @Environment(\.dismiss) var dismiss

    var body: some View {

        VStack(alignment: .leading, spacing: 20) {

            HStack {

                Text("Что делать при разрыве соединения")
                    .font(.title2)
                    .bold()

                Spacer()

                Button("Закрыть") {
                    dismiss()
                }

            }

            VStack(alignment: .leading, spacing: 10) {

                Label("Проверьте подключение к интернету", systemImage: "wifi")

                Label("Проверьте сетевой кабель", systemImage: "cable.connector")

                Label("Убедитесь что VPN подключен", systemImage: "lock.shield")

                Label("Попробуйте перезапустить приложение", systemImage: "arrow.clockwise")

                Label("Если проблема повторяется — обратитесь к администратору", systemImage: "person.crop.circle.badge.exclamationmark")

            }

            Spacer()

        }
        .padding(30)
        .frame(width: 420, height: 260)

    }

}
