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
import Display
import PromptUI
import OverlayStatusController
import PresentationDataUtils
import TelegramPresentationData
import ChatPresentationInterfaceState
import ChatControllerInteraction

private let darkgramAISelectionLargeContextCharacterLimit = 6000

private func darkgramAISelectionMediaHint(message: Message, lang: String) -> String? {
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
        }
    }
    return nil
}

private func darkgramAISelectionText(message: Message, lang: String) -> String {
    let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        return trimmed
    }
    return darkgramAISelectionMediaHint(message: message, lang: lang) ?? ""
}

private func darkgramAISelectionEntries(
    messages: [Message],
    accountPeerId: PeerId,
    presentationData: PresentationData,
    snapshot: DarkgramAISettingsSnapshot
) -> [DarkgramAIMessageContextEntry] {
    var aliasByPeerId: [PeerId: String] = [:]
    var nextAliasIndex = 1

    func authorName(for message: Message) -> String {
        let isOutgoing = !message.effectivelyIncoming(accountPeerId)
        if isOutgoing {
            return "You"
        }

        let peerId = message.author?.id ?? message.id.peerId
        if snapshot.redactUsernames {
            if let existing = aliasByPeerId[peerId] {
                return existing
            }
            let alias = "Participant \(nextAliasIndex)"
            nextAliasIndex += 1
            aliasByPeerId[peerId] = alias
            return alias
        }

        if let author = message.author {
            return EnginePeer(author).displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        } else if let peer = message.peers[peerId] {
            return EnginePeer(peer).displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        } else {
            return "Unknown"
        }
    }

    let lang = presentationData.strings.baseLanguageCode
    return messages
        .sorted(by: { $0.index < $1.index })
        .map { message in
            DarkgramAIMessageContextEntry(
                authorName: authorName(for: message),
                timestamp: Int64(message.timestamp),
                isOutgoing: !message.effectivelyIncoming(accountPeerId),
                text: darkgramAISelectionText(message: message, lang: lang),
                mediaHint: darkgramAISelectionMediaHint(message: message, lang: lang)
            )
        }
}

private func darkgramAISelectionStoredReference(message: Message, threadId: Int64?) -> DarkgramAIStoredMessageReference {
    return DarkgramAIStoredMessageReference(
        peerId: message.id.peerId.toInt64(),
        namespace: Int32(message.id.namespace),
        id: message.id.id,
        threadId: threadId ?? message.threadId
    )
}

private func darkgramAISelectionInsertIntoInput(
    chatControllerInteraction: ChatControllerInteraction,
    text: String
) {
    chatControllerInteraction.updateInputState { current in
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

private func darkgramAISelectionPresentResult(
    context: AccountContext,
    chatControllerInteraction: ChatControllerInteraction,
    title: String,
    response: DarkgramAIResponse
) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode

    chatControllerInteraction.presentControllerInCurrent(
        darkgramAIResultController(
            context: context,
            title: title,
            text: response.text,
            copyTitle: "Darkgram.AI.Common.Copy".i18n(lang),
            insertTitle: "Darkgram.AI.Result.Insert".i18n(lang),
            onInsert: {
                darkgramAISelectionInsertIntoInput(chatControllerInteraction: chatControllerInteraction, text: response.text)
            }
        ),
        ViewControllerPresentationArguments(presentationAnimation: .modalSheet)
    )
}

private func darkgramAISelectionErrorText(lang: String, error: DarkgramAIError) -> String {
    switch error {
    case .providerNotConfigured:
        return "Darkgram.AI.Error.NotConfigured".i18n(lang)
    case .emptyInput:
        return "Darkgram.AI.Error.EmptyInput".i18n(lang)
    case .emptyResult:
        return "Darkgram.AI.Error.EmptyResult".i18n(lang)
    case let .providerRejected(message):
        return String(format: "Darkgram.AI.Error.ProviderRejected".i18n(lang), message)
    case let .transport(message):
        return String(format: "Darkgram.AI.Error.Transport".i18n(lang), message)
    case .invalidResponse:
        return "Darkgram.AI.Error.InvalidResponse".i18n(lang)
    }
}

private func darkgramAISelectionPresentError(
    context: AccountContext,
    chatControllerInteraction: ChatControllerInteraction,
    title: String,
    error: DarkgramAIError
) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode
    chatControllerInteraction.presentControllerInCurrent(
        textAlertController(
            context: context,
            title: title,
            text: darkgramAISelectionErrorText(lang: lang, error: error),
            actions: [
                TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
            ]
        ),
        nil
    )
}

