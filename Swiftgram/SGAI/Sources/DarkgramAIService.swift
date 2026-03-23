import Foundation
import SwiftSignalKit

public protocol DarkgramAIProvider {
    var kind: DarkgramAIProviderKind { get }
    var supportedTasks: Set<DarkgramAITaskKind> { get }
}

private struct DarkgramAIPromptEnvelope {
    let system: String?
    let user: String
}

private struct DarkgramAIUsageState: Codable {
    let dayKey: String
    var countsByFingerprint: [String: Int]
}

public final class DarkgramAIService {
    public static let shared = DarkgramAIService()

    private let keychainStore = DarkgramAIKeychainStore.shared
    private let session: URLSession
    private let defaults: UserDefaults
    private let usageDefaultsKey = "darkgram.ai.dailyUsageByProvider"
    private let preferredKeyDefaultsKey = "darkgram.ai.preferredKeyIndexByProvider"

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45.0
        configuration.timeoutIntervalForResource = 60.0
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
        self.defaults = UserDefaults.standard
    }

    public func saveAPIKey(_ apiKey: String, for provider: DarkgramAIProviderKind) throws {
        try self.keychainStore.setAPIKey(apiKey, for: provider)
    }

    public func clearAPIKey(for provider: DarkgramAIProviderKind) throws {
        try self.keychainStore.deleteAPIKey(for: provider)
    }

    public func apiKey(for provider: DarkgramAIProviderKind) -> String? {
        return try? self.keychainStore.apiKey(for: provider)
    }

    public func saveAPIKeys(_ apiKeys: [String], for provider: DarkgramAIProviderKind) throws {
        try self.keychainStore.setAPIKeys(apiKeys, for: provider)
    }

    public func apiKeys(for provider: DarkgramAIProviderKind) -> [String] {
        return (try? self.keychainStore.apiKeys(for: provider)) ?? []
    }

    public func appendAPIKey(_ apiKey: String, for provider: DarkgramAIProviderKind) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }
        var keys = self.apiKeys(for: provider)
        if !keys.contains(normalized) {
            keys.append(normalized)
        }
        try self.keychainStore.setAPIKeys(keys, for: provider)
    }

    public func replaceAPIKey(_ apiKey: String, fingerprint: String, for provider: DarkgramAIProviderKind) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }
        let keys = self.apiKeys(for: provider)
        let updatedKeys = keys.map { key in
            self.keyFingerprint(for: key) == fingerprint ? normalized : key
        }
        try self.keychainStore.setAPIKeys(updatedKeys, for: provider)
    }

    public func removeAPIKey(fingerprint: String, for provider: DarkgramAIProviderKind) throws {
        let filteredKeys = self.apiKeys(for: provider).filter { self.keyFingerprint(for: $0) != fingerprint }
        try self.keychainStore.setAPIKeys(filteredKeys, for: provider)
    }

    public func apiKeyDescriptors(for provider: DarkgramAIProviderKind) -> [DarkgramAIAPIKeyDescriptor] {
        return self.apiKeys(for: provider).map { key in
            DarkgramAIAPIKeyDescriptor(
                value: key,
                fingerprint: self.keyFingerprint(for: key),
                maskedSuffix: String(key.suffix(min(4, key.count)))
            )
        }
    }

    public func apiKeyUsageSnapshots(for provider: DarkgramAIProviderKind) -> [DarkgramAIAPIKeyUsageSnapshot] {
        let usageState = self.usageState(for: provider)
        return self.apiKeyDescriptors(for: provider).map { descriptor in
            DarkgramAIAPIKeyUsageSnapshot(
                descriptor: descriptor,
                requestsToday: usageState.countsByFingerprint[descriptor.fingerprint] ?? 0
            )
        }
    }

    public func secretStatus(for provider: DarkgramAIProviderKind) -> DarkgramAISecretStatus {
        let descriptors = self.apiKeyDescriptors(for: provider)
        guard let firstDescriptor = descriptors.first else {
            return .notSet
        }
        if descriptors.count == 1 {
            return .configured(maskedSuffix: firstDescriptor.maskedSuffix)
        } else {
            return .configured(maskedSuffix: "\(firstDescriptor.maskedSuffix) +\(descriptors.count - 1)")
        }
    }

    public func providerConfiguration(from snapshot: DarkgramAISettingsSnapshot, provider: DarkgramAIProviderKind? = nil) -> DarkgramAIProviderConfiguration {
        let resolvedProvider = provider ?? snapshot.activeProvider
        return DarkgramAIProviderConfiguration(
            provider: resolvedProvider,
            model: snapshot.model(for: resolvedProvider),
            apiKeys: self.apiKeyDescriptors(for: resolvedProvider)
        )
    }

    public func isConfigured(snapshot: DarkgramAISettingsSnapshot, provider: DarkgramAIProviderKind? = nil) -> Bool {
        return self.providerConfiguration(from: snapshot, provider: provider).isConfigured
    }

    public func resolvedResponseLanguage(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        if trimmed.isEmpty || normalized == "system" || normalized == "default" || normalized == "auto" {
            return self.systemResponseLanguageDisplayName()
        }
        return trimmed
    }

    public func perform(
        request: DarkgramAIRequest,
        snapshot: DarkgramAISettingsSnapshot,
        provider: DarkgramAIProviderKind? = nil
    ) -> Signal<DarkgramAIResponse, DarkgramAIError> {
        let configuration = self.providerConfiguration(from: snapshot, provider: provider)
        guard configuration.isConfigured else {
            return .fail(.providerNotConfigured)
        }

        let promptEnvelope = self.buildPromptEnvelope(for: request, snapshot: snapshot)
        guard !promptEnvelope.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .fail(.emptyInput)
        }

        let orderedKeys = self.orderedAPIKeys(for: configuration.provider, descriptors: configuration.apiKeys)
        guard !orderedKeys.isEmpty else {
            return .fail(.providerNotConfigured)
        }

        return self.perform(
            using: orderedKeys,
            configuration: configuration,
            promptEnvelope: promptEnvelope
        )
    }

    private func performGemini(configuration: DarkgramAIProviderConfiguration, apiKey: String, promptEnvelope: DarkgramAIPromptEnvelope) -> Signal<DarkgramAIResponse, DarkgramAIError> {
        guard let encodedModel = configuration.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return .fail(.invalidResponse)
        }

        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent")
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let url = components?.url else {
            return .fail(.invalidResponse)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        [
                            "text": promptEnvelope.user
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.3
            ]
        ]
        if let system = promptEnvelope.system, !system.isEmpty {
            payload["system_instruction"] = [
                "parts": [
                    [
                        "text": system
                    ]
                ]
            ]
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            return .fail(.transport(error.localizedDescription))
        }

        return self.performRequest(configuration: configuration, request: request, parse: { data in
            self.parseGeminiResponse(data)
        })
    }

    private func performGrok(configuration: DarkgramAIProviderConfiguration, apiKey: String, promptEnvelope: DarkgramAIPromptEnvelope) -> Signal<DarkgramAIResponse, DarkgramAIError> {
        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else {
            return .fail(.invalidResponse)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var messages: [[String: Any]] = []
        if let system = promptEnvelope.system, !system.isEmpty {
            messages.append([
                "role": "system",
                "content": system
            ])
        }
        messages.append([
            "role": "user",
            "content": promptEnvelope.user
        ])

        let payload: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "temperature": 0.3,
            "stream": false
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            return .fail(.transport(error.localizedDescription))
        }

        return self.performRequest(configuration: configuration, request: request, parse: { data in
            self.parseGrokResponse(data)
        })
    }

    private func performRequest(
        configuration: DarkgramAIProviderConfiguration,
        request: URLRequest,
        parse: @escaping (Data) -> Result<String, DarkgramAIError>
    ) -> Signal<DarkgramAIResponse, DarkgramAIError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                subscriber.putError(.transport("service_unavailable"))
                return EmptyDisposable
            }

            let task = self.session.dataTask(with: request) { data, response, error in
                if let error {
                    subscriber.putError(.transport(error.localizedDescription))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse, let data else {
                    subscriber.putError(.invalidResponse)
                    return
                }

                guard (200 ..< 300).contains(httpResponse.statusCode) else {
                    subscriber.putError(self.providerError(from: data, statusCode: httpResponse.statusCode))
                    return
                }

                switch parse(data) {
                case let .success(text):
                    subscriber.putNext(DarkgramAIResponse(provider: configuration.provider, model: configuration.model, text: text))
                    subscriber.putCompletion()
                case let .failure(error):
                    subscriber.putError(error)
                }
            }

            task.resume()

            return ActionDisposable {
                task.cancel()
            }
        }
    }

    private func perform(
        using orderedKeys: [DarkgramAIAPIKeyDescriptor],
        configuration: DarkgramAIProviderConfiguration,
        promptEnvelope: DarkgramAIPromptEnvelope
    ) -> Signal<DarkgramAIResponse, DarkgramAIError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()

            func attempt(_ index: Int) {
                let descriptor = orderedKeys[index]
                self.incrementUsageCount(for: configuration.provider, fingerprint: descriptor.fingerprint)

                let signal: Signal<DarkgramAIResponse, DarkgramAIError>
                switch configuration.provider {
                case .gemini:
                    signal = self.performGemini(configuration: configuration, apiKey: descriptor.value, promptEnvelope: promptEnvelope)
                case .grok:
                    signal = self.performGrok(configuration: configuration, apiKey: descriptor.value, promptEnvelope: promptEnvelope)
                }

                disposable.set(signal.start(next: { response in
                    if let preferredIndex = configuration.apiKeys.firstIndex(where: { $0.fingerprint == descriptor.fingerprint }) {
                        self.setPreferredKeyIndex(preferredIndex, for: configuration.provider)
                    }
                    subscriber.putNext(response)
                    subscriber.putCompletion()
                }, error: { error in
                    if index + 1 < orderedKeys.count, self.shouldFallbackToNextKey(after: error) {
                        attempt(index + 1)
                    } else {
                        subscriber.putError(error)
                    }
                }))
            }

            attempt(0)
            return disposable
        }
    }

    private func shouldFallbackToNextKey(after error: DarkgramAIError) -> Bool {
        switch error {
        case .providerRejected, .transport, .invalidResponse, .emptyResult:
            return true
        case .providerNotConfigured, .emptyInput:
            return false
        }
    }

    private func buildPromptEnvelope(for request: DarkgramAIRequest, snapshot: DarkgramAISettingsSnapshot) -> DarkgramAIPromptEnvelope {
        let messageBlock = request.selectedMessages
            .map { self.serializedMessageContext($0) }
            .joined(separator: "\n")

        let recentMessagesBlock = request.recentMessages
            .map { self.serializedMessageContext($0) }
            .joined(separator: "\n")

        let debateThreadBlock = request.debateThreadMessages
            .map { self.serializedMessageContext($0) }
            .joined(separator: "\n")

        let transcriptBlock = request.transcript?.trimmingCharacters(in: .whitespacesAndNewlines)

        let system: String
        var userSections: [String] = []
        let responseLanguage = self.resolvedResponseLanguage(from: snapshot.responseLanguage)
        let responseLanguageInstruction = "Always answer in \(responseLanguage). Do not switch to another language unless the user explicitly asks you to."

        switch request.task {
        case .summarizeMessages:
            let summaryLimit = max(2, min(5, Int(request.maxSummarySentences ?? 5)))
            let base = request.systemPrompt?.nonEmpty ?? "You are a concise assistant inside a messaging client. Summarize selected chat messages clearly, preserve the important facts, promises, decisions, dates, and disagreements, and return plain text only."
            system = "\(base) \(responseLanguageInstruction)"
            userSections.append("Task: Summarize the selected messages in \(summaryLimit) sentences or fewer.")
        case .summarizeVoiceTranscript:
            let summaryLimit = max(2, min(5, Int(request.maxSummarySentences ?? 5)))
            let base = request.systemPrompt?.nonEmpty ?? "You are a concise assistant inside a messaging client. Summarize the voice transcript clearly and return plain text only."
            system = "\(base) \(responseLanguageInstruction)"
            userSections.append("Task: Summarize the provided voice transcript in \(summaryLimit) sentences or fewer.")
        case .askAboutMessages:
            let base = request.systemPrompt?.nonEmpty ?? "You are an assistant inside a messaging client. Analyze the provided chat messages carefully, use the author names and timestamps when relevant, and return plain text only."
            system = "\(base) \(responseLanguageInstruction)"
            userSections.append("Task: Follow the user's instruction about the selected messages.")
        case .draftMessage:
            let base = request.systemPrompt?.nonEmpty ?? "You are an assistant inside a messaging client. Draft a message in the user's voice and return only the message text."
            system = "\(base) \(responseLanguageInstruction)"
            userSections.append("Task: Draft a message for the user.")
        case .draftReply:
            let base = request.systemPrompt?.nonEmpty ?? "You are an assistant inside a messaging client. Draft a reply to the provided conversation context in the user's voice and return only the message text."
            system = "\(base) \(responseLanguageInstruction)"
            userSections.append("Task: Draft a reply to the selected conversation context.")
        case .freeChat:
            let base = request.systemPrompt?.nonEmpty ?? "You are a helpful assistant inside a messaging client. Return plain text only."
            system = "\(base) \(responseLanguageInstruction)"
            userSections.append("Task: Answer the user's request.")
        }

        if !request.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userSections.append("User instruction:\n\(request.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if !messageBlock.isEmpty {
            userSections.append("Selected messages:\n\(messageBlock)")
        }
        if !recentMessagesBlock.isEmpty {
            userSections.append("Recent chat context:\n\(recentMessagesBlock)")
        }
        if !debateThreadBlock.isEmpty {
            userSections.append("Debate thread context:\n\(debateThreadBlock)")
        }
        if let transcriptBlock, !transcriptBlock.isEmpty {
            userSections.append("Transcript:\n\(transcriptBlock)")
        }
        userSections.append("Return only the final answer as plain text.")

        return DarkgramAIPromptEnvelope(
            system: system,
            user: userSections.joined(separator: "\n\n")
        )
    }

    private func serializedMessageContext(_ entry: DarkgramAIMessageContextEntry) -> String {
        var line = "[\(self.formattedTimestamp(entry.timestamp))] \(entry.authorName)"
        line += entry.isOutgoing ? " (outgoing)" : " (incoming)"
        line += ": "

        let trimmedText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            line += trimmedText
        } else if let mediaHint = entry.mediaHint, !mediaHint.isEmpty {
            line += "[\(mediaHint)]"
        } else {
            line += "[empty]"
        }

        if let mediaHint = entry.mediaHint, !mediaHint.isEmpty, !trimmedText.isEmpty {
            line += " [media: \(mediaHint)]"
        }

        return line
    }

    private func formattedTimestamp(_ timestamp: Int64) -> String {
        let interval: TimeInterval
        if timestamp > 1_000_000_000_000 {
            interval = Double(timestamp) / 1000.0
        } else {
            interval = Double(timestamp)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withSpaceBetweenDateAndTime]
        return formatter.string(from: Date(timeIntervalSince1970: interval))
    }

    private func systemResponseLanguageDisplayName() -> String {
        let preferredIdentifier = Locale.preferredLanguages.first ?? "en"
        let preferredLocale = Locale(identifier: preferredIdentifier)
        let englishLocale = Locale(identifier: "en")

        if let languageCode = preferredLocale.languageCode,
           let localized = englishLocale.localizedString(forLanguageCode: languageCode),
           !localized.isEmpty {
            return localized.capitalized
        }

        if let localized = englishLocale.localizedString(forIdentifier: preferredIdentifier),
           !localized.isEmpty {
            return localized.capitalized
        }

        return "the user's current language"
    }

    private func keyFingerprint(for key: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    private func orderedAPIKeys(for provider: DarkgramAIProviderKind, descriptors: [DarkgramAIAPIKeyDescriptor]) -> [DarkgramAIAPIKeyDescriptor] {
        guard !descriptors.isEmpty else {
            return []
        }
        let startIndex = min(max(self.preferredKeyIndex(for: provider), 0), descriptors.count - 1)
        if startIndex == 0 {
            return descriptors
        }
        var result: [DarkgramAIAPIKeyDescriptor] = []
        result.reserveCapacity(descriptors.count)
        for index in startIndex ..< descriptors.count {
            result.append(descriptors[index])
        }
        if startIndex > 0 {
            for index in 0 ..< startIndex {
                result.append(descriptors[index])
            }
        }
        return result
    }

    private func preferredKeyIndex(for provider: DarkgramAIProviderKind) -> Int {
        let map = self.defaults.dictionary(forKey: self.preferredKeyDefaultsKey) ?? [:]
        if let value = map[provider.rawValue] as? Int {
            return value
        } else if let number = map[provider.rawValue] as? NSNumber {
            return number.intValue
        } else {
            return 0
        }
    }

    private func setPreferredKeyIndex(_ index: Int, for provider: DarkgramAIProviderKind) {
        var map = self.defaults.dictionary(forKey: self.preferredKeyDefaultsKey) ?? [:]
        map[provider.rawValue] = index
        self.defaults.set(map, forKey: self.preferredKeyDefaultsKey)
    }

    private func usageState(for provider: DarkgramAIProviderKind) -> DarkgramAIUsageState {
        let dayKey = self.currentDayKey()
        guard
            let rawMap = self.defaults.dictionary(forKey: self.usageDefaultsKey) as? [String: Data],
            let data = rawMap[provider.rawValue],
            let state = try? JSONDecoder().decode(DarkgramAIUsageState.self, from: data)
        else {
            return DarkgramAIUsageState(dayKey: dayKey, countsByFingerprint: [:])
        }

        if state.dayKey != dayKey {
            return DarkgramAIUsageState(dayKey: dayKey, countsByFingerprint: [:])
        }
        return state
    }

    private func saveUsageState(_ state: DarkgramAIUsageState, for provider: DarkgramAIProviderKind) {
        var rawMap = self.defaults.dictionary(forKey: self.usageDefaultsKey) as? [String: Data] ?? [:]
        if let data = try? JSONEncoder().encode(state) {
            rawMap[provider.rawValue] = data
            self.defaults.set(rawMap, forKey: self.usageDefaultsKey)
        }
    }

    private func incrementUsageCount(for provider: DarkgramAIProviderKind, fingerprint: String) {
        var state = self.usageState(for: provider)
        state.countsByFingerprint[fingerprint, default: 0] += 1
        self.saveUsageState(state, for: provider)
    }

    private func currentDayKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func normalizedResponseText(_ text: String) -> Result<String, DarkgramAIError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyResult)
        }
        return .success(trimmed)
    }

    private func parseGeminiResponse(_ data: Data) -> Result<String, DarkgramAIError> {
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }

        guard
            let json = jsonObject as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]]
        else {
            return .failure(.invalidResponse)
        }

        let text = candidates
            .compactMap { candidate -> [String]? in
                guard
                    let content = candidate["content"] as? [String: Any],
                    let parts = content["parts"] as? [[String: Any]]
                else {
                    return nil
                }
                return parts.compactMap { $0["text"] as? String }
            }
            .flatMap { $0 }
            .joined(separator: "\n")

        return self.normalizedResponseText(text)
    }

    private func parseGrokResponse(_ data: Data) -> Result<String, DarkgramAIError> {
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }

        guard
            let json = jsonObject as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            return .failure(.invalidResponse)
        }

        return self.normalizedResponseText(content)
    }

    private func providerError(from data: Data, statusCode: Int) -> DarkgramAIError {
        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let error = json["error"] as? [String: Any] {
                if let message = error["message"] as? String, !message.isEmpty {
                    return .providerRejected("HTTP \(statusCode): \(message)")
                } else if let message = error["status"] as? String, !message.isEmpty {
                    return .providerRejected("HTTP \(statusCode): \(message)")
                }
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return .providerRejected("HTTP \(statusCode): \(message)")
            }
        }
        return .providerRejected("HTTP \(statusCode)")
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
