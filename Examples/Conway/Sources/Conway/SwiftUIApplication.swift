// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Cocoa
import SwiftUI

/// Simple application wrapper to create a command line UI application.
class SwiftUIApplication<V: View, O: ObservableObject>: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!

    let contentView: V
    let observable: O

    init(_ contentView: V, observable: O) {
        self.contentView = contentView
        self.observable = observable
    }

    func run() {
        let app = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        app.mainMenu = NSMenu(title: "Main Menu")
        app.delegate = self
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false)
        window.center()
        window.setFrameAutosaveName("Main Window")
        window.contentView = NSHostingView(rootView: contentView.environmentObject(observable))
        window.makeKeyAndOrderFront(nil)
        window.delegate = self

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
