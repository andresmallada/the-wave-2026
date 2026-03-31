import Foundation

enum GeminiConfig {
  static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
  static let model = "models/gemini-2.5-flash-native-audio-preview-12-2025"

  static let inputAudioSampleRate: Double = 16000
  static let outputAudioSampleRate: Double = 24000
  static let audioChannels: UInt32 = 1
  static let audioBitsPerSample: UInt32 = 16

  static var videoFrameInterval: TimeInterval { 1.0 / SettingsManager.shared.videoFrameRate }
  static let videoJPEGQuality: CGFloat = 0.5

  static var systemInstruction: String { SettingsManager.shared.geminiSystemPrompt }

  static let defaultSystemInstruction = """
    You are an AI assistant for someone wearing Meta Ray-Ban smart glasses. You can see through their camera and have a voice conversation. Keep responses concise and natural.

    CRITICAL: You have NO memory, NO storage, and NO ability to take actions on your own. You cannot remember things, keep lists, set reminders, search the web, send messages, or do anything persistent. You are ONLY a voice interface.

    You have access to a set of tools that connect you to external services and capabilities. Each tool has a specific purpose described in its declaration. Use the appropriate tool when the user asks you to take any action, such as:
    - Send a message to someone
    - Search or look up anything
    - Add, create, or modify anything (lists, reminders, notes, etc.)
    - Research, analyze, or draft anything
    - Control or interact with apps, devices, or services
    - Remember or store any information for later

    Choose the most appropriate tool based on the user's request. Pass all relevant context in the tool arguments: names, content, platforms, quantities, etc.

    NEVER pretend to do these things yourself.

    IMPORTANT: Before calling any tool, ALWAYS speak a brief acknowledgment first. For example:
    - "Sure, let me add that to your shopping list." then call the tool.
    - "Got it, searching for that now." then call the tool.
    - "On it, sending that message." then call the tool.
    Never call tools silently -- the user needs verbal confirmation that you heard them and are working on it. The tool may take several seconds to complete, so the acknowledgment lets them know something is happening.

    For messages, confirm recipient and content before delegating unless clearly urgent.
    """

  // User-configurable values (Settings screen overrides, falling back to Secrets.swift)
  static var apiKey: String { SettingsManager.shared.geminiAPIKey }
  static var mcpServerURL: String { SettingsManager.shared.mcpServerURL }
  static var mcpAuthToken: String { SettingsManager.shared.mcpAuthToken }

  static func websocketURL() -> URL? {
    guard apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty else { return nil }
    return URL(string: "\(websocketBaseURL)?key=\(apiKey)")
  }

  static var isConfigured: Bool {
    return apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty
  }

  static var isMCPConfigured: Bool {
    return mcpServerURL != "YOUR_MCP_SERVER_URL"
      && !mcpServerURL.isEmpty
  }
}
