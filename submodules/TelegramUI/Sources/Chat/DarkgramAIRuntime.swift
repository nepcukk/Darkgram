import Foundation
import UIKit
import SGAI
import SGAIUI
import SGSimpleSettings
import SGStrings
import Postbox
import TelegramCore
import SwiftSignalKit
import AccountContext
import ChatPresentationInterfaceState
import ChatControllerInteraction
import Display
import OverlayStatusController
import PresentationDataUtils
import PromptUI
import TelegramPresentationData
import UndoUI

private let darkgramAISharedLargeContextCharacterLimit = 6000
private let darkgramAIComposeRecentContextLimit = 12

private func darkgramAISharedMessageMediaHint(message: Message, lang: String) -> String? {
    for media in message.media {
        if media is TelegramMediaImage {
            return lang == "ru" ? "Фото" : "Photo"
        } else if let file = media as? TelegramMediaFile {
            if file.isInstantVideo {
                return lang == "ru" ? "Кружок" : "Round Video"
            } else if file.isVoice {
                return lang == "ru" ? "Голосовое сообщение" : "Voice Message"
            } else if file.isVideo {
                return lang == "ru" ? "Видео" : "Video"
            } else if file.isMusic {
                return lang == "ru" ? "Аудио" : "Audio"
            }
            return lang == "ru" ? "Файл" : "File"
        } else if media is TelegramMediaPoll {
            return lang == "ru" ? "Опрос" : "Poll"
        } else if media is TelegramMediaMap {
            return lang == "ru" ? "Геопозиция" : "Location"
        } else if media is TelegramMediaContact {
            return lang == "ru" ? "Контакт" : "Contact"
        }
    }
    return nil
}

private func darkgramAISharedMessageText(message: Message, lang: String) -> String {
    let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        return trimmed
    }
    return darkgramAISharedMessageMediaHint(message: message, lang: lang) ?? ""
}

private func darkgramAISharedResolvedAuthorName(
    peerId: PeerId,
    explicitAuthorName: String?,
    isOutgoing: Bool,
    snapshot: DarkgramAISettingsSnapshot,
    aliasByPeerId: inout [PeerId: String],
    nextAliasIndex: inout Int,
    fallback: String
) -> String {
    if isOutgoing {
        return "You"
    }
    if snapshot.redactUsernames {
        if let existing = aliasByPeerId[peerId] {
            return existing
        }
        let alias = "Participant \(nextAliasIndex)"
        nextAliasIndex += 1
        aliasByPeerId[peerId] = alias
        return alias
    }
    if let explicitAuthorName {
        let trimmed = explicitAuthorName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return explicitAuthorName
        }
    }
    return fallback
}

func darkgramAISharedContextEntries(
    messages: [Message],
    accountPeerId: PeerId,
    presentationData: PresentationData,
    snapshot: DarkgramAISettingsSnapshot,
    aliasByPeerId: inout [PeerId: String],
    nextAliasIndex: inout Int
) -> [DarkgramAIMessageContextEntry] {
    let lang = presentationData.strings.baseLanguageCode
    return messages
        .sorted(by: { $0.index < $1.index })
        .map { message in
            let isOutgoing = !message.effectivelyIncoming(accountPeerId)
            let authorPeerId = message.author?.id ?? message.id.peerId
            let authorName: String
            if let author = message.author {
                authorName = darkgramAISharedResolvedAuthorName(
                    peerId: authorPeerId,
                    explicitAuthorName: EnginePeer(author).displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder),
                    isOutgoing: isOutgoing,
                    snapshot: snapshot,
                    aliasByPeerId: &aliasByPeerId,
                    nextAliasIndex: &nextAliasIndex,
                    fallback: "Unknown"
                )
            } else if let peer = message.peers[authorPeerId] {
                authorName = darkgramAISharedResolvedAuthorName(
                    peerId: authorPeerId,
                    explicitAuthorName: EnginePeer(peer).displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder),
                    isOutgoing: isOutgoing,
                    snapshot: snapshot,
                    aliasByPeerId: &aliasByPeerId,
                    nextAliasIndex: &nextAliasIndex,
                    fallback: "Unknown"
                )
            } else {
                authorName = darkgramAISharedResolvedAuthorName(
                    peerId: authorPeerId,
                    explicitAuthorName: nil,
                    isOutgoing: isOutgoing,
                    snapshot: snapshot,
                    aliasByPeerId: &aliasByPeerId,
                    nextAliasIndex: &nextAliasIndex,
                    fallback: "Unknown"
                )
            }
            return DarkgramAIMessageContextEntry(
                authorName: authorName,
                timestamp: Int64(message.timestamp),
                isOutgoing: isOutgoing,
                text: darkgramAISharedMessageText(message: message, lang: lang),
                mediaHint: darkgramAISharedMessageMediaHint(message: message, lang: lang)
            )
        }
}

