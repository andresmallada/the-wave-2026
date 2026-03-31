import Foundation

@MainActor
class MCPBridge: ObservableObject {
  @Published var lastToolCallStatus: ToolCallStatus = .idle
  @Published var connectionState: MCPConnectionState = .notConfigured

  private let session: URLSession
  private let pingSession: URLSession
  private var requestIdCounter = 0
  private var cachedTools: [MCPTool] = []
  private var sessionId: String?

  var mcpSessionId: String? { sessionId }

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    self.session = URLSession(configuration: config)

    let pingConfig = URLSessionConfiguration.default
    pingConfig.timeoutIntervalForRequest = 10
    self.pingSession = URLSession(configuration: pingConfig)
  }

  // MARK: - Connection

  func checkConnection() async {
    guard GeminiConfig.isMCPConfigured else {
      connectionState = .notConfigured
      return
    }
    connectionState = .checking

    let result = await initialize()
    switch result {
    case .success(let info):
      connectionState = .connected(info.serverName)
      NSLog("[MCP] Connected to %@ v%@", info.serverName, info.serverVersion)
    case .failure(let error):
      connectionState = .unreachable(error.localizedDescription)
      NSLog("[MCP] Unreachable: %@", error.localizedDescription)
    }
  }

  // MARK: - MCP Protocol: initialize

  private func initialize() async -> Result<MCPInitializeResult, Error> {
    let params: [String: Any] = [
      "protocolVersion": "2025-06-18",
      "capabilities": [:] as [String: Any],
      "clientInfo": [
        "name": "VisionClaw-iOS",
        "version": "1.0.0"
      ]
    ]

    let result = await sendRequest(method: "initialize", params: params)
    switch result {
    case .success(let response):
      if let error = response.error {
        return .failure(MCPError.serverError(error.message))
      }
      guard let resultDict = response.result?.value as? [String: Any],
            let initResult = MCPInitializeResult(dict: resultDict) else {
        return .failure(MCPError.invalidResponse)
      }
      // Send initialized notification (no response expected)
      await sendNotification(method: "notifications/initialized")
      return .success(initResult)
    case .failure(let error):
      return .failure(error)
    }
  }

  // MARK: - MCP Protocol: tools/list

  func fetchTools() async -> [MCPTool] {
    let result = await sendRequest(method: "tools/list", params: [:])
    switch result {
    case .success(let response):
      if let error = response.error {
        NSLog("[MCP] tools/list error: %@", error.message)
        return []
      }
      guard let resultDict = response.result?.value as? [String: Any],
            let toolsArray = resultDict["tools"] as? [[String: Any]] else {
        NSLog("[MCP] tools/list: unexpected response format")
        return []
      }
      let tools = toolsArray.compactMap { MCPTool(dict: $0) }
      cachedTools = tools
      NSLog("[MCP] Fetched %d tools: %@", tools.count, tools.map { $0.name }.joined(separator: ", "))
      return tools
    case .failure(let error):
      NSLog("[MCP] tools/list failed: %@", error.localizedDescription)
      return []
    }
  }

  // MARK: - MCP Protocol: tools/call

  func callTool(
    name: String,
    arguments: [String: Any]
  ) async -> ToolResult {
    lastToolCallStatus = .executing(name)

    let params: [String: Any] = [
      "name": name,
      "arguments": arguments
    ]

    let result = await sendRequest(method: "tools/call", params: params)
    switch result {
    case .success(let response):
      if let error = response.error {
        NSLog("[MCP] tools/call error: %@", error.message)
        lastToolCallStatus = .failed(name, error.message)
        return .failure("MCP error: \(error.message)")
      }
      guard let resultDict = response.result?.value as? [String: Any],
            let toolResult = MCPToolResult(dict: resultDict) else {
        NSLog("[MCP] tools/call: unexpected response format")
        lastToolCallStatus = .failed(name, "Invalid response")
        return .failure("Invalid MCP response")
      }

      let text = toolResult.textContent
      if toolResult.isError {
        NSLog("[MCP] Tool %@ returned error: %@", name, String(text.prefix(200)))
        lastToolCallStatus = .failed(name, String(text.prefix(50)))
        return .failure(text)
      }

      NSLog("[MCP] Tool %@ result: %@", name, String(text.prefix(200)))
      lastToolCallStatus = .completed(name)
      return .success(text)

    case .failure(let error):
      NSLog("[MCP] tools/call failed: %@", error.localizedDescription)
      lastToolCallStatus = .failed(name, error.localizedDescription)
      return .failure("MCP error: \(error.localizedDescription)")
    }
  }

  // MARK: - JSON-RPC Transport

  private func sendRequest(method: String, params: [String: Any]) async -> Result<JSONRPCResponse, Error> {
    guard let url = mcpEndpointURL() else {
      return .failure(MCPError.invalidURL)
    }

    requestIdCounter += 1
    let requestId = requestIdCounter

    let body: [String: Any] = [
      "jsonrpc": "2.0",
      "id": requestId,
      "method": method,
      "params": params
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

    if let sid = sessionId {
      request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
    }

    let token = GeminiConfig.mcpAuthToken
    if !token.isEmpty && token != "YOUR_MCP_AUTH_TOKEN" {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, httpResponse) = try await session.data(for: request)

      guard let http = httpResponse as? HTTPURLResponse else {
        return .failure(MCPError.invalidResponse)
      }

      // Capture session ID from initialize response
      if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
        sessionId = sid
      }

      guard (200...299).contains(http.statusCode) else {
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        NSLog("[MCP] HTTP %d: %@", http.statusCode, String(bodyStr.prefix(200)))
        return .failure(MCPError.httpError(http.statusCode))
      }

      // FastMCP may return SSE-wrapped responses; extract JSON from data: lines
      let jsonData = Self.extractJSONFromSSE(data)

      let decoder = JSONDecoder()
      let response = try decoder.decode(JSONRPCResponse.self, from: jsonData)
      return .success(response)
    } catch let error as MCPError {
      return .failure(error)
    } catch {
      return .failure(error)
    }
  }

  private func sendNotification(method: String) async {
    guard let url = mcpEndpointURL() else { return }

    let body: [String: Any] = [
      "jsonrpc": "2.0",
      "method": method
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

    if let sid = sessionId {
      request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
    }

    let token = GeminiConfig.mcpAuthToken
    if !token.isEmpty && token != "YOUR_MCP_AUTH_TOKEN" {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      _ = try await session.data(for: request)
    } catch {
      NSLog("[MCP] Notification %@ failed: %@", method, error.localizedDescription)
    }
  }

  // MARK: - SSE Response Parsing

  /// FastMCP Streamable HTTP may wrap JSON-RPC responses in SSE format:
  ///   event: message\ndata: {"jsonrpc":...}\n\n
  /// This extracts the raw JSON from the `data:` line(s) if present.
  private static func extractJSONFromSSE(_ data: Data) -> Data {
    guard let text = String(data: data, encoding: .utf8) else { return data }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // If it already looks like plain JSON, return as-is
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
      return data
    }
    // Parse SSE: collect all `data:` lines
    var jsonParts: [String] = []
    for line in trimmed.components(separatedBy: "\n") {
      if line.hasPrefix("data:") {
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if !payload.isEmpty {
          jsonParts.append(payload)
        }
      }
    }
    if let joined = jsonParts.last, let result = joined.data(using: .utf8) {
      return result
    }
    return data
  }

  private func mcpEndpointURL() -> URL? {
    let baseURL = GeminiConfig.mcpServerURL
    guard !baseURL.isEmpty, baseURL != "YOUR_MCP_SERVER_URL" else { return nil }
    // Ensure the URL ends with /mcp if it doesn't already
    let endpoint = baseURL.hasSuffix("/mcp") ? baseURL : baseURL + "/mcp"
    return URL(string: endpoint)
  }
}

// MARK: - Errors

enum MCPError: LocalizedError {
  case invalidURL
  case invalidResponse
  case httpError(Int)
  case serverError(String)

  var errorDescription: String? {
    switch self {
    case .invalidURL: return "Invalid MCP server URL"
    case .invalidResponse: return "Invalid response from MCP server"
    case .httpError(let code): return "MCP server returned HTTP \(code)"
    case .serverError(let msg): return msg
    }
  }
}