private func darkgramAISelectionCharacterCount(entries: [DarkgramAIMessageContextEntry], extraPrompt: String = "") -> Int {
    return entries.reduce(extraPrompt.count) { partial, entry in
        partial + entry.authorName.count + entry.text.count + (entry.mediaHint?.count ?? 0) + 32
    }
}

private func darkgramAISelectionPerformAfterLargeContextConfirmation(
    context: AccountContext,
    chatControllerInteraction: ChatControllerInteraction,
    entries: [DarkgramAIMessageContextEntry],
    extraPrompt: String = "",
    perform: @escaping () -> Void
) {
    let snapshot = SGSimpleSettings.shared.darkgramAISettingsSnapshot
    guard snapshot.confirmLargeContext else {
        perform()
        return
    }

    let totalCharacterCount = darkgramAISelectionCharacterCount(entries: entries, extraPrompt: extraPrompt)
    guard totalCharacterCount > darkgramAISelectionLargeContextCharacterLimit else {
        perform()
        return
    }

    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode
    chatControllerInteraction.presentControllerInCurrent(
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

private func darkgramAISelectionPerformRequest(
    context: AccountContext,
    chatControllerInteraction: ChatControllerInteraction,
    request: DarkgramAIRequest,
    overlayText: String,
    resultTitle: String
) {
    let snapshot = SGSimpleSettings.shared.darkgramAISettingsSnapshot
    let overlayController = OverlayStatusController(
        theme: context.sharedContext.currentPresentationData.with { $0 }.theme,
        type: .loading(cancelled: nil)
    )
    chatControllerInteraction.presentGlobalOverlayController(overlayController, nil)

    let _ = (DarkgramAIService.shared.perform(request: request, snapshot: snapshot)
    |> deliverOnMainQueue).start(next: { response in
        overlayController.dismiss()
        darkgramAISelectionPresentResult(
            context: context,
            chatControllerInteraction: chatControllerInteraction,
            title: resultTitle,
            response: response
        )
    }, error: { error in
        overlayController.dismiss()
        darkgramAISelectionPresentError(
            context: context,
            chatControllerInteraction: chatControllerInteraction,
            title: overlayText,
            error: error
        )
    })
}

private func darkgramAISelectionAddMessagesToDebateThread(
    peerId: PeerId,
    threadId: Int64?,
    messages: [Message],
    accountPeerId: PeerId,
    presentationData: PresentationData,
    snapshot: DarkgramAISettingsSnapshot
) -> Int {
    let contexts = darkgramAISelectionEntries(
        messages: messages,
        accountPeerId: accountPeerId,
        presentationData: presentationData,
        snapshot: snapshot
    )
    let currentEntries = SGSimpleSettings.shared.darkgramAIDebateThreadEntries(peerId: peerId, threadId: threadId)
    var byKey: [String: DarkgramAIDebateThreadEntry] = [:]
    for entry in currentEntries {
        byKey[entry.reference.stableKey] = entry
    }

    var addedCount = 0
    for (index, message) in messages.enumerated() where index < contexts.count {
        let reference = darkgramAISelectionStoredReference(message: message, threadId: threadId)
        if byKey[reference.stableKey] == nil {
            byKey[reference.stableKey] = DarkgramAIDebateThreadEntry(reference: reference, context: contexts[index])
            addedCount += 1
        }
    }

    SGSimpleSettings.shared.setDarkgramAIDebateThreadEntries(peerId: peerId, threadId: threadId, entries: byKey.values.sorted(by: { $0.reference.stableKey < $1.reference.stableKey }))
    return addedCount
}

private func darkgramAISelectionRemoveMessagesFromDebateThread(
    peerId: PeerId,
    threadId: Int64?,
    messages: [Message]
) -> Int {
    let currentEntries = SGSimpleSettings.shared.darkgramAIDebateThreadEntries(peerId: peerId, threadId: threadId)
    let removeKeys = Set(messages.map { darkgramAISelectionStoredReference(message: $0, threadId: threadId).stableKey })
    let nextEntries = currentEntries.filter { !removeKeys.contains($0.reference.stableKey) }
    let removedCount = currentEntries.count - nextEntries.count
    SGSimpleSettings.shared.setDarkgramAIDebateThreadEntries(peerId: peerId, threadId: threadId, entries: nextEntries)
    return removedCount
}

private func darkgramAIPresentSelectionPrompt(
    context: AccountContext,
    chatControllerInteraction: ChatControllerInteraction,
    entries: [DarkgramAIMessageContextEntry]
) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode
    let controller = promptController(
        context: context,
        text: "Darkgram.AI.ContextMenu.CustomPrompt.Title".i18n(lang),
        subtitle: String(format: "Darkgram.AI.ContextMenu.CustomPrompt.Subtitle".i18n(lang), entries.count),
        value: nil,
        placeholder: "Darkgram.AI.ContextMenu.CustomPrompt.Placeholder".i18n(lang),
        characterLimit: 2000,
        displayCharacterLimit: true,
        apply: { value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return
            }
            darkgramAISelectionPerformAfterLargeContextConfirmation(
                context: context,
                chatControllerInteraction: chatControllerInteraction,
                entries: entries,
                extraPrompt: value
            ) {
                darkgramAISelectionPerformRequest(
                    context: context,
                    chatControllerInteraction: chatControllerInteraction,
                    request: DarkgramAIRequest(
                        task: .askAboutMessages,
                        userPrompt: value,
                        selectedMessages: entries
                    ),
                    overlayText: "Darkgram.AI.ContextMenu.CustomPrompt".i18n(lang),
                    resultTitle: "Darkgram.AI.Result.CustomPromptTitle".i18n(lang)
                )
            }
        }
    )
    chatControllerInteraction.presentControllerInCurrent(controller, nil)
}