private func darkgramAISharedDebateContextEntries(
    entries: [DarkgramAIDebateThreadEntry],
    accountPeerId: PeerId,
    snapshot: DarkgramAISettingsSnapshot,
    aliasByPeerId: inout [PeerId: String],
    nextAliasIndex: inout Int
) -> [DarkgramAIMessageContextEntry] {
    return entries.sorted(by: { $0.context.timestamp < $1.context.timestamp }).map { entry in
        let peerId = PeerId(entry.reference.peerId)
        let authorName = darkgramAISharedResolvedAuthorName(
            peerId: peerId,
            explicitAuthorName: entry.context.authorName,
            isOutgoing: entry.context.isOutgoing || peerId == accountPeerId,
            snapshot: snapshot,
            aliasByPeerId: &aliasByPeerId,
            nextAliasIndex: &nextAliasIndex,
            fallback: entry.context.authorName
        )
        return DarkgramAIMessageContextEntry(
            authorName: authorName,
            timestamp: entry.context.timestamp,
            isOutgoing: entry.context.isOutgoing,
            text: entry.context.text,
            mediaHint: entry.context.mediaHint
        )
    }
}

func darkgramAISharedStoredReference(message: Message, threadId: Int64?) -> DarkgramAIStoredMessageReference {
    return DarkgramAIStoredMessageReference(
        peerId: message.id.peerId.toInt64(),
        namespace: message.id.namespace,
        id: message.id.id,
        threadId: threadId ?? message.threadId
    )
}

func darkgramAISharedCharacterCount(
    selectedEntries: [DarkgramAIMessageContextEntry],
    recentEntries: [DarkgramAIMessageContextEntry],
    debateEntries: [DarkgramAIMessageContextEntry],
    extraPrompt: String = ""
) -> Int {
    var total = extraPrompt.count
    for entry in selectedEntries {
        total += entry.authorName.count + entry.text.count + (entry.mediaHint?.count ?? 0) + 32
    }
    for entry in recentEntries {
        total += entry.authorName.count + entry.text.count + (entry.mediaHint?.count ?? 0) + 32
    }
    for entry in debateEntries {
        total += entry.authorName.count + entry.text.count + (entry.mediaHint?.count ?? 0) + 32
    }
    return total
}

func darkgramAISharedInsertIntoInput(controllerInteraction: ChatControllerInteraction, text: String) {
    controllerInteraction.updateInputState { current in
        let updated = NSMutableAttributedString(attributedString: current.inputText)
        if updated.length > 0 {
            let suffix = updated.string.hasSuffix("\n") ? "\n" : "\n\n"
            updated.append(NSAttributedString(string: suffix))
        }
        updated.append(NSAttributedString(string: text))
        let selectionIndex = updated.length
        return ChatTextInputState(inputText: updated, selectionRange: selectionIndex ..< selectionIndex)
    }
}

func darkgramAISharedPresentError(
    context: AccountContext,
    controllerInteraction: ChatControllerInteraction,
    title: String,
    error: DarkgramAIError
) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode

    let text: String
    switch error {
    case .providerNotConfigured:
        text = "Darkgram.AI.Error.NotConfigured".i18n(lang)
    case .emptyInput:
        text = "Darkgram.AI.Error.EmptyInput".i18n(lang)
    case .emptyResult:
        text = "Darkgram.AI.Error.EmptyResult".i18n(lang)
    case let .providerRejected(message):
        text = String(format: "Darkgram.AI.Error.ProviderRejected".i18n(lang), message)
    case let .transport(message):
        text = String(format: "Darkgram.AI.Error.Transport".i18n(lang), message)
    case .invalidResponse:
        text = "Darkgram.AI.Error.InvalidResponse".i18n(lang)
    }

    controllerInteraction.presentControllerInCurrent(
        textAlertController(
            context: context,
            title: title,
            text: text,
            actions: [
                TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
            ]
        ),
        nil
    )
}

