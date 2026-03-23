import Foundation
import SGAI
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import Display
import Postbox
import TelegramCore
import AccountContext
import ChatPresentationInterfaceState
import ChatControllerInteraction
import PromptUI
import TelegramPresentationData
import PresentationDataUtils
import TelegramStringFormatting
import UndoUI

private let darkgramAIComposeRecentContextLimit = 12
private let darkgramAIComposeLargeContextCharacterLimit = 6000

private func darkgramAIComposeMessageMediaHint(message: Message, lang: String) -> String? {
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

private func darkgramAIComposeMessageText(message: Message, lang: String) -> String {
    let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        return trimmed
    }
    return darkgramAIComposeMessageMediaHint(message: message, lang: lang) ?? ""
}

private func darkgramAIComposeContextEntries(
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
    let sortedMessages = messages.sorted(by: { lhs, rhs in
        lhs.index < rhs.index
    })
    var result: [DarkgramAIMessageContextEntry] = []
    result.reserveCapacity(sortedMessages.count)
    for message in sortedMessages {
        result.append(DarkgramAIMessageContextEntry(
            authorName: authorName(for: message),
            timestamp: Int64(message.timestamp),
            isOutgoing: !message.effectivelyIncoming(accountPeerId),
            text: darkgramAIComposeMessageText(message: message, lang: lang),
            mediaHint: darkgramAIComposeMessageMediaHint(message: message, lang: lang)
        ))
    }
    return result
}

private func darkgramAIComposeRecentContextSignal(
    context: AccountContext,
    chatLocation: ChatLocation,
    snapshot: DarkgramAISettingsSnapshot
) -> Signal<[DarkgramAIMessageContextEntry], NoError> {
    guard snapshot.allowRecentChatContext else {
        return .single([])
    }

    let contextHolder = Atomic<ChatLocationContextHolder?>(value: nil)
    return context.account.viewTracker.aroundMessageHistoryViewForLocation(
        context.chatLocationInput(for: chatLocation, contextHolder: contextHolder),
        index: .upperBound,
        anchorIndex: .upperBound,
        count: darkgramAIComposeRecentContextLimit,
        fixedCombinedReadStates: nil
    )
    |> take(1)
    |> map { view, _, _ -> [DarkgramAIMessageContextEntry] in
        var messages: [Message] = []
        messages.reserveCapacity(view.entries.count)
        for entry in view.entries {
            messages.append(entry.message)
        }
        return darkgramAIComposeContextEntries(
            messages: messages,
            accountPeerId: context.account.peerId,
            presentationData: context.sharedContext.currentPresentationData.with { $0 },
            snapshot: snapshot
        )
    }
}

