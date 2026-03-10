//
//  MedTecAppApp.swift
//  MedTecApp
//
//  Created by Александр Скаредин on 27.02.2026.
//

import SwiftUI

@main
struct MedTecApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