func darkgramAISharedPresentInfo(context: AccountContext, controllerInteraction: ChatControllerInteraction, text: String) {
    controllerInteraction.displayUndo(.info(title: nil, text: text, timeout: nil, customUndoText: nil))
}

func darkgramAISharedPresentResult(
    context: AccountContext,
    controllerInteraction: ChatControllerInteraction,
    title: String,
    response: DarkgramAIResponse
) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode
    controllerInteraction.presentControllerInCurrent(
        darkgramAIResultController(
            context: context,
            title: title,
            text: response.text,
            copyTitle: "Darkgram.AI.Common.Copy".i18n(lang),
            insertTitle: "Darkgram.AI.Result.Insert".i18n(lang),
            onInsert: {
                darkgramAISharedInsertIntoInput(controllerInteraction: controllerInteraction, text: response.text)
            }
        ),
        ViewControllerPresentationArguments(presentationAnimation: .modalSheet)
    )
}

func darkgramAISharedPerformRequest(
    context: AccountContext,
    controllerInteraction: ChatControllerInteraction,
    chatPresentationInterfaceState: ChatPresentationInterfaceState,
    request: DarkgramAIRequest,
    overlayText: String,
    resultTitle: String,
    onResponse: ((DarkgramAIResponse) -> Void)? = nil
) {
    let snapshot = SGSimpleSettings.shared.darkgramAISettingsSnapshot
    let overlayController = OverlayStatusController(theme: chatPresentationInterfaceState.theme, type: .loading(cancelled: nil))
    controllerInteraction.presentGlobalOverlayController(overlayController, nil)

    let _ = (DarkgramAIService.shared.perform(request: request, snapshot: snapshot)
    |> deliverOnMainQueue).start(next: { response in
        overlayController.dismiss()
        if let onResponse {
            onResponse(response)
        } else {
            darkgramAISharedPresentResult(
                context: context,
                controllerInteraction: controllerInteraction,
                title: resultTitle,
                response: response
            )
        }
    }, error: { error in
        overlayController.dismiss()
        darkgramAISharedPresentError(
            context: context,
            controllerInteraction: controllerInteraction,
            title: overlayText,
            error: error
        )
    })
}

func darkgramAISharedPerformAfterLargeContextConfirmation(
    context: AccountContext,
    controllerInteraction: ChatControllerInteraction,
    selectedEntries: [DarkgramAIMessageContextEntry],
    recentEntries: [DarkgramAIMessageContextEntry],
    debateEntries: [DarkgramAIMessageContextEntry],
    extraPrompt: String = "",
    perform: @escaping () -> Void
) {
    let snapshot = SGSimpleSettings.shared.darkgramAISettingsSnapshot
    guard snapshot.confirmLargeContext else {
        perform()
        return
    }

    let totalCharacterCount = darkgramAISharedCharacterCount(
        selectedEntries: selectedEntries,
        recentEntries: recentEntries,
        debateEntries: debateEntries,
        extraPrompt: extraPrompt
    )
    guard totalCharacterCount > darkgramAISharedLargeContextCharacterLimit else {
        perform()
        return
    }

    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode
    controllerInteraction.presentControllerInCurrent(
        textAlertController(
            context: context,
            title: "Darkgram.AI.ContextMenu.ConfirmLargeContext.Title".i18n(lang),
            text: String(format: "Darkgram.AI.ContextMenu.ConfirmLargeContext.Text".i18n(lang), totalCharacterCount),
            actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                TextAlertAction(type: .defaultAction, title: "Darkgram.AI.Common.Continue".i18n(lang), action: perform)
            ]
        ),
        nil
    )
}

func darkgramAISharedRecentContextSignal(
    context: AccountContext,
    chatLocation: ChatLocation,
    snapshot: DarkgramAISettingsSnapshot,
    limit: Int = darkgramAIComposeRecentContextLimit
) -> Signal<[DarkgramAIMessageContextEntry], NoError> {
    guard snapshot.allowRecentChatContext else {
        return .single([])
    }

    let contextHolder = Atomic<ChatLocationContextHolder?>(value: nil)
    return context.account.viewTracker.aroundMessageHistoryViewForLocation(
        context.chatLocationInput(for: chatLocation, contextHolder: contextHolder),
        index: .upperBound,
        anchorIndex: .upperBound,
        count: limit,
        fixedCombinedReadStates: nil
    )
    |> take(1)
    |> map { view, _, _ -> [DarkgramAIMessageContextEntry] in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        var aliasByPeerId: [PeerId: String] = [:]
        var nextAliasIndex = 1
        var messages: [Message] = []
        messages.reserveCapacity(view.entries.count)
        for entry in view.entries {
            messages.append(entry.message)
        }
        return darkgramAISharedContextEntries(
            messages: messages,
            accountPeerId: context.account.peerId,
            presentationData: presentationData,
            snapshot: snapshot,
            aliasByPeerId: &aliasByPeerId,
            nextAliasIndex: &nextAliasIndex
        )
    }
}

