import Foundation
import UIKit

enum FloorplanImageAnalysisError: LocalizedError {
    case aiNotReady
    case imageEncodingFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .aiNotReady:
            return String(localized: "drawing.ai.error.notReady", defaultValue: "AI is not configured. Enable AI, add an API key, and grant data consent in Settings.")
        case .imageEncodingFailed:
            return String(localized: "drawing.ai.error.imageEncoding", defaultValue: "Unable to prepare the image for analysis.")
        case .invalidResponse:
            return String(localized: "drawing.ai.error.invalidResponse", defaultValue: "The AI response could not be converted into a floorplan draft.")
        }
    }
}

final class FloorplanImageAnalysisService {
    static let shared = FloorplanImageAnalysisService(settings: .init())

    private let settings: AISettings
    private let session: URLSession

    init(settings: AISettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func analyze(image: UIImage) async throws -> DrawingDocument {
        guard settings.isOperational,
              let apiKey = KeychainHelper.load(key: AIProvider.claude.keychainKey),
              !apiKey.isEmpty
        else { throw FloorplanImageAnalysisError.aiNotReady }

        guard let imageData = Self.preparedJPEGData(from: image) else {
            throw FloorplanImageAnalysisError.imageEncodingFailed
        }

        let responseText = try await sendClaudeVisionRequest(imageData: imageData, apiKey: apiKey)
        let draft = try decodeDraft(from: responseText)
        return FloorplanAIDraftMapper.makeDocument(from: draft)
    }

    private func sendClaudeVisionRequest(imageData: Data, apiKey: String) async throws -> String {
        guard let url = URL(string: AIProvider.claude.apiEndpoint) else { throw AIError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 45.0
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": AIProvider.claude.defaultModel,
            "max_tokens": 4000,
            "system": Self.systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": imageData.base64EncodedString()
                            ]
                        ],
                        [
                            "type": "text",
                            "text": Self.userPrompt
                        ]
                    ]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try checkHTTP(response)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstText = content.compactMap({ $0["text"] as? String }).first
        else { throw AIError.decodingFailed }

        return firstText
    }

    private func decodeDraft(from responseText: String) throws -> FloorplanAIDraft {
        let jsonText = Self.extractJSONObject(from: responseText)
        guard let data = jsonText.data(using: .utf8) else {
            throw FloorplanImageAnalysisError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(FloorplanAIDraft.self, from: data)
        } catch {
            throw FloorplanImageAnalysisError.invalidResponse
        }
    }

    private func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AIError.unexpectedResponse }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw AIError.unauthorized
        case 429:
            throw AIError.rateLimited
        default:
            throw AIError.serverError(code: http.statusCode)
        }
    }

    private static func preparedJPEGData(from image: UIImage) -> Data? {
        let maxSide: CGFloat = 1600
        let longest = max(image.size.width, image.size.height)
        let target: UIImage

        if longest > maxSide {
            let scale = maxSide / longest
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: size)
            target = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        } else {
            target = image
        }

        return target.jpegData(compressionQuality: 0.82)
    }

    private static func extractJSONObject(from text: String) -> String {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end
        else { return text }
        return String(text[start...end])
    }

    private static let systemPrompt = """
    You convert uploaded architectural floorplan images into a conservative wall-only editable JSON draft.
    Return only valid JSON. Do not include Markdown, comments, explanations, or code fences.
    The coordinate system is a square canvas from 0 to 2000 on both axes, origin at top-left.
    Trace only wall segments that are clearly visible in the actual pixels. Do not infer, regularize, complete, simplify, or redesign the layout.
    Prefer returning an empty "walls" array over returning guessed geometry.
    """

    private static let userPrompt = """
    Analyze this floorplan image and return this JSON shape exactly:
    {
      "walls": [
        { "x1": 0, "y1": 0, "x2": 100, "y2": 0, "kind": "exterior", "confidence": 0.95 }
      ],
      "rooms": [],
      "labels": []
    }

    Rules:
    - Use only "exterior", "interior", or "balcony" for wall kind.
    - Use wall centerlines, not both sides of thick walls.
    - Trace the visible perimeter and main internal partitions only when their exact direction and endpoints are clear.
    - Do not invent closed rectangles or regular room grids.
    - Do not straighten or normalize a wall unless the image clearly shows it as straight.
    - Do not connect separated wall fragments unless the connection is visible.
    - Preserve diagonal/angled partitions when visible.
    - Skip furniture, dimensions, room names, room fills, north arrows, title blocks, shadows, and decorative symbols.
    - If this is a 3D render, perspective view, blurry screenshot, or furnished visualization where wall centerlines are uncertain, return fewer segments with lower confidence or an empty walls array.
    - Include "confidence" from 0.0 to 1.0 for every wall. Use confidence >= 0.85 only when the wall is directly visible and endpoints are clear.
    - Always return empty arrays for "rooms" and "labels". The user will add room areas later.
    - Keep all coordinates between 0 and 2000.
    """
}