private func darkgramAIFetchSelectionMessages(
    context: AccountContext,
    selectedMessageIds: Set<MessageId>,
    completion: @escaping ([Message]) -> Void
) {
    let _ = (context.engine.data.get(
        EngineDataMap(
            Array(selectedMessageIds).map(TelegramEngine.EngineData.Item.Messages.Message.init)
        )
    )
    |> map { messages -> [Message] in
        messages.values.compactMap { $0?._asMessage() }.sorted(by: { $0.index < $1.index })
    }
    |> take(1)
    |> deliverOnMainQueue).startStandalone(next: completion)
}

func darkgramAIPresentSelectionActions(
    context: AccountContext,
    chatControllerInteraction: ChatControllerInteraction,
    presentationInterfaceState: ChatPresentationInterfaceState,
    selectedMessageIds: Set<MessageId>
) {
    let snapshot = SGSimpleSettings.shared.darkgramAISettingsSnapshot
    guard snapshot.enabled, DarkgramAIService.shared.isConfigured(snapshot: snapshot), !selectedMessageIds.isEmpty else {
        return
    }

    darkgramAIFetchSelectionMessages(context: context, selectedMessageIds: selectedMessageIds) { messages in
        guard !messages.isEmpty else {
            return
        }

        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        let entries = darkgramAISelectionEntries(
            messages: messages,
            accountPeerId: context.account.peerId,
            presentationData: presentationData,
            snapshot: snapshot
        )
        guard !entries.isEmpty else {
            return
        }

        let peerId = presentationInterfaceState.chatLocation.peerId ?? messages[0].id.peerId
        let threadId = presentationInterfaceState.chatLocation.threadId
        let storedEntries = SGSimpleSettings.shared.darkgramAIDebateThreadEntries(peerId: peerId, threadId: threadId)
        let selectedReferenceKeys = Set(messages.map { darkgramAISelectionStoredReference(message: $0, threadId: threadId).stableKey })
        let storedReferenceKeys = Set(storedEntries.map { $0.reference.stableKey })
        let canAddToDebate = snapshot.debateThreadsEnabled && !selectedReferenceKeys.isSubset(of: storedReferenceKeys)
        let canRemoveFromDebate = snapshot.debateThreadsEnabled && !selectedReferenceKeys.intersection(storedReferenceKeys).isEmpty

        var actions: [TextAlertAction] = []
        if snapshot.messageSummariesEnabled {
            actions.append(TextAlertAction(type: .genericAction, title: "Darkgram.AI.ContextMenu.SummarizeMessages".i18n(lang), action: {
                darkgramAISelectionPerformAfterLargeContextConfirmation(
                    context: context,
                    chatControllerInteraction: chatControllerInteraction,
                    entries: entries
                ) {
                    darkgramAISelectionPerformRequest(
                        context: context,
                        chatControllerInteraction: chatControllerInteraction,
                        request: DarkgramAIRequest(
                            task: .summarizeMessages,
                            userPrompt: "Summarize the selected messages and preserve the key facts and conclusions.",
                            selectedMessages: entries,
                            maxSummarySentences: 5
                        ),
                        overlayText: "Darkgram.AI.ContextMenu.SummarizeMessages".i18n(lang),
                        resultTitle: "Darkgram.AI.Result.SummaryTitle".i18n(lang)
                    )
                }
            }))
        }

        actions.append(TextAlertAction(type: .genericAction, title: "Darkgram.AI.ContextMenu.CustomPrompt".i18n(lang), action: {
            darkgramAIPresentSelectionPrompt(
                context: context,
                chatControllerInteraction: chatControllerInteraction,
                entries: entries
            )
        }))

        if canAddToDebate {
            actions.append(TextAlertAction(type: .genericAction, title: "Darkgram.AI.ContextMenu.Debate.Add".i18n(lang), action: {
                let addedCount = darkgramAISelectionAddMessagesToDebateThread(
                    peerId: peerId,
                    threadId: threadId,
                    messages: messages,
                    accountPeerId: context.account.peerId,
                    presentationData: presentationData,
                    snapshot: snapshot
                )
                if addedCount > 0 {
                    chatControllerInteraction.displayUndo(.info(
                        title: nil,
                        text: String(format: "Darkgram.AI.ContextMenu.Debate.Added".i18n(lang), addedCount),
                        timeout: nil,
                        customUndoText: nil
                    ))
                }
            }))
        }

        if canRemoveFromDebate {
            actions.append(TextAlertAction(type: .genericAction, title: "Darkgram.AI.ContextMenu.Debate.Remove".i18n(lang), action: {
                let removedCount = darkgramAISelectionRemoveMessagesFromDebateThread(
                    peerId: peerId,
                    threadId: threadId,
                    messages: messages
                )
                if removedCount > 0 {
                    chatControllerInteraction.displayUndo(.info(
                        title: nil,
                        text: String(format: "Darkgram.AI.ContextMenu.Debate.Removed".i18n(lang), removedCount),
                        timeout: nil,
                        customUndoText: nil
                    ))
                }
            }))
        }

        actions.append(TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_Cancel, action: {}))
        chatControllerInteraction.presentControllerInCurrent(
            textAlertController(
                context: context,
                title: "Darkgram AI",
                text: "",
                actions: actions
            ),
            nil
        )
    }
}