func darkgramAISharedIsVoiceSummarizable(message: Message) -> Bool {
    for media in message.media {
        if let file = media as? TelegramMediaFile, file.isVoice || file.isInstantVideo {
            return true
        }
    }
    return false
}

private func darkgramAISharedAudioTranscription(message: Message) -> AudioTranscriptionMessageAttribute? {
    return message.attributes.first(where: { $0 is AudioTranscriptionMessageAttribute }) as? AudioTranscriptionMessageAttribute
}

private func darkgramAISharedMessageFromPostbox(context: AccountContext, messageId: MessageId) -> Signal<Message?, NoError> {
    return context.account.postbox.transaction { transaction in
        transaction.getMessage(messageId)
    }
}

func darkgramAISummarizeVoiceMessage(
    context: AccountContext,
    controllerInteraction: ChatControllerInteraction,
    chatPresentationInterfaceState: ChatPresentationInterfaceState,
    message: Message
) {
    let snapshot = SGSimpleSettings.shared.darkgramAISettingsSnapshot
    guard snapshot.enabled, snapshot.voiceSummariesEnabled else {
        return
    }
    guard DarkgramAIService.shared.isConfigured(snapshot: snapshot) else {
        darkgramAISharedPresentError(
            context: context,
            controllerInteraction: controllerInteraction,
            title: "Darkgram.AI.ContextMenu.SummarizeVoice".i18n(chatPresentationInterfaceState.strings.baseLanguageCode),
            error: .providerNotConfigured
        )
        return
    }
    guard snapshot.allowTranscriptUpload else {
        darkgramAISharedPresentInfo(
            context: context,
            controllerInteraction: controllerInteraction,
            text: "Darkgram.AI.Voice.TranscriptUploadDisabled".i18n(chatPresentationInterfaceState.strings.baseLanguageCode)
        )
        return
    }

    let summarizeTranscript: (String) -> Void = { transcript in
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            darkgramAISharedPresentError(
                context: context,
                controllerInteraction: controllerInteraction,
                title: "Darkgram.AI.ContextMenu.SummarizeVoice".i18n(chatPresentationInterfaceState.strings.baseLanguageCode),
                error: .emptyInput
            )
            return
        }

        darkgramAISharedPerformAfterLargeContextConfirmation(
            context: context,
            controllerInteraction: controllerInteraction,
            selectedEntries: [],
            recentEntries: [],
            debateEntries: [],
            extraPrompt: trimmedTranscript
        ) {
            darkgramAISharedPerformRequest(
                context: context,
                controllerInteraction: controllerInteraction,
                chatPresentationInterfaceState: chatPresentationInterfaceState,
                request: DarkgramAIRequest(
                    task: .summarizeVoiceTranscript,
                    userPrompt: "Summarize the transcript and preserve the main points.",
                    transcript: trimmedTranscript,
                    maxSummarySentences: 5
                ),
                overlayText: "Darkgram.AI.ContextMenu.SummarizeVoice".i18n(chatPresentationInterfaceState.strings.baseLanguageCode),
                resultTitle: "Darkgram.AI.Result.VoiceSummaryTitle".i18n(chatPresentationInterfaceState.strings.baseLanguageCode)
            )
        }
    }

    if let transcription = darkgramAISharedAudioTranscription(message: message) {
        if let error = transcription.error {
            let errorMessage = error == .tooLong ? "Darkgram.AI.Voice.TranscriptionTooLong".i18n(chatPresentationInterfaceState.strings.baseLanguageCode) : "Darkgram.AI.Voice.TranscriptionFailed".i18n(chatPresentationInterfaceState.strings.baseLanguageCode)
            darkgramAISharedPresentInfo(context: context, controllerInteraction: controllerInteraction, text: errorMessage)
            return
        }
        if !transcription.text.isEmpty && !transcription.isPending {
            summarizeTranscript(transcription.text)
            return
        }
        if transcription.isPending {
            darkgramAISharedPresentInfo(
                context: context,
                controllerInteraction: controllerInteraction,
                text: "Darkgram.AI.Voice.TranscriptionPending".i18n(chatPresentationInterfaceState.strings.baseLanguageCode)
            )
            return
        }
    }

    let _ = (context.engine.messages.transcribeAudio(messageId: message.id)
    |> mapToSignal { _ in
        darkgramAISharedMessageFromPostbox(context: context, messageId: message.id)
    }
    |> deliverOnMainQueue).start(next: { updatedMessage in
        guard let updatedMessage else {
            darkgramAISharedPresentInfo(
                context: context,
                controllerInteraction: controllerInteraction,
                text: "Darkgram.AI.Voice.TranscriptionFailed".i18n(chatPresentationInterfaceState.strings.baseLanguageCode)
            )
            return
        }
        if let transcription = darkgramAISharedAudioTranscription(message: updatedMessage) {
            if let error = transcription.error {
                let errorMessage = error == .tooLong ? "Darkgram.AI.Voice.TranscriptionTooLong".i18n(chatPresentationInterfaceState.strings.baseLanguageCode) : "Darkgram.AI.Voice.TranscriptionFailed".i18n(chatPresentationInterfaceState.strings.baseLanguageCode)
                darkgramAISharedPresentInfo(context: context, controllerInteraction: controllerInteraction, text: errorMessage)
            } else if !transcription.text.isEmpty && !transcription.isPending {
                summarizeTranscript(transcription.text)
            } else {
                darkgramAISharedPresentInfo(
                    context: context,
                    controllerInteraction: controllerInteraction,
                    text: "Darkgram.AI.Voice.TranscriptionStarted".i18n(chatPresentationInterfaceState.strings.baseLanguageCode)
                )
            }
        } else {
            darkgramAISharedPresentInfo(
                context: context,
                controllerInteraction: controllerInteraction,
                text: "Darkgram.AI.Voice.TranscriptionStarted".i18n(chatPresentationInterfaceState.strings.baseLanguageCode)
            )
        }
    })
}

