import Foundation

public enum DarkgramAIProviderKind: String, CaseIterable, Codable {
    case gemini
    case grok

    public var title: String {
        switch self {
        case .gemini:
            return "Gemini"
        case .grok:
            return "Grok"
        }
    }

    public var defaultModel: String {
        switch self {
        case .gemini:
            return "gemini-2.5-flash"
        case .grok:
            return "grok-4"
        }
    }
}

public enum DarkgramAITaskKind: String, CaseIterable, Codable {
    case summarizeMessages
    case summarizeVoiceTranscript
    case askAboutMessages
    case draftMessage
    case draftReply
    case freeChat
}

public struct DarkgramAISettingsSnapshot {
    public let enabled: Bool
    public let activeProviderRawValue: String
    public let responseLanguage: String
    public let geminiModel: String
    public let grokModel: String
    public let messageSummariesEnabled: Bool
    public let voiceSummariesEnabled: Bool
    public let composeButtonEnabled: Bool
    public let replyDraftingEnabled: Bool
    public let debateThreadsEnabled: Bool
    public let allowRecentChatContext: Bool
    public let allowTranscriptUpload: Bool
    public let redactUsernames: Bool
    public let confirmLargeContext: Bool

    public init(
        enabled: Bool,
        activeProviderRawValue: String,
        responseLanguage: String,
        geminiModel: String,
        grokModel: String,
        messageSummariesEnabled: Bool,
        voiceSummariesEnabled: Bool,
        composeButtonEnabled: Bool,
        replyDraftingEnabled: Bool,
        debateThreadsEnabled: Bool,
        allowRecentChatContext: Bool,
        allowTranscriptUpload: Bool,
        redactUsernames: Bool,
        confirmLargeContext: Bool
    ) {
        self.enabled = enabled
        self.activeProviderRawValue = activeProviderRawValue
        self.responseLanguage = responseLanguage
        self.geminiModel = geminiModel
        self.grokModel = grokModel
        self.messageSummariesEnabled = messageSummariesEnabled
        self.voiceSummariesEnabled = voiceSummariesEnabled
        self.composeButtonEnabled = composeButtonEnabled
        self.replyDraftingEnabled = replyDraftingEnabled
        self.debateThreadsEnabled = debateThreadsEnabled
        self.allowRecentChatContext = allowRecentChatContext
        self.allowTranscriptUpload = allowTranscriptUpload
        self.redactUsernames = redactUsernames
        self.confirmLargeContext = confirmLargeContext
    }

    public var activeProvider: DarkgramAIProviderKind {
        return DarkgramAIProviderKind(rawValue: self.activeProviderRawValue) ?? .gemini
    }

    public func model(for provider: DarkgramAIProviderKind) -> String {
        switch provider {
        case .gemini:
            return self.geminiModel
        case .grok:
            return self.grokModel
        }
    }
}

public struct DarkgramAIProviderConfiguration {
    public let provider: DarkgramAIProviderKind
    public let model: String
    public let apiKeys: [DarkgramAIAPIKeyDescriptor]

    public var isConfigured: Bool {
        return !self.apiKeys.isEmpty && !self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct DarkgramAIAPIKeyDescriptor: Equatable {
    public let value: String
    public let fingerprint: String
    public let maskedSuffix: String

    public init(value: String, fingerprint: String, maskedSuffix: String) {
        self.value = value
        self.fingerprint = fingerprint
        self.maskedSuffix = maskedSuffix
    }
}

public struct DarkgramAIAPIKeyUsageSnapshot: Equatable {
    public let descriptor: DarkgramAIAPIKeyDescriptor
    public let requestsToday: Int

    public init(descriptor: DarkgramAIAPIKeyDescriptor, requestsToday: Int) {
        self.descriptor = descriptor
        self.requestsToday = requestsToday
    }
}

public struct DarkgramAIMessageContextEntry: Codable, Equatable {
    public let authorName: String
    public let timestamp: Int64
    public let isOutgoing: Bool
    public let text: String
    public let mediaHint: String?

    public init(authorName: String, timestamp: Int64, isOutgoing: Bool, text: String, mediaHint: String? = nil) {
        self.authorName = authorName
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.text = text
        self.mediaHint = mediaHint
    }
}

public struct DarkgramAIStoredMessageReference: Codable, Equatable {
    public let peerId: Int64
    public let namespace: Int32
    public let id: Int32
    public let threadId: Int64?

    public init(peerId: Int64, namespace: Int32, id: Int32, threadId: Int64?) {
        self.peerId = peerId
        self.namespace = namespace
        self.id = id
        self.threadId = threadId
    }

    public var stableKey: String {
        return "\(self.peerId):\(self.namespace):\(self.id):\(self.threadId ?? 0)"
    }
}

public struct DarkgramAIDebateThreadEntry: Codable, Equatable {
    public let reference: DarkgramAIStoredMessageReference
    public let context: DarkgramAIMessageContextEntry

    public init(reference: DarkgramAIStoredMessageReference, context: DarkgramAIMessageContextEntry) {
        self.reference = reference
        self.context = context
    }
}

public struct DarkgramAIDebateThreadState: Codable, Equatable {
    public let updatedAt: Int64
    public let entries: [DarkgramAIDebateThreadEntry]

    public init(updatedAt: Int64, entries: [DarkgramAIDebateThreadEntry]) {
        self.updatedAt = updatedAt
        self.entries = entries
    }
}

public struct DarkgramAIRequest {
    public let task: DarkgramAITaskKind
    public let userPrompt: String
    public let systemPrompt: String?
    public let selectedMessages: [DarkgramAIMessageContextEntry]
    public let recentMessages: [DarkgramAIMessageContextEntry]
    public let debateThreadMessages: [DarkgramAIMessageContextEntry]
    public let transcript: String?
    public let maxSummarySentences: Int32?

    public init(
        task: DarkgramAITaskKind,
        userPrompt: String,
        systemPrompt: String? = nil,
        selectedMessages: [DarkgramAIMessageContextEntry] = [],
        recentMessages: [DarkgramAIMessageContextEntry] = [],
        debateThreadMessages: [DarkgramAIMessageContextEntry] = [],
        transcript: String? = nil,
        maxSummarySentences: Int32? = nil
    ) {
        self.task = task
        self.userPrompt = userPrompt
        self.systemPrompt = systemPrompt
        self.selectedMessages = selectedMessages
        self.recentMessages = recentMessages
        self.debateThreadMessages = debateThreadMessages
        self.transcript = transcript
        self.maxSummarySentences = maxSummarySentences
    }
}

public struct DarkgramAIResponse {
    public let provider: DarkgramAIProviderKind
    public let model: String
    public let text: String

    public init(provider: DarkgramAIProviderKind, model: String, text: String) {
        self.provider = provider
        self.model = model
        self.text = text
    }
}

public enum DarkgramAISecretStatus: Equatable {
    case notSet
    case configured(maskedSuffix: String)
}

public enum DarkgramAIError: Error, Equatable {
    case providerNotConfigured
    case emptyInput
    case emptyResult
    case invalidResponse
    case transport(String)
    case providerRejected(String)
}
