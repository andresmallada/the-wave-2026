import Foundation
import SwiftUI

@MainActor
class GeminiSessionViewModel: ObservableObject {
  @Published var isGeminiActive: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var mcpConnectionState: MCPConnectionState = .notConfigured
  private let geminiService = GeminiLiveService()
  private let mcpBridge = MCPBridge()
  private var toolCallRouter: MCPToolCallRouter?
  private let audioManager = AudioManager()
  private let eventClient = MCPEventClient()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?

  var streamingMode: StreamingMode = .glasses

  /// Handler to capture a high-res photo from the glasses (wired by StreamSessionView)
  var photoCaptureHandler: (() async -> UIImage?)?
  /// When true, video frames are NOT sent to Gemini (frees Bluetooth bandwidth for photo transfer)
  var pauseVideoForScan: Bool = false

  // MARK: - Local Tool Definitions

  private static let scanDocumentToolName = "scan_document"

  /// Gemini function declaration for the local scan_document tool
  private static let scanDocumentDeclaration: [String: Any] = [
    "name": scanDocumentToolName,
    "description": "Captures a high-resolution photo from the smart glasses and uses OCR to read and extract all text and data from any document (business cards, invoices, receipts, IDs, etc.). Use this tool whenever the user asks to read, scan, or extract information from a document, or when the video stream quality is too low to read text clearly.",
    "parameters": [
      "type": "object",
      "properties": [
        "document_type": [
          "type": "string",
          "description": "Optional hint about what type of document to expect (e.g. 'business_card', 'invoice', 'receipt', 'id_card'). If not provided, the system will auto-detect."
        ]
      ]
    ]
  ]