func darkgramAIAddMessagesToDebateThread(
    context: AccountContext,
    peerId: PeerId,
    threadId: Int64?,
    messages: [Message]
) -> Int {
    let snapshot = SGSimpleSettings.shared.darkgramAISettingsSnapshot
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    var aliasByPeerId: [PeerId: String] = [:]
    var nextAliasIndex = 1
    let contexts = darkgramAISharedContextEntries(
        messages: messages,
        accountPeerId: context.account.peerId,
        presentationData: presentationData,
        snapshot: snapshot,
        aliasByPeerId: &aliasByPeerId,
        nextAliasIndex: &nextAliasIndex
    )

    let currentEntries = SGSimpleSettings.shared.darkgramAIDebateThreadEntries(peerId: peerId, threadId: threadId)
    var byKey: [String: DarkgramAIDebateThreadEntry] = [:]
    byKey.reserveCapacity(currentEntries.count)
    for entry in currentEntries {
        byKey[entry.reference.stableKey] = entry
    }
    var addedCount = 0

    for (index, message) in messages.sorted(by: { $0.index < $1.index }).enumerated() {
        guard index < contexts.count else {
            continue
        }
        let reference = darkgramAISharedStoredReference(message: message, threadId: threadId)
        if byKey[reference.stableKey] == nil {
            byKey[reference.stableKey] = DarkgramAIDebateThreadEntry(reference: reference, context: contexts[index])
            addedCount += 1
        }
    }

    let updatedEntries = byKey.values.sorted(by: {
        if $0.context.timestamp != $1.context.timestamp {
            return $0.context.timestamp < $1.context.timestamp
        } else {
            return $0.reference.stableKey < $1.reference.stableKey
        }
    })
    SGSimpleSettings.shared.setDarkgramAIDebateThreadEntries(peerId: peerId, threadId: threadId, entries: updatedEntries)
    return addedCount
}

func darkgramAIRemoveMessagesFromDebateThread(
    peerId: PeerId,
    threadId: Int64?,
    messages: [Message]
) -> Int {
    let currentEntries = SGSimpleSettings.shared.darkgramAIDebateThreadEntries(peerId: peerId, threadId: threadId)
    let keysToRemove = Set(messages.map { darkgramAISharedStoredReference(message: $0, threadId: threadId).stableKey })
    let updatedEntries = currentEntries.filter { !keysToRemove.contains($0.reference.stableKey) }
    SGSimpleSettings.shared.setDarkgramAIDebateThreadEntries(peerId: peerId, threadId: threadId, entries: updatedEntries)
    return currentEntries.count - updatedEntries.count
}

