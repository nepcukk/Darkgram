import Foundation
import UIKit
import SGAI
import SGAIUI
import SGSimpleSettings
import SGStrings
import Postbox
import TelegramCore
import AccountContext
import ChatPresentationInterfaceState
import ChatControllerInteraction
import ContextUI
import Display
import OverlayStatusController
import PresentationDataUtils
import PromptUI
import SwiftSignalKit
import TelegramPresentationData

private let darkgramAILargeContextCharacterLimit = 6000

private func darkgramAIMessageMediaHint(message: Message, lang: String) -> String? {
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

private func darkgramAIMessageText(message: Message, lang: String) -> String {
    let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        return trimmed
    }
    return darkgramAIMessageMediaHint(message: message, lang: lang) ?? ""
}

private func darkgramAIContextEntries(
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
                text: darkgramAIMessageText(message: message, lang: lang),
                mediaHint: darkgramAIMessageMediaHint(message: message, lang: lang)
            )
        }
}

private func darkgramAIPresentError(
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

private func darkgramAIInsertIntoInput(controllerInteraction: ChatControllerInteraction, text: String) {
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

private func darkgramAIPresentResult(
    context: AccountContext,
    controllerInteraction: ChatControllerInteraction,
    title: String,
    response: DarkgramAIResponse
) {
    controllerInteraction.presentControllerInCurrent(
        darkgramAIResultController(
            context: context,
            title: title,
            text: response.text,
            copyTitle: "Darkgram.AI.Common.Copy".i18n(context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode),
            insertTitle: "Darkgram.AI.Result.Insert".i18n(context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode),
            onInsert: {
                darkgramAIInsertIntoInput(controllerInteraction: controllerInteraction, text: response.text)
            }
        ),
        ViewControllerPresentationArguments(presentationAnimation: .modalSheet)
    )
}

private func darkgramAIPerformRequest(
    context: AccountContext,
    controllerInteraction: ChatControllerInteraction,
    chatPresentationInterfaceState: ChatPresentationInterfaceState,
    request: DarkgramAIRequest,
    overlayText: String,
    resultTitle: String
) {
    let snapshot = SGSimpleSettings.shared.darkgramAISettingsSnapshot

    let overlayController = OverlayStatusController(theme: chatPresentationInterfaceState.theme, type: .loading(cancelled: nil))
    controllerInteraction.presentGlobalOverlayController(overlayController, nil)

    let _ = (DarkgramAIService.shared.perform(request: request, snapshot: snapshot)
    |> deliverOnMainQueue).start(next: { response in
        overlayController.dismiss()
        darkgramAIPresentResult(
            context: context,
            controllerInteraction: controllerInteraction,
            title: resultTitle,
            response: response
        )
    }, error: { error in
        overlayController.dismiss()
        darkgramAIPresentError(
            context: context,
            controllerInteraction: controllerInteraction,
            title: overlayText,
            error: error
        )
    })
}

private func darkgramAIContextCharacterCount(entries: [DarkgramAIMessageContextEntry], extraPrompt: String = "") -> Int {
    return entries.reduce(extraPrompt.count) { partial, entry in
        partial + entry.authorName.count + entry.text.count + (entry.mediaHint?.count ?? 0) + 32
    }
}

private func darkgramAIPerformAfterLargeContextConfirmation(
    context: AccountContext,
    controllerInteraction: ChatControllerInteraction,
    chatPresentationInterfaceState: ChatPresentationInterfaceState,
    entries: [DarkgramAIMessageContextEntry],
    extraPrompt: String = "",
    perform: @escaping () -> Void
) {
    let snapshot = SGSimpleSettings.shared.darkgramAISettingsSnapshot
    guard snapshot.confirmLargeContext else {
        perform()
        return
    }

    let totalCharacterCount = darkgramAIContextCharacterCount(entries: entries, extraPrompt: extraPrompt)
    guard totalCharacterCount > darkgramAILargeContextCharacterLimit else {
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

func darkgramAppendAIContextMenuActions(
    sgActions: inout [ContextMenuItem],
    context: AccountContext,
    controllerInteraction: ChatControllerInteraction,
    chatPresentationInterfaceState: ChatPresentationInterfaceState,
    messages: [Message]
) {
    let snapshot = SGSimpleSettings.shared.darkgramAISettingsSnapshot
    guard snapshot.enabled, DarkgramAIService.shared.isConfigured(snapshot: snapshot) else {
        return
    }

    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode
    let entries = darkgramAIContextEntries(
        messages: messages,
        accountPeerId: context.account.peerId,
        presentationData: presentationData,
        snapshot: snapshot
    )
    guard !entries.isEmpty else {
        return
    }
    let dialogPeerId = chatPresentationInterfaceState.chatLocation.peerId ?? messages[0].id.peerId
    let dialogThreadId = chatPresentationInterfaceState.chatLocation.threadId

    if snapshot.messageSummariesEnabled {
        sgActions.append(.action(ContextMenuActionItem(
            text: "Darkgram.AI.ContextMenu.SummarizeMessages".i18n(lang),
            icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Translate"), color: theme.actionSheet.primaryTextColor)
            },
            action: { _, f in
                f(.dismissWithoutContent)
                Queue.mainQueue().after(0.05) {
                    darkgramAIPerformAfterLargeContextConfirmation(
                        context: context,
                        controllerInteraction: controllerInteraction,
                        chatPresentationInterfaceState: chatPresentationInterfaceState,
                        entries: entries
                    ) {
                        darkgramAIPerformRequest(
                            context: context,
                            controllerInteraction: controllerInteraction,
                            chatPresentationInterfaceState: chatPresentationInterfaceState,
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
                }
            }
        )))
    }

    sgActions.append(.action(ContextMenuActionItem(
        text: "Darkgram.AI.ContextMenu.CustomPrompt".i18n(lang),
        icon: { theme in
            generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Message"), color: theme.actionSheet.primaryTextColor)
        },
        action: { _, f in
            f(.dismissWithoutContent)
            Queue.mainQueue().after(0.05) {
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
                        darkgramAIPerformAfterLargeContextConfirmation(
                            context: context,
                            controllerInteraction: controllerInteraction,
                            chatPresentationInterfaceState: chatPresentationInterfaceState,
                            entries: entries,
                            extraPrompt: value
                        ) {
                            darkgramAIPerformRequest(
                                context: context,
                                controllerInteraction: controllerInteraction,
                                chatPresentationInterfaceState: chatPresentationInterfaceState,
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
                controllerInteraction.presentControllerInCurrent(controller, nil)
            }
        }
    )))

    if snapshot.voiceSummariesEnabled, messages.count == 1, darkgramAISharedIsVoiceSummarizable(message: messages[0]) {
        let voiceMessage = messages[0]
        sgActions.append(.action(ContextMenuActionItem(
            text: "Darkgram.AI.ContextMenu.SummarizeVoice".i18n(lang),
            icon: { theme in
                generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Translate"), color: theme.actionSheet.primaryTextColor)
            },
            action: { _, f in
                f(.dismissWithoutContent)
                Queue.mainQueue().after(0.05) {
                    darkgramAISummarizeVoiceMessage(
                        context: context,
                        controllerInteraction: controllerInteraction,
                        chatPresentationInterfaceState: chatPresentationInterfaceState,
                        message: voiceMessage
                    )
                }
            }
        )))
    }

    if snapshot.debateThreadsEnabled {
        let storedEntries = SGSimpleSettings.shared.darkgramAIDebateThreadEntries(peerId: dialogPeerId, threadId: dialogThreadId)
        let selectedReferenceKeys = Set(messages.map { darkgramAISharedStoredReference(message: $0, threadId: dialogThreadId).stableKey })
        let storedReferenceKeys = Set(storedEntries.map { $0.reference.stableKey })
        let canAddSelected = !selectedReferenceKeys.isSubset(of: storedReferenceKeys)
        let canRemoveSelected = !selectedReferenceKeys.intersection(storedReferenceKeys).isEmpty

        if canAddSelected {
            sgActions.append(.action(ContextMenuActionItem(
                text: "Darkgram.AI.ContextMenu.Debate.Add".i18n(lang),
                icon: { theme in
                    generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Forward"), color: theme.actionSheet.primaryTextColor)
                },
                action: { _, f in
                    f(.dismissWithoutContent)
                    let addedCount = darkgramAIAddMessagesToDebateThread(
                        context: context,
                        peerId: dialogPeerId,
                        threadId: dialogThreadId,
                        messages: messages
                    )
                    if addedCount > 0 {
                        controllerInteraction.displayUndo(.info(
                            title: nil,
                            text: String(format: "Darkgram.AI.ContextMenu.Debate.Added".i18n(lang), addedCount),
                            timeout: nil,
                            customUndoText: nil
                        ))
                    }
                }
            )))
        }

        if canRemoveSelected {
            sgActions.append(.action(ContextMenuActionItem(
                text: "Darkgram.AI.ContextMenu.Debate.Remove".i18n(lang),
                icon: { theme in
                    generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.actionSheet.primaryTextColor)
                },
                action: { _, f in
                    f(.dismissWithoutContent)
                    let removedCount = darkgramAIRemoveMessagesFromDebateThread(
                        peerId: dialogPeerId,
                        threadId: dialogThreadId,
                        messages: messages
                    )
                    if removedCount > 0 {
                        controllerInteraction.displayUndo(.info(
                            title: nil,
                            text: String(format: "Darkgram.AI.ContextMenu.Debate.Removed".i18n(lang), removedCount),
                            timeout: nil,
                            customUndoText: nil
                        ))
                    }
                }
            )))
        }

        if !storedEntries.isEmpty {
            sgActions.append(.action(ContextMenuActionItem(
                text: "Darkgram.AI.ContextMenu.Debate.Clear".i18n(lang),
                textColor: .destructive,
                icon: { theme in
                    generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.actionSheet.destructiveActionTextColor)
                },
                action: { _, f in
                    f(.dismissWithoutContent)
                    SGSimpleSettings.shared.clearDarkgramAIDebateThread(peerId: dialogPeerId, threadId: dialogThreadId)
                    controllerInteraction.displayUndo(.info(
                        title: nil,
                        text: "Darkgram.AI.ContextMenu.Debate.Cleared".i18n(lang),
                        timeout: nil,
                        customUndoText: nil
                    ))
                }
            )))
        }
    }
}
