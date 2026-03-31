import Foundation

// MARK: - JSON-RPC 2.0

struct JSONRPCRequest: Encodable {
  let jsonrpc = "2.0"
  let id: Int
  let method: String
  let params: [String: AnyCodable]?

  enum CodingKeys: String, CodingKey {
    case jsonrpc, id, method, params
  }
}

struct JSONRPCResponse: Decodable {
  let jsonrpc: String
  let id: Int?
  let result: AnyCodable?
  let error: JSONRPCError?
}

struct JSONRPCError: Decodable {
  let code: Int
  let message: String
  let data: AnyCodable?
}

// MARK: - AnyCodable (type-erased Codable wrapper)

struct AnyCodable: Codable {
  let value: Any

  init(_ value: Any) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      value = NSNull()
    } else if let bool = try? container.decode(Bool.self) {
      value = bool
    } else if let int = try? container.decode(Int.self) {
      value = int
    } else if let double = try? container.decode(Double.self) {
      value = double
    } else if let string = try? container.decode(String.self) {
      value = string
    } else if let array = try? container.decode([AnyCodable].self) {
      value = array.map { $0.value }
    } else if let dict = try? container.decode([String: AnyCodable].self) {
      value = dict.mapValues { $0.value }
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch value {
    case is NSNull:
      try container.encodeNil()
    case let bool as Bool:
      try container.encode(bool)
    case let int as Int:
      try container.encode(int)
    case let double as Double:
      try container.encode(double)
    case let string as String:
      try container.encode(string)
    case let array as [Any]:
      try container.encode(array.map { AnyCodable($0) })
    case let dict as [String: Any]:
      try container.encode(dict.mapValues { AnyCodable($0) })
    default:
      throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
    }
  }
}

// MARK: - MCP Tool Definition (from tools/list response)

struct MCPTool {
  let name: String
  let description: String?
  let inputSchema: [String: Any]?

  init?(dict: [String: Any]) {
    guard let name = dict["name"] as? String else { return nil }
    self.name = name
    self.description = dict["description"] as? String
    self.inputSchema = dict["inputSchema"] as? [String: Any]
  }

  /// Convert to Gemini functionDeclaration format
  func toGeminiFunctionDeclaration() -> [String: Any] {
    var decl: [String: Any] = ["name": name]
    if let desc = description {
      decl["description"] = desc
    }
    if let schema = inputSchema {
      decl["parameters"] = schema
    }
    decl["behavior"] = "BLOCKING"
    return decl
  }
}

// MARK: - MCP Initialize Result

struct MCPInitializeResult {
  let protocolVersion: String
  let serverName: String
  let serverVersion: String
  let capabilities: [String: Any]

  init?(dict: [String: Any]) {
    guard let version = dict["protocolVersion"] as? String else { return nil }
    self.protocolVersion = version
    let info = dict["serverInfo"] as? [String: Any] ?? [:]
    self.serverName = info["name"] as? String ?? "unknown"
    self.serverVersion = info["version"] as? String ?? "0.0.0"
    self.capabilities = dict["capabilities"] as? [String: Any] ?? [:]
  }
}

// MARK: - MCP Tool Call Result

struct MCPToolResult {
  let content: [MCPContentBlock]
  let isError: Bool

  init?(dict: [String: Any]) {
    self.isError = dict["isError"] as? Bool ?? false
    guard let contentArray = dict["content"] as? [[String: Any]] else {
      self.content = []
      return
    }
    self.content = contentArray.compactMap { MCPContentBlock(dict: $0) }
  }

  var textContent: String {
    content
      .filter { $0.type == "text" }
      .map { $0.text ?? "" }
      .joined(separator: "\n")
  }
}

struct MCPContentBlock {
  let type: String
  let text: String?

  init?(dict: [String: Any]) {
    guard let type = dict["type"] as? String else { return nil }
    self.type = type
    self.text = dict["text"] as? String
  }
}

// MARK: - Gemini Tool Call (parsed from server JSON)

struct GeminiFunctionCall {
  let id: String
  let name: String
  let args: [String: Any]
}

struct GeminiToolCall {
  let functionCalls: [GeminiFunctionCall]

  init?(json: [String: Any]) {
    guard let toolCall = json["toolCall"] as? [String: Any],
          let calls = toolCall["functionCalls"] as? [[String: Any]] else {
      return nil
    }
    self.functionCalls = calls.compactMap { call in
      guard let id = call["id"] as? String,
            let name = call["name"] as? String else { return nil }
      let args = call["args"] as? [String: Any] ?? [:]
      return GeminiFunctionCall(id: id, name: name, args: args)
    }
  }
}

// MARK: - Gemini Tool Call Cancellation

struct GeminiToolCallCancellation {
  let ids: [String]

  init?(json: [String: Any]) {
    guard let cancellation = json["toolCallCancellation"] as? [String: Any],
          let ids = cancellation["ids"] as? [String] else {
      return nil
    }
    self.ids = ids
  }
}

// MARK: - Tool Result (for bridging MCP → Gemini)

enum ToolResult {
  case success(String)
  case failure(String)

  var responseValue: [String: Any] {
    switch self {
    case .success(let result):
      return ["result": result]
    case .failure(let error):
      return ["error": error]
    }
  }
}

// MARK: - Tool Call Status (for UI)

enum ToolCallStatus: Equatable {
  case idle
  case executing(String)
  case completed(String)
  case failed(String, String)
  case cancelled(String)

  var displayText: String {
    switch self {
    case .idle: return ""
    case .executing(let name): return "Running: \(name)..."
    case .completed(let name): return "Done: \(name)"
    case .failed(let name, let err): return "Failed: \(name) - \(err)"
    case .cancelled(let name): return "Cancelled: \(name)"
    }
  }

  var isActive: Bool {
    if case .executing = self { return true }
    return false
  }
}

// MARK: - MCP Connection State

enum MCPConnectionState: Equatable {
  case notConfigured
  case checking
  case connected(String) // server name
  case unreachable(String)

  static func == (lhs: MCPConnectionState, rhs: MCPConnectionState) -> Bool {
    switch (lhs, rhs) {
    case (.notConfigured, .notConfigured): return true
    case (.checking, .checking): return true
    case (.connected(let a), .connected(let b)): return a == b
    case (.unreachable(let a), .unreachable(let b)): return a == b
    default: return false
    }
  }
}