  func startSession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open GeminiConfig.swift and replace YOUR_GEMINI_API_KEY with your key from https://aistudio.google.com/apikey"
      return
    }

    isGeminiActive = true

    // Wire audio callbacks
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        guard SettingsManager.shared.sendAudioToGemini else { return }
        // Mute mic while model speaks when output is on the phone
        // (speaker/usb + co-located mic overwhelms iOS echo cancellation)
        let route = SettingsManager.shared.audioOutputRoute
        let outputOnPhone = self.streamingMode == .iPhone || route == "speaker" || route == "usb"
        if outputOnPhone && self.geminiService.isModelSpeaking { return }
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      self?.audioManager.playAudio(data: data)
    }

    geminiService.onInterrupted = { [weak self] in
      self?.audioManager.stopPlayback()
    }

    geminiService.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        // Clear user transcript when AI finishes responding
        self.userTranscript = ""
      }
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript += text
        self.aiTranscript = ""
      }
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
      }
    }

    // Handle unexpected disconnection
    geminiService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive else { return }
        self.stopSession()
        self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
      }
    }

    // Check MCP server connectivity and fetch available tools
    await mcpBridge.checkConnection()
    let mcpTools = await mcpBridge.fetchTools()

    // Set dynamic tool declarations for Gemini (MCP tools + local tools)
    var declarations = mcpTools.map { $0.toGeminiFunctionDeclaration() }
    declarations.append(Self.scanDocumentDeclaration)
    AppLog("Session", "MCP connection: \(mcpBridge.connectionState), tools fetched: \(mcpTools.count), declarations: \(declarations.count) (incl. local)")
    geminiService.toolDeclarations = declarations

    // Wire tool call handling
    toolCallRouter = MCPToolCallRouter(bridge: mcpBridge)

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        let currentSessionId = self.geminiService.sessionId
        for call in toolCall.functionCalls {
          // Local tool: scan_document — handle on-device
          if call.name == Self.scanDocumentToolName {
            await self.handleScanDocument(call: call, sessionId: currentSessionId)
            continue
          }
          // MCP tool: route to server
          self.toolCallRouter?.handleToolCall(call) { [weak self] response in
            guard let self else { return }
            guard self.geminiService.sessionId == currentSessionId else {
              AppLog("ToolCall", "Dropping stale response for session #\(currentSessionId) (now #\(self.geminiService.sessionId))")
              return
            }
            guard self.isGeminiActive else {
              AppLog("ToolCall", "Dropping response — session no longer active")
              return
            }
            self.geminiService.sendToolResponse(response)
          }
        }
      }
    }

    geminiService.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
      }
    }

    // Observe service state
    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        guard !Task.isCancelled else { break }
        self.connectionState = self.geminiService.connectionState
        self.isModelSpeaking = self.geminiService.isModelSpeaking
        self.toolCallStatus = self.mcpBridge.lastToolCallStatus
        self.mcpConnectionState = self.mcpBridge.connectionState
      }
    }

    // Setup audio
    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      isGeminiActive = false
      return
    }

    // Connect to Gemini and wait for setupComplete
    let setupOk = await geminiService.connect()

    if !setupOk {
      let msg: String
      if case .error(let err) = geminiService.connectionState {
        msg = err
      } else {
        msg = "Failed to connect to Gemini"
      }
      errorMessage = msg
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Start mic capture
    do {
      try audioManager.startCapture()
    } catch {
      errorMessage = "Mic capture failed: \(error.localizedDescription)"
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Connect to MCP event stream for proactive notifications
    if SettingsManager.shared.proactiveNotificationsEnabled {
      eventClient.mcpSessionId = mcpBridge.mcpSessionId
      eventClient.onNotification = { [weak self] text in
        guard let self else { return }
        Task { @MainActor in
          guard self.isGeminiActive, self.connectionState == .ready else { return }
          self.geminiService.sendTextMessage(text)
        }
      }
      eventClient.connect()
    }
  }

  func stopSession() {
    AppLog("Session", "stopSession() called — tearing down")
    eventClient.disconnect()
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
    lastVideoFrameTime = .distantPast
    errorMessage = nil
    AppLog("Session", "stopSession() complete — all state reset")
  }

  // MARK: - Local Tool: scan_document

  private func handleScanDocument(call: GeminiFunctionCall, sessionId: Int) async {
    let callId = call.id
    AppLog("Vision", "scan_document invoked (id: \(callId))")
    toolCallStatus = .executing(call.name)

    // Guard: still same session?
    func sendResponse(_ result: [String: Any]) {
      guard geminiService.sessionId == sessionId, isGeminiActive else {
        AppLog("Vision", "Dropping scan_document response — session changed")
        return
      }
      let response: [String: Any] = [
        "toolResponse": [
          "functionResponses": [
            [
              "id": callId,
              "name": Self.scanDocumentToolName,
              "response": result
            ]
          ]
        ]
      ]
      geminiService.sendToolResponse(response)
    }

    // Step 1: Capture high-res photo
    guard let captureHandler = photoCaptureHandler else {
      AppLog("Vision", "No photo capture handler — glasses not streaming?")
      sendResponse(["error": "Camera not available. Make sure glasses are streaming."])
      toolCallStatus = .idle
      return
    }

    AppLog("Vision", "Capturing high-res photo...")
    guard let photo = await captureHandler() else {
      AppLog("Vision", "Photo capture failed or timed out")
      sendResponse(["error": "Failed to capture photo. Please try again."])
      toolCallStatus = .idle
      return
    }

    AppLog("Vision", "Photo captured: \(Int(photo.size.width))x\(Int(photo.size.height))")

    // Step 2: Send to Gemini Vision REST API for OCR
    do {
      let documentType = call.args["document_type"] as? String
      var prompt = GeminiVisionService.documentOCRPrompt
      if let docType = documentType {
        prompt += "\n\nHint: The user expects this to be a \(docType)."
      }

      let ocrResult = try await GeminiVisionService.analyzeImage(image: photo, prompt: prompt)
      AppLog("Vision", "OCR complete: \(ocrResult.prefix(200))...")

      // Try to parse as JSON to validate, but send raw text if it fails
      if let jsonData = ocrResult.data(using: .utf8),
         let jsonObj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
        sendResponse(jsonObj)
      } else {
        sendResponse(["raw_text": ocrResult])
      }
    } catch {
      AppLog("Vision", "OCR failed: \(error.localizedDescription)")
      sendResponse(["error": "Document scan failed: \(error.localizedDescription)"])
    }

    toolCallStatus = .idle
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard !pauseVideoForScan else { return }
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard SettingsManager.shared.sendFramesToGemini else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

}
