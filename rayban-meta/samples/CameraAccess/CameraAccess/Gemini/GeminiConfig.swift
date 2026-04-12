import Foundation

enum GeminiConfig {
  static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
  static let defaultModel = "models/gemini-2.5-flash-native-audio-preview-12-2025"
  static var model: String { SettingsManager.shared.geminiModel }
  static var voice: String { SettingsManager.shared.geminiVoice }
  static var thinkingBudget: Int { SettingsManager.shared.thinkingBudget }
  static var thinkingLevel: String { SettingsManager.shared.thinkingLevel }
  static var isModel31: Bool { SettingsManager.shared.isModel31 }
  static var responseLanguage: String { SettingsManager.shared.responseLanguage }

  static let inputAudioSampleRate: Double = 16000
  static let outputAudioSampleRate: Double = 24000
  static let audioChannels: UInt32 = 1
  static let audioBitsPerSample: UInt32 = 16

  static var videoFrameInterval: TimeInterval { 1.0 / SettingsManager.shared.videoFrameRate }
  static var videoJPEGQuality: CGFloat { CGFloat(SettingsManager.shared.videoJPEGQuality) }

  static var systemInstruction: String { SettingsManager.shared.geminiSystemPrompt }

  static let defaultSystemInstruction = """
    You are an AI assistant for someone wearing Meta Ray-Ban smart glasses. You can see through their camera and have a voice conversation. Keep responses concise and natural.

    CRITICAL: You have NO memory, NO storage, and NO ability to take actions on your own. You cannot remember things, keep lists, set reminders, send messages, or do anything persistent. You are ONLY a voice interface.

    GOOGLE SEARCH: You have built-in Google Search capability. Use it automatically whenever you need current information, facts, news, or details about people, companies, places, or events. You don't need to announce that you're searching -- just answer with up-to-date information.

    You have tools to interact with external services (CRM, messaging, etc.) and a special scan_document tool.

    ALWAYS use the available tools when the user asks you to:
    - Send a message to someone (any platform: WhatsApp, Telegram, iMessage, Slack, etc.)
    - Search or look up anything (web, local info, facts, news)
    - Add, create, or modify anything (shopping lists, reminders, notes, todos, events, contacts)
    - Research, analyze, or draft anything
    - Control or interact with apps, devices, or services
    - Remember or store any information for later

    DOCUMENT SCANNING (scan_document tool):
    - Use scan_document whenever the user asks you to read, scan, or extract info from a document (business card, invoice, receipt, ID, etc.)
    - Also use it when you cannot read text clearly from the video stream
    - This tool captures a HIGH-RESOLUTION photo and uses advanced OCR -- much better than the live video
    - IMPORTANT: After scanning, ALWAYS read the extracted data back to the user for confirmation BEFORE saving to any system (CRM, contacts, etc.)
    - Example flow: User says "scan this business card and add it to CRM" → You say "Let me scan that" → call scan_document → read back "I found: Juan García, CEO at TechCorp, email juan@techcorp.com. Shall I save this to the CRM?" → user confirms → call crm_create_contact

    Be detailed in your task descriptions. Include all relevant context: names, content, platforms, quantities, etc.

    NEVER pretend to do things yourself that require tools.

    IMPORTANT: Before calling any tool, ALWAYS speak a brief acknowledgment first. For example:
    - "Sure, let me scan that for you." then call scan_document.
    - "Got it, searching for that now." then call the appropriate tool.
    - "On it, saving that contact." then call crm_create_contact.
    Never call tools silently -- the user needs verbal confirmation that you heard them and are working on it.

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
