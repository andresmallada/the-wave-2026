import Foundation
import UIKit

/// Calls Gemini REST API (non-live) for high-quality image analysis / OCR.
/// Used by the `scan_document` local tool to extract text from photos captured
/// by the glasses at full resolution — much better than the compressed video stream.
enum GeminiVisionService {

  private static let model = "gemini-2.5-flash"
  private static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

  /// Analyze an image with a given prompt. Returns the model's text response.
  static func analyzeImage(image: UIImage, prompt: String) async throws -> String {
    let apiKey = GeminiConfig.apiKey
    guard !apiKey.isEmpty, apiKey != "YOUR_GEMINI_API_KEY" else {
      throw VisionError.noAPIKey
    }

    // JPEG encode at high quality for best OCR accuracy
    guard let jpegData = image.jpegData(compressionQuality: 0.95) else {
      throw VisionError.encodingFailed
    }

    let base64 = jpegData.base64EncodedString()
    let sizeKB = jpegData.count / 1024
    AppLog("Vision", "Sending \(Int(image.size.width))x\(Int(image.size.height)) image (\(sizeKB)KB) to \(model)")

    let requestBody: [String: Any] = [
      "contents": [
        [
          "parts": [
            ["text": prompt],
            [
              "inlineData": [
                "mimeType": "image/jpeg",
                "data": base64
              ]
            ]
          ]
        ]
      ],
      "generationConfig": [
        "temperature": 0.1,
        "maxOutputTokens": 4096
      ]
    ]

    guard let url = URL(string: "\(baseURL)/\(model):generateContent?key=\(apiKey)") else {
      throw VisionError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

    let start = Date()
    let (data, response) = try await URLSession.shared.data(for: request)
    let elapsed = Int(Date().timeIntervalSince(start) * 1000)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw VisionError.invalidResponse
    }

    guard httpResponse.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? "no body"
      AppLog("Vision", "HTTP \(httpResponse.statusCode): \(body.prefix(300))")
      throw VisionError.httpError(httpResponse.statusCode, body)
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let candidates = json["candidates"] as? [[String: Any]],
          let content = candidates.first?["content"] as? [String: Any],
          let parts = content["parts"] as? [[String: Any]],
          let text = parts.first?["text"] as? String else {
      throw VisionError.parsingFailed
    }

    AppLog("Vision", "Response in \(elapsed)ms (\(text.count) chars)")
    return text
  }

  // MARK: - OCR Prompt

  /// Standard prompt for extracting structured data from any document
  static let documentOCRPrompt = """
    You are a precise OCR and data extraction system. Analyze this image carefully and extract ALL visible text and information.

    Return a JSON object with these fields (include only fields that are visible/readable):

    {
      "document_type": "business_card" | "invoice" | "receipt" | "id_card" | "other",
      "raw_text": "all visible text exactly as written",
      "structured_data": {
        // For business cards:
        "full_name": "",
        "first_name": "",
        "last_name": "",
        "job_title": "",
        "company": "",
        "email": "",
        "phone": "",
        "mobile": "",
        "website": "",
        "address": "",
        // For other documents, include relevant fields
      },
      "confidence": "high" | "medium" | "low",
      "notes": "any observations about readability or ambiguous text"
    }

    IMPORTANT:
    - Extract EVERY piece of text you can read, even partially visible text
    - For phone numbers, preserve the exact format including country codes
    - For emails, be very precise about characters (dots, hyphens, underscores)
    - If a field is not present, omit it from the JSON (don't include empty strings)
    - Return ONLY the JSON, no markdown formatting, no code fences
    """

  // MARK: - Errors

  enum VisionError: LocalizedError {
    case noAPIKey
    case encodingFailed
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case parsingFailed

    var errorDescription: String? {
      switch self {
      case .noAPIKey: return "Gemini API key not configured"
      case .encodingFailed: return "Failed to encode image as JPEG"
      case .invalidURL: return "Invalid API URL"
      case .invalidResponse: return "Invalid HTTP response"
      case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
      case .parsingFailed: return "Failed to parse API response"
      }
    }
  }
}
