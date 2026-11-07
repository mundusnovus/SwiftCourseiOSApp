// The Smartz language model for FoundationModels. A session hands the executor its whole transcript
// (instructions, prompts, answers, tool calls and their outputs, reasoning); the executor turns it into a Chat
// Completions request, sends it to Asteria's gateway, and streams the answer back as text, reasoning and tool calls.
// The session runs the tools and parses @Generable answers itself, exactly as it does with Apple's models.
import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import UniformTypeIdentifiers

nonisolated public struct SmartzModel: LanguageModel {
    public typealias Executor = SmartzExecutor

    /// "chat" for a conversation with Smartz: the gateway adds what Smartz knows (the person's memories, shared skills).
    public var context: String?
    /// Think harder: reasoning on for every answer, unless the session asks for a level itself.
    public var thinkHarder: Bool

    public init(context: String? = nil, thinkHarder: Bool = false) {
        self.context = context
        self.thinkHarder = thinkHarder
    }

    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling, .guidedGeneration, .vision, .reasoning]) }

    public var executorConfiguration: SmartzExecutor.Configuration { .init(context: context, thinkHarder: thinkHarder) }

    /// Images are the only attachments it reads.
    public func supportsDataAttachmentType(_ type: UTType) async throws -> Bool { type.conforms(to: .image) }
}

nonisolated public struct SmartzExecutor: LanguageModelExecutor {
    public struct Configuration: Hashable, Sendable {
        public var context: String?
        public var thinkHarder: Bool
        public init(context: String? = nil, thinkHarder: Bool = false) { self.context = context; self.thinkHarder = thinkHarder }
    }
    public typealias Model = SmartzModel

    let configuration: Configuration

    public init(configuration: Configuration) throws { self.configuration = configuration }

    /// Starts the gateway session early, so the first answer doesn't wait for it.
    public func prewarm(model: SmartzModel, transcript: Transcript) {
        guard Smartz.isOn else { return }
        Task { try? await IntelligenceClient.shared.token() }
    }

    nonisolated(nonsending) public func respond(to request: LanguageModelExecutorGenerationRequest, model: SmartzModel,
                                                streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        guard await SmartzPrompt.ensurePermission() else { throw SmartzError.notAllowed }
        let body = try IntelligenceRequest.body(for: request, thinkHarder: configuration.thinkHarder)
        let structured = request.schema != nil
        // A structured answer is buffered and sent whole: it must be one JSON object, and the provider occasionally
        // returns a blank one, which is worth one retry.
        for attempt in 0..<(structured ? 2 : 1) {
            var text = ""
            var reasoningTokens = 0
            var calls: [Int: (id: String, name: String, arguments: String)] = [:]
            var usage: (prompt: Int, cached: Int, completion: Int, reasoning: Int)?
            for try await event in IntelligenceClient.shared.stream(body, context: configuration.context) {
                try Task.checkCancellation()
                switch event {
                case .text(let delta):
                    if structured { text += delta } else {
                        await channel.send(.response(action: .appendText(delta, tokenCount: IntelligenceRequest.tokens(delta))))
                    }
                case .reasoning(let delta):
                    reasoningTokens += IntelligenceRequest.tokens(delta)
                    await channel.send(.reasoning(action: .appendText(delta, tokenCount: IntelligenceRequest.tokens(delta))))
                case .toolCall(let index, let id, let name, let arguments):
                    var call = calls[index] ?? (id: id ?? "call_\(index)", name: name ?? "", arguments: "")
                    if let id, !id.isEmpty { call.id = id }
                    if let name, !name.isEmpty { call.name = name }
                    call.arguments += arguments
                    calls[index] = call
                case .usage(let prompt, let cached, let completion, let reasoning):
                    usage = (prompt, cached, completion, reasoning)
                case .cost(let tokens):
                    await SmartzUsage.shared.noteAnswer(tokens: tokens)
                }
            }
            if structured {
                let json = IntelligenceRequest.extractJSON(text)
                if json.isEmpty && attempt == 0 && calls.isEmpty { continue }
                if !json.isEmpty { await channel.send(.response(action: .appendText(json, tokenCount: IntelligenceRequest.tokens(json)))) }
            }
            for index in calls.keys.sorted() {
                guard let call = calls[index], !call.name.isEmpty else { continue }
                let arguments = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : call.arguments
                await channel.send(.toolCalls(action: .toolCall(id: call.id, name: call.name,
                                                                action: .appendArguments(arguments, tokenCount: IntelligenceRequest.tokens(arguments)))))
            }
            Task { await SmartzUsage.shared.refresh() }
            if let usage {
                await channel.send(.response(action: .updateUsage(
                    input: .init(totalTokenCount: usage.prompt, cachedTokenCount: usage.cached),
                    output: .init(totalTokenCount: usage.completion, reasoningTokenCount: max(usage.reasoning, reasoningTokens)))))
            }
            return
        }
    }
}

// MARK: Transcript → Chat Completions

