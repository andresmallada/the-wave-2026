import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  private let settings = SettingsManager.shared

  @State private var geminiAPIKey: String = ""
  @State private var mcpServerURL: String = ""
  @State private var mcpAuthToken: String = ""
  @State private var geminiSystemPrompt: String = ""
  @State private var webrtcSignalingURL: String = ""
  @State private var speakerOutputEnabled: Bool = false
  @State private var videoStreamingEnabled: Bool = true
  @State private var videoFrameRate: Double = 3.0
  @State private var sendFramesToGemini: Bool = true
  @State private var sendAudioToGemini: Bool = true
  @State private var proactiveNotificationsEnabled: Bool = true
  @State private var showResetConfirmation = false

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Gemini API")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("API Key")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Enter Gemini API key", text: $geminiAPIKey)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("System Prompt"), footer: Text("Customize the AI assistant's behavior and personality. Changes take effect on the next Gemini session.")) {
          TextEditor(text: $geminiSystemPrompt)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 200)
        }

        Section(header: Text("MCP Server"), footer: Text("Connect to your custom MCP server for agentic tool-calling. The server should be accessible via Cloudflare Tunnel or similar.")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Server URL")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("https://your-server.trycloudflare.com", text: $mcpServerURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Auth Token")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Bearer token (optional)", text: $mcpAuthToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("WebRTC")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Signaling URL")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("wss://your-server.example.com", text: $webrtcSignalingURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("Audio"), footer: Text("Speaker Output routes audio to the iPhone speaker. Send Audio to Gemini controls whether mic input is forwarded to the LLM. Disable it to mute yourself without disconnecting.")) {
          Toggle("Speaker Output", isOn: $speakerOutputEnabled)
          Toggle("Send Audio to Gemini", isOn: $sendAudioToGemini)
        }

        Section(header: Text("Video"), footer: Text("Video Streaming captures frames from the camera. Send Frames to Gemini controls whether those frames are forwarded to the LLM. Disable it for audio-only mode.")) {
          Toggle("Video Streaming", isOn: $videoStreamingEnabled)
          Toggle("Send Frames to Gemini", isOn: $sendFramesToGemini)

          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("Frame Rate")
                .font(.caption)
                .foregroundColor(.secondary)
              Spacer()
              Text("\(Int(videoFrameRate)) fps")
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Slider(value: $videoFrameRate, in: 1...10, step: 1)
          }
        }

        Section(header: Text("Notifications"), footer: Text("Receive proactive updates from your MCP server spoken through the glasses.")) {
          Toggle("Proactive Notifications", isOn: $proactiveNotificationsEnabled)
        }

        Section {
          Button("Reset to Defaults") {
            showResetConfirmation = true
          }
          .foregroundColor(.red)
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Save") {
            save()
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
      .alert("Reset Settings", isPresented: $showResetConfirmation) {
        Button("Reset", role: .destructive) {
          settings.resetAll()
          loadCurrentValues()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This will reset all settings to the values built into the app.")
      }
      .onAppear {
        loadCurrentValues()
      }
    }
  }

  private func loadCurrentValues() {
    geminiAPIKey = settings.geminiAPIKey
    geminiSystemPrompt = settings.geminiSystemPrompt
    mcpServerURL = settings.mcpServerURL
    mcpAuthToken = settings.mcpAuthToken
    webrtcSignalingURL = settings.webrtcSignalingURL
    speakerOutputEnabled = settings.speakerOutputEnabled
    videoStreamingEnabled = settings.videoStreamingEnabled
    videoFrameRate = settings.videoFrameRate
    sendFramesToGemini = settings.sendFramesToGemini
    sendAudioToGemini = settings.sendAudioToGemini
    proactiveNotificationsEnabled = settings.proactiveNotificationsEnabled
  }

  private func save() {
    settings.geminiAPIKey = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.geminiSystemPrompt = geminiSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.mcpServerURL = mcpServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.mcpAuthToken = mcpAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.webrtcSignalingURL = webrtcSignalingURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.speakerOutputEnabled = speakerOutputEnabled
    settings.videoStreamingEnabled = videoStreamingEnabled
    settings.videoFrameRate = videoFrameRate
    settings.sendFramesToGemini = sendFramesToGemini
    settings.sendAudioToGemini = sendAudioToGemini
    settings.proactiveNotificationsEnabled = proactiveNotificationsEnabled
  }
}
