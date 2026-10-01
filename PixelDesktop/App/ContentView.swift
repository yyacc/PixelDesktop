import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { appState.refreshDevices() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(appState.isDiscovering)
            }
        }
    }

    private var sidebar: some View {
        List {
            Section("Devices") {
                if appState.devices.isEmpty {
                    Text("No devices found")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.devices) { device in
                        DeviceRow(device: device)
                    }
                }
            }

            Section("Status") {
                HStack {
                    Text("Discovery:")
                    Spacer()
                    Text(appState.isDiscovering ? "Running" : "Stopped")
                        .foregroundStyle(appState.isDiscovering ? .green : .secondary)
                }

                if let error = appState.lastError {
                    HStack {
                        Text("Error:")
                        Spacer()
                        Text(error.description)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle("PixelDesktop")
    }

    private var detailView: some View {
        VStack(spacing: 20) {
            if let device = appState.devices.first {
                DeviceDetailView(device: device)
            } else {
                ContentUnavailableView(
                    "No Device Selected",
                    systemImage: "iphone.slash",
                    description: Text("Connect an Android device via USB to get started.")
                )
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DeviceRow: View {
    let device: PixelDevice

    var body: some View {
        HStack {
            Image(systemName: "iphone")
                .foregroundStyle(device.state.isConnected ? .green : .secondary)

            VStack(alignment: .leading) {
                Text(device.displayName)
                    .font(.headline)
                Text(device.serialNumber)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(device.state.description)
                .font(.caption)
                .foregroundStyle(device.state.isConnected ? .green : .orange)
        }
        .padding(.vertical, 4)
    }
}

struct DeviceDetailView: View {
    let device: PixelDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(device.displayName)
                .font(.largeTitle)

            LabeledContent("Serial", value: device.serialNumber)
            LabeledContent("Model", value: device.model.isEmpty ? "Unknown" : device.model)
            LabeledContent("Manufacturer", value: device.manufacturer.isEmpty ? "Unknown" : device.manufacturer)
            LabeledContent("Android Version", value: device.androidVersion.isEmpty ? "Unknown" : device.androidVersion)
            LabeledContent("API Level", value: device.apiLevel > 0 ? "\(device.apiLevel)" : "Unknown")
            LabeledContent("Architecture", value: device.architecture.isEmpty ? "Unknown" : device.architecture)
            LabeledContent("State", value: device.state.description)

            Spacer()
        }
        .padding()
    }
}
