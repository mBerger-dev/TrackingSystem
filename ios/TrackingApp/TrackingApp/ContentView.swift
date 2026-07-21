//
//  ContentView.swift
//  TrackingApp
//
//  Created by Marius Berger on 21/07/2026.
//

import SwiftUI
import SensorCore

struct ContentView: View {
    var body: some View {
        Text("SensorCore linked: \(SensorPacket.byteCount) byte packets")
            .padding()
    }
}

#Preview {
    ContentView()
}