private func darkgramAIComposeInsertIntoInput(controllerInteraction: ChatControllerInteraction, text: String) {
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

private func darkgramAIComposeDisplayInfo(
    controllerInteraction: ChatControllerInteraction,
    text: String
) {
    controllerInteraction.displayUndo(.info(title: nil, text: text, timeout: nil, customUndoText: nil))
}

private func darkgramAIComposeCharacterCount(
    selectedEntries: [DarkgramAIMessageContextEntry],
    recentEntries: [DarkgramAIMessageContextEntry],
    debateEntries: [DarkgramAIMessageContextEntry],
    extraPrompt: String
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

private func darkgramAIComposeStoredDebateEntries(
    peerId: PeerId?,
    threadId: Int64?,
    snapshot: DarkgramAISettingsSnapshot
) -> [DarkgramAIDebateThreadEntry] {
    guard snapshot.debateThreadsEnabled, let peerId else {
        return []
    }
    return SGSimpleSettings.shared.darkgramAIDebateThreadEntries(peerId: peerId, threadId: threadId)
}

private func darkgramAIComposeErrorText(lang: String, error: DarkgramAIError) -> String {
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

private func darkgramAIComposePresentLargeContextAlert(
    context: AccountContext,
    chatControllerInteraction: ChatControllerInteraction,
    presentationData: PresentationData,
    lang: String,
    totalCharacterCount: Int,
    performRequest: @escaping () -> Void
) {
    let title = "Darkgram.AI.ContextMenu.ConfirmLargeContext.Title".i18n(lang)
    let text = String(format: "Darkgram.AI.ContextMenu.ConfirmLargeContext.Text".i18n(lang), totalCharacterCount)
    let actions = [
        TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
        TextAlertAction(type: .defaultAction, title: "Darkgram.AI.Common.Continue".i18n(lang), action: performRequest)
    ]
    let controller = textAlertController(
        context: context,
        title: title,
        text: text,
        actions: actions
    )
    chatControllerInteraction.presentControllerInCurrent(controller, nil)
}

private func darkgramAIComposeRequestTask(
    selectedEntries: [DarkgramAIMessageContextEntry],
    debateEntries: [DarkgramAIMessageContextEntry]
) -> DarkgramAITaskKind {
    if !selectedEntries.isEmpty || !debateEntries.isEmpty {
        return .draftReply
    } else {
        return .draftMessage
    }
}

private func darkgramAIComposePerformRequest(
    context: AccountContext,
    chatControllerInteraction: ChatControllerInteraction,
    snapshot: DarkgramAISettingsSnapshot,
    lang: String,
    prompt: String,
    selectedEntries: [DarkgramAIMessageContextEntry],
    recentEntries: [DarkgramAIMessageContextEntry],
    debateEntries: [DarkgramAIMessageContextEntry]
) {
    let request = DarkgramAIRequest(
        task: darkgramAIComposeRequestTask(selectedEntries: selectedEntries, debateEntries: debateEntries),
        userPrompt: prompt,
        selectedMessages: selectedEntries,
        recentMessages: recentEntries,
        debateThreadMessages: debateEntries
    )

    let _ = (DarkgramAIService.shared.perform(request: request, snapshot: snapshot)
    |> deliverOnMainQueue).start(next: { response in
        darkgramAIComposeInsertIntoInput(controllerInteraction: chatControllerInteraction, text: response.text)
        darkgramAIComposeDisplayInfo(
            controllerInteraction: chatControllerInteraction,
            text: "Darkgram.AI.Compose.Inserted".i18n(lang)
        )
    }, error: { error in
        darkgramAIComposeDisplayInfo(
            controllerInteraction: chatControllerInteraction,
            text: darkgramAIComposeErrorText(lang: lang, error: error)
        )
    })
}

private func darkgramAIComposeHandlePrompt(
    context: AccountContext,
    chatControllerInteraction: ChatControllerInteraction,
    chatPresentationInterfaceState: ChatPresentationInterfaceState,
    snapshot: DarkgramAISettingsSnapshot,
    presentationData: PresentationData,
    lang: String,
    promptValue: String
) {
    let replyMessages: [Message]
    if snapshot.replyDraftingEnabled, let replyMessage = chatPresentationInterfaceState.replyMessage {
        replyMessages = [replyMessage]
    } else {
        replyMessages = []
    }

    let peerId = chatPresentationInterfaceState.chatLocation.peerId
    let threadId = chatPresentationInterfaceState.chatLocation.threadId
    let storedDebateEntries = darkgramAIComposeStoredDebateEntries(
        peerId: peerId,
        threadId: threadId,
        snapshot: snapshot
    )

    let selectedEntries = darkgramAIComposeContextEntries(
        messages: replyMessages,
        accountPeerId: context.account.peerId,
        presentationData: presentationData,
        snapshot: snapshot
    )
    var debateEntries: [DarkgramAIMessageContextEntry] = []
    debateEntries.reserveCapacity(storedDebateEntries.count)
    for storedEntry in storedDebateEntries {
        debateEntries.append(storedEntry.context)
    }

    let recentContextSignal = darkgramAIComposeRecentContextSignal(
        context: context,
        chatLocation: chatPresentationInterfaceState.chatLocation,
        snapshot: snapshot
    )
    |> deliverOnMainQueue

    let _ = recentContextSignal.start(next: { recentEntries in
        darkgramAIComposeHandleRecentEntries(
            context: context,
            chatControllerInteraction: chatControllerInteraction,
            snapshot: snapshot,
            presentationData: presentationData,
            lang: lang,
            promptValue: promptValue,
            selectedEntries: selectedEntries,
            recentEntries: recentEntries,
            debateEntries: debateEntries
        )
    })
}

private func darkgramAIComposeHandleRecentEntries(
    context: AccountContext,
    chatControllerInteraction: ChatControllerInteraction,
    snapshot: DarkgramAISettingsSnapshot,
    presentationData: PresentationData,
    lang: String,
    promptValue: String,
    selectedEntries: [DarkgramAIMessageContextEntry],
    recentEntries: [DarkgramAIMessageContextEntry],
    debateEntries: [DarkgramAIMessageContextEntry]
) {
    let totalCharacterCount = darkgramAIComposeCharacterCount(
        selectedEntries: selectedEntries,
        recentEntries: recentEntries,
        debateEntries: debateEntries,
        extraPrompt: promptValue
    )

    let performRequest: () -> Void = {
        darkgramAIComposePerformRequest(
            context: context,
            chatControllerInteraction: chatControllerInteraction,
            snapshot: snapshot,
            lang: lang,
            prompt: promptValue,
            selectedEntries: selectedEntries,
            recentEntries: recentEntries,
            debateEntries: debateEntries
        )
    }

    if snapshot.confirmLargeContext, totalCharacterCount > darkgramAIComposeLargeContextCharacterLimit {
        darkgramAIComposePresentLargeContextAlert(
            context: context,
            chatControllerInteraction: chatControllerInteraction,
            presentationData: presentationData,
            lang: lang,
            totalCharacterCount: totalCharacterCount,
            performRequest: performRequest
        )
    } else {
        performRequest()
    }
}

private func darkgramAIComposeApplyClosure(
    context: AccountContext,
    chatControllerInteraction: ChatControllerInteraction,
    chatPresentationInterfaceState: ChatPresentationInterfaceState,
    snapshot: DarkgramAISettingsSnapshot,
    presentationData: PresentationData,
    lang: String
) -> (String?) -> Void {
    return { value in
        guard let promptValue = value?.trimmingCharacters(in: .whitespacesAndNewlines), !promptValue.isEmpty else {
            return
        }
        darkgramAIComposeHandlePrompt(
            context: context,
            chatControllerInteraction: chatControllerInteraction,
            chatPresentationInterfaceState: chatPresentationInterfaceState,
            snapshot: snapshot,
            presentationData: presentationData,
            lang: lang,
            promptValue: promptValue
        )
    }
}

func darkgramAIPresentComposePrompt(
    context: AccountContext,
    chatControllerInteraction: ChatControllerInteraction,
    chatPresentationInterfaceState: ChatPresentationInterfaceState
) {
    let snapshot = SGSimpleSettings.shared.darkgramAISettingsSnapshot
    guard snapshot.enabled, snapshot.composeButtonEnabled else {
        return
    }

    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode
    let title = "Darkgram.AI.Compose.Prompt.Title".i18n(lang)
    let subtitle = "Darkgram.AI.Compose.Prompt.Subtitle".i18n(lang)
    let placeholder = "Darkgram.AI.Compose.Prompt.Placeholder".i18n(lang)
    let apply = darkgramAIComposeApplyClosure(
        context: context,
        chatControllerInteraction: chatControllerInteraction,
        chatPresentationInterfaceState: chatPresentationInterfaceState,
        snapshot: snapshot,
        presentationData: presentationData,
        lang: lang
    )

    let controller = promptController(
        context: context,
        text: title,
        subtitle: subtitle,
        value: nil,
        placeholder: placeholder,
        characterLimit: 2000,
        displayCharacterLimit: true,
        apply: apply
    )

    chatControllerInteraction.presentControllerInCurrent(controller, nil)
}
