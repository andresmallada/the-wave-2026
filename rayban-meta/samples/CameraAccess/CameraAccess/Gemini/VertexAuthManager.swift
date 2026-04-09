import Foundation
import Security

/// Handles Google Cloud service account authentication for Vertex AI.
/// Parses the service account JSON, signs a JWT with RS256, and exchanges it
/// for a short-lived OAuth2 access token.
actor VertexAuthManager {
  static let shared = VertexAuthManager()

  private var cachedToken: String?
  private var tokenExpiry: Date?

  /// Returns a valid access token, refreshing if needed.
  func accessToken(serviceAccountJSON: String) async throws -> String {
    if let token = cachedToken, let expiry = tokenExpiry, Date() < expiry {
      return token
    }
    let token = try await fetchNewToken(serviceAccountJSON: serviceAccountJSON)
    return token
  }

  func clearCache() {
    cachedToken = nil
    tokenExpiry = nil
  }

  // MARK: - Private

  private func fetchNewToken(serviceAccountJSON: String) async throws -> String {
    guard let data = serviceAccountJSON.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let clientEmail = json["client_email"] as? String,
          let privateKeyPEM = json["private_key"] as? String,
          let tokenURI = json["token_uri"] as? String else {
      throw VertexAuthError.invalidServiceAccount
    }

    let now = Date()
    let expiry = now.addingTimeInterval(3600)

    // Build JWT
    let header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
    let claims: [String: Any] = [
      "iss": clientEmail,
      "scope": "https://www.googleapis.com/auth/cloud-platform",
      "aud": tokenURI,
      "iat": Int(now.timeIntervalSince1970),
      "exp": Int(expiry.timeIntervalSince1970)
    ]

    let headerB64 = try jsonBase64URL(header)
    let claimsB64 = try jsonBase64URL(claims)
    let signingInput = "\(headerB64).\(claimsB64)"

    guard let signingData = signingInput.data(using: .utf8) else {
      throw VertexAuthError.jwtCreationFailed
    }

    let privateKey = try parsePrivateKey(pem: privateKeyPEM)
    let signature = try sign(data: signingData, with: privateKey)
    let signatureB64 = base64URLEncode(signature)
    let jwt = "\(signingInput).\(signatureB64)"

    // Exchange JWT for access token
    guard let url = URL(string: tokenURI) else {
      throw VertexAuthError.invalidServiceAccount
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)"
    request.httpBody = body.data(using: .utf8)

    let (responseData, httpResponse) = try await URLSession.shared.data(for: request)
    guard let http = httpResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let bodyStr = String(data: responseData, encoding: .utf8) ?? "no body"
      NSLog("[VertexAuth] Token exchange failed: %@", String(bodyStr.prefix(300)))
      throw VertexAuthError.tokenExchangeFailed
    }

    guard let tokenJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
          let accessToken = tokenJSON["access_token"] as? String else {
      throw VertexAuthError.tokenExchangeFailed
    }

    let expiresIn = tokenJSON["expires_in"] as? Int ?? 3600
    cachedToken = accessToken
    tokenExpiry = now.addingTimeInterval(Double(expiresIn) - 60) // refresh 60s early
    NSLog("[VertexAuth] Token obtained, expires in %ds", expiresIn)
    return accessToken
  }

  // MARK: - Crypto helpers

  private func parsePrivateKey(pem: String) throws -> SecKey {
    let stripped = pem
      .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
      .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
      .replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: "\r", with: "")

    guard let keyData = Data(base64Encoded: stripped) else {
      throw VertexAuthError.invalidPrivateKey
    }

    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
      kSecAttrKeySizeInBits as String: 2048
    ]

    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
      NSLog("[VertexAuth] SecKey creation failed: %@", error?.takeRetainedValue().localizedDescription ?? "unknown")
      throw VertexAuthError.invalidPrivateKey
    }
    return key
  }

  private func sign(data: Data, with key: SecKey) throws -> Data {
    var error: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(
      key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error
    ) else {
      throw VertexAuthError.signingFailed
    }
    return signature as Data
  }

  private func jsonBase64URL(_ dict: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    return base64URLEncode(data)
  }

  private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

enum VertexAuthError: LocalizedError {
  case invalidServiceAccount
  case invalidPrivateKey
  case jwtCreationFailed
  case signingFailed
  case tokenExchangeFailed

  var errorDescription: String? {
    switch self {
    case .invalidServiceAccount: return "Invalid service account JSON"
    case .invalidPrivateKey: return "Cannot parse private key from service account"
    case .jwtCreationFailed: return "Failed to create JWT"
    case .signingFailed: return "Failed to sign JWT"
    case .tokenExchangeFailed: return "Failed to exchange JWT for access token"
    }
  }
}
