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
    
    var body: some View {
        Group {
            if let url = activeURL {
                WebView(url: url)
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
    @ObservedObject var permissions = AppPermissions.shared
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> ZoomableWebView {
        
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        
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