nonisolated enum IntelligenceRequest {
    static func tokens(_ text: String) -> Int { max(1, text.utf8.count / 4) }

    /// The request body for one turn.
    static func body(for request: LanguageModelExecutorGenerationRequest, thinkHarder: Bool = false) throws -> Data {
        var messages = try messages(from: request.transcript)
        if let schema = request.schema {
            let json = String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)
            let rule = "Answer with one JSON object and nothing else: no Markdown, no code fence, no commentary. It must follow this JSON schema:\n\(json)"
            messages.append(["role": "system", "content": rule])
        }
        var body: [String: Any] = ["messages": messages]
        let options = request.generationOptions
        let toolsAllowed = options.toolCallingMode?.kind != .disallowed
        if !request.enabledToolDefinitions.isEmpty {
            body["tools"] = try request.enabledToolDefinitions.map { definition -> [String: Any] in
                let parameters = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition.parameters))
                return ["type": "function", "function": ["name": definition.name, "description": definition.description, "parameters": parameters]]
            }
            if !toolsAllowed { body["tool_choice"] = "none" } else if options.toolCallingMode?.kind == .required { body["tool_choice"] = "required" }
        }
        if request.schema != nil { body["response_format"] = ["type": "json_object"] }
        if let maximum = options.maximumResponseTokens { body["max_tokens"] = maximum }
        if let temperature = options.temperature { body["temperature"] = temperature }
        switch options.samplingMode?.kind {
        case .greedy?: body["temperature"] = 0
        case .randomProbabilityThreshold(let threshold, _)?: body["top_p"] = threshold
        default: break
        }
        switch request.contextOptions.reasoningLevel {
        case nil where thinkHarder: body["thinking"] = ["type": "enabled"]; body["reasoning_effort"] = "high"
        case nil: body["thinking"] = ["type": "disabled"]
        case .light?: body["thinking"] = ["type": "enabled"]; body["reasoning_effort"] = "low"
        case .moderate?: body["thinking"] = ["type": "enabled"]; body["reasoning_effort"] = "high"
        case .deep?: body["thinking"] = ["type": "enabled"]; body["reasoning_effort"] = "max"
        case .custom(let effort)?:
            body["thinking"] = ["type": "enabled"]
            body["reasoning_effort"] = ["low", "high", "max"].contains(effort) ? effort : "high"
        default:
            body["thinking"] = ["type": "enabled"]; body["reasoning_effort"] = "high"
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func messages(from transcript: Transcript) throws -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var reasoning = ""
        var pendingCalls: [(id: String, name: String)] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                let text = plain(instructions.segments)
                if !text.isEmpty { messages.append(["role": "system", "content": text]) }
            case .prompt(let prompt):
                messages.append(["role": "user", "content": content(prompt.segments)])
            case .reasoning(let entry):
                reasoning += plain(entry.segments)
            case .response(let response):
                var message: [String: Any] = ["role": "assistant", "content": plain(response.segments)]
                if !reasoning.isEmpty { message["reasoning_content"] = reasoning; reasoning = "" }
                messages.append(message)
            case .toolCalls(let calls):
                var message: [String: Any] = ["role": "assistant", "content": ""]
                message["tool_calls"] = calls.map { call -> [String: Any] in
                    ["id": call.id, "type": "function", "function": ["name": call.toolName, "arguments": call.arguments.jsonString]]
                }
                if !reasoning.isEmpty { message["reasoning_content"] = reasoning; reasoning = "" }
                pendingCalls = calls.map { (id: $0.id, name: $0.toolName) }
                messages.append(message)
            case .toolOutput(let output):
                // The output carries its call's id; if not, it answers the next call to that tool.
                let id: String
                if let index = pendingCalls.firstIndex(where: { $0.id == output.id }) {
                    id = pendingCalls.remove(at: index).id
                } else if let index = pendingCalls.firstIndex(where: { $0.name == output.toolName }) {
                    id = pendingCalls.remove(at: index).id
                } else {
                    id = output.id
                }
                messages.append(["role": "tool", "tool_call_id": id, "content": plain(output.segments)])
            default:
                continue
            }
        }
        return messages
    }

    /// Text and structured segments as one string (attachments described by their label).
    static func plain(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            case .attachment(let attachment): attachment.label.map { "[\($0)]" }
            @unknown default: nil
            }
        }.joined(separator: "\n")
    }

    /// A prompt's content: a plain string, or text and images when it has pictures.
    static func content(_ segments: [Transcript.Segment]) -> Any {
        var parts: [[String: Any]] = []
        var hasImage = false
        for segment in segments {
            switch segment {
            case .text(let text): parts.append(["type": "text", "text": text.content])
            case .structure(let structure): parts.append(["type": "text", "text": structure.content.jsonString])
            case .attachment(let attachment):
                if case .image(let image) = attachment.content, let url = jpegDataURL(image.cgImage) {
                    hasImage = true
                    if let label = attachment.label { parts.append(["type": "text", "text": label]) }
                    parts.append(["type": "image_url", "image_url": ["url": url]])
                }
            @unknown default: continue
            }
        }
        return hasImage ? parts : parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// At most 1,568 pixels on the long side, as JPEG.
    static func jpegDataURL(_ image: CGImage) -> String? {
        let longest = max(image.width, image.height)
        var source = image
        if longest > 1_568 {
            let scale = 1_568 / Double(longest)
            let width = Int(Double(image.width) * scale), height = Int(Double(image.height) * scale)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            source = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, source, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }

    /// The JSON object in an answer, without a code fence or words around it.
    static func extractJSON(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.first == "{" || trimmed.first == "[" { return trimmed }
        guard let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = trimmed.lastIndex(where: { $0 == "}" || $0 == "]" }), start < end else { return trimmed }
        return String(trimmed[start...end])
    }
}