func darkgramAIPresentComposePrompt(
    context: AccountContext,
    interfaceInteraction: ChatPanelInterfaceInteraction,
    chatPresentationInterfaceState: ChatPresentationInterfaceState
) {
    guard let controller = interfaceInteraction.chatController() as? ChatControllerImpl, let controllerInteraction = controller.controllerInteraction else {
        return
    }

    let snapshot = SGSimpleSettings.shared.darkgramAISettingsSnapshot
    guard snapshot.enabled, snapshot.composeButtonEnabled else {
        return
    }

    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode

    let prompt = promptController(
        context: context,
        text: "Darkgram.AI.Compose.Prompt.Title".i18n(lang),
        subtitle: "Darkgram.AI.Compose.Prompt.Subtitle".i18n(lang),
        value: nil,
        placeholder: "Darkgram.AI.Compose.Prompt.Placeholder".i18n(lang),
        characterLimit: 2000,
        displayCharacterLimit: true,
        apply: { value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return
            }

            let replyMessages: [Message]
            if snapshot.replyDraftingEnabled, let replyMessage = chatPresentationInterfaceState.replyMessage {
                replyMessages = [replyMessage]
            } else {
                replyMessages = []
            }

            let peerId = chatPresentationInterfaceState.chatLocation.peerId
            let threadId = chatPresentationInterfaceState.chatLocation.threadId
            let recentContextSignal = darkgramAISharedRecentContextSignal(
                context: context,
                chatLocation: chatPresentationInterfaceState.chatLocation,
                snapshot: snapshot
            )

            let storedDebateEntries: [DarkgramAIDebateThreadEntry]
            if let peerId, snapshot.debateThreadsEnabled {
                storedDebateEntries = SGSimpleSettings.shared.darkgramAIDebateThreadEntries(peerId: peerId, threadId: threadId)
            } else {
                storedDebateEntries = []
            }

            let _ = (recentContextSignal
            |> deliverOnMainQueue).start(next: { recentEntries in
                var aliasByPeerId: [PeerId: String] = [:]
                var nextAliasIndex = 1
                let selectedEntries = darkgramAISharedContextEntries(
                    messages: replyMessages,
                    accountPeerId: context.account.peerId,
                    presentationData: presentationData,
                    snapshot: snapshot,
                    aliasByPeerId: &aliasByPeerId,
                    nextAliasIndex: &nextAliasIndex
                )
                let debateEntries = darkgramAISharedDebateContextEntries(
                    entries: storedDebateEntries,
                    accountPeerId: context.account.peerId,
                    snapshot: snapshot,
                    aliasByPeerId: &aliasByPeerId,
                    nextAliasIndex: &nextAliasIndex
                )

                let task: DarkgramAITaskKind
                if !selectedEntries.isEmpty || !debateEntries.isEmpty {
                    task = .draftReply
                } else {
                    task = .draftMessage
                }

                darkgramAISharedPerformAfterLargeContextConfirmation(
                    context: context,
                    controllerInteraction: controllerInteraction,
                    selectedEntries: selectedEntries,
                    recentEntries: recentEntries,
                    debateEntries: debateEntries,
                    extraPrompt: value
                ) {
                    darkgramAISharedPerformRequest(
                        context: context,
                        controllerInteraction: controllerInteraction,
                        chatPresentationInterfaceState: chatPresentationInterfaceState,
                        request: DarkgramAIRequest(
                            task: task,
                            userPrompt: value,
                            selectedMessages: selectedEntries,
                            recentMessages: recentEntries,
                            debateThreadMessages: debateEntries
                        ),
                        overlayText: "Darkgram.AI.Compose.Prompt.Title".i18n(lang),
                        resultTitle: "Darkgram.AI.Result.ComposeTitle".i18n(lang),
                        onResponse: { response in
                            darkgramAISharedInsertIntoInput(controllerInteraction: controllerInteraction, text: response.text)
                            darkgramAISharedPresentInfo(
                                context: context,
                                controllerInteraction: controllerInteraction,
                                text: "Darkgram.AI.Compose.Inserted".i18n(lang)
                            )
                        }
                    )
                }
            })
        }
    )
    controllerInteraction.presentControllerInCurrent(prompt, nil)
}
