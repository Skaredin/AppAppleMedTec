//
//  ContentView.swift
//  MedTecApp
//

import SwiftUI
import WebKit
import AppKit
import AVFoundation
import CoreLocation

// MARK: - Unsafe TLS Delegate

class UnsafeSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        if let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    
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
                    AVCaptureDevice.requestAccess(for: .video) { granted in
                        print("Camera granted:", granted)
                    }
                    
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        print("Mic granted:", granted)
                    }
                    
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
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: Context) -> ZoomableWebView {
        
        let config = WKWebViewConfiguration()
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        let webView = ZoomableWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        
        webView.load(URLRequest(url: url))
        
        return webView
    }
    
    func updateNSView(_ nsView: ZoomableWebView, context: Context) {}
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        
        // TLS + Basic Auth
        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
                
                let credential = URLCredential(
                    user: "login",
                    password: "password",
                    persistence: .forSession
                )
                
                completionHandler(.useCredential, credential)
                return
            }
            
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
        
        // File upload
        func webView(_ webView: WKWebView,
                     runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping ([URL]?) -> Void) {
            
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            
            panel.begin { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }
        
        // Camera / Microphone permission
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            
            switch type {
                
            case .camera:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        decisionHandler(granted ? .grant : .deny)
                    }
                }
                
            case .microphone:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        decisionHandler(granted ? .grant : .deny)
                    }
                }
                
            case .cameraAndMicrophone:
                AVCaptureDevice.requestAccess(for: .video) { videoGranted in
                    AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                        DispatchQueue.main.async {
                            decisionHandler((videoGranted && audioGranted) ? .grant : .deny)
                        }
                    }
                }
                
            default:
                decisionHandler(.deny)
            }
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
