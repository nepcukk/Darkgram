import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AlertUI
import SGStrings
import SGSimpleSettings

private struct DarkgramDialogDeletedHistoryArguments {
    let context: AccountContext
    let openItem: (Int32) -> Void
}

private enum DarkgramDialogDeletedHistorySection: Int32 {
    case overview
    case messages
    case empty
}

private struct DarkgramDialogDeletedHistoryItem: Equatable {
    let stableId: Int32
    let message: Message
    let peer: Peer?
    let title: String
    let detailText: String
    let fullText: String

    static func == (lhs: DarkgramDialogDeletedHistoryItem, rhs: DarkgramDialogDeletedHistoryItem) -> Bool {
        return lhs.stableId == rhs.stableId
            && lhs.message.id == rhs.message.id
            && lhs.peer?.id == rhs.peer?.id
            && lhs.title == rhs.title
            && lhs.detailText == rhs.detailText
            && lhs.fullText == rhs.fullText
    }
}

private enum DarkgramDialogDeletedHistoryEntry: ItemListNodeEntry, Equatable {
    case header(Int32, DarkgramDialogDeletedHistorySection, String)
    case text(Int32, DarkgramDialogDeletedHistorySection, String)
    case item(DarkgramDialogDeletedHistoryItem)

    var section: ItemListSectionId {
        switch self {
        case let .header(_, section, _):
            return section.rawValue
        case let .text(_, section, _):
            return section.rawValue
        case .item:
            return DarkgramDialogDeletedHistorySection.messages.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(id, _, _):
            return id
        case let .text(id, _, _):
            return id
        case let .item(item):
            return item.stableId
        }
    }

    static func <(lhs: DarkgramDialogDeletedHistoryEntry, rhs: DarkgramDialogDeletedHistoryEntry) -> Bool {
        lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! DarkgramDialogDeletedHistoryArguments

        switch self {
        case let .header(_, _, text):
            return ItemListSectionHeaderItem(
                presentationData: presentationData,
                text: text,
                sectionId: self.section
            )
        case let .text(_, _, text):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .markdown(text),
                sectionId: self.section
            )
        case let .item(item):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: item.peer == nil ? UIImage(bundleImageName: "Chat/Context Menu/Delete")?.precomposed() : nil,
                context: item.peer == nil ? nil : arguments.context,
                iconPeer: item.peer.flatMap { EnginePeer($0) },
                title: item.title,
                titleFont: .regular,
                label: item.detailText,
                labelStyle: .multilineDetailText,
                sgLabelMaximumNumberOfLines: 4,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .arrow,
                action: {
                    arguments.openItem(item.stableId)
                }
            )
        }
    }
}

private func darkgramDialogDeletedHistoryTimestampString(_ timestampMs: Int64, lang: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: lang == "ru" ? "ru_RU" : "en_US_POSIX")
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter.string(from: Date(timeIntervalSince1970: Double(timestampMs) / 1000.0))
}

private func darkgramDialogDeletedHistoryContentText(message: Message, lang: String) -> String {
    let trimmedText = message.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    if !trimmedText.isEmpty {
        return trimmedText
    }

    for media in message.media {
        if media is TelegramMediaImage {
            return lang == "ru" ? "Фото" : "Photo"
        } else if let file = media as? TelegramMediaFile {
            if file.isInstantVideo {
                return lang == "ru" ? "Кружок" : "Round Video"
            }
            if file.isVoice {
                return lang == "ru" ? "Голосовое сообщение" : "Voice Message"
            }
            if file.isVideo {
                return lang == "ru" ? "Видео" : "Video"
            }
            if file.isMusic {
                return lang == "ru" ? "Аудио" : "Audio"
            }
            if let fileName = file.fileName, !fileName.isEmpty {
                return fileName
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

    return lang == "ru" ? "Сообщение без текста" : "Message without text"
}

private func darkgramDialogDeletedHistoryPreviewText(message: Message, lang: String) -> String {
    let content = darkgramDialogDeletedHistoryContentText(message: message, lang: lang)
    let singleLine = content.components(separatedBy: CharacterSet.newlines).joined(separator: " ")
    return String(singleLine.prefix(80))
}

private func darkgramDialogDeletedHistoryHasOpenableMedia(_ message: Message) -> Bool {
    for media in message.media {
        if media is TelegramMediaImage || media is TelegramMediaFile {
            return true
        }
    }
    return false
}

private func darkgramOpenDeletedHistoryMedia(
    context: AccountContext,
    message: Message,
    pushController: ((ViewController) -> Void)?,
    presentController: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
) -> Bool {
    let resolvedMessage = darkgramResolvedMediaMessage(accountBasePath: context.account.basePath, message: message)
    guard darkgramDialogDeletedHistoryHasOpenableMedia(resolvedMessage) else {
        return false
    }
    let gallery = context.sharedContext.makeGalleryController(context: context, source: .standaloneMessage(resolvedMessage, nil), streamSingleVideo: true, isPreview: true)
    if let pushController {
        pushController(gallery)
    } else {
        presentController?(gallery, nil)
    }
    return true
}

private func darkgramDialogDeletedHistoryPeerTitle(peer: Peer?, accountPeerId: PeerId, strings: PresentationStrings, lang: String) -> String {
    guard let peer else {
        return lang == "ru" ? "Неизвестно" : "Unknown"
    }
    if peer.id == accountPeerId {
        return strings.DialogList_SavedMessages
    }
    if let user = peer as? TelegramUser {
        if !user.nameOrPhone.isEmpty {
            return user.nameOrPhone
        }
        return user.username ?? (lang == "ru" ? "Пользователь" : "User")
    } else if let channel = peer as? TelegramChannel {
        return channel.title
    } else if let group = peer as? TelegramGroup {
        return group.title
    } else if peer is TelegramSecretChat {
        return lang == "ru" ? "Секретный чат" : "Secret Chat"
    } else {
        return lang == "ru" ? "Чат" : "Chat"
    }
}

private func darkgramDialogDeletedHistoryItems(
    context: AccountContext,
    presentationData: PresentationData,
    peerId: PeerId,
    threadId: Int64?
) -> [DarkgramDialogDeletedHistoryItem] {
    let lang = presentationData.strings.baseLanguageCode
    let deletedEntries = darkgramDialogDeletedEntries(
        accountBasePath: context.account.basePath,
        peerId: peerId,
        threadId: threadId,
        limit: 2048
    ).sorted(by: { $0.recordedAt > $1.recordedAt })

    return deletedEntries.enumerated().map { index, entry in
        let authorTitle = darkgramDialogDeletedHistoryPeerTitle(
            peer: entry.message.author,
            accountPeerId: context.account.peerId,
            strings: presentationData.strings,
            lang: lang
        )
        let sentAt = darkgramDialogDeletedHistoryTimestampString(Int64(entry.message.timestamp) * 1000, lang: lang)
        let deletedAt = darkgramDialogDeletedHistoryTimestampString(entry.recordedAt, lang: lang)
        let previewText = darkgramDialogDeletedHistoryPreviewText(message: entry.message, lang: lang)
        let bodyText = darkgramDialogDeletedHistoryContentText(message: entry.message, lang: lang)

        let detailText: String
        let fullText: String
        if lang == "ru" {
            detailText = "От: \(authorTitle)\nОтправлено: \(sentAt)\nУдалено: \(deletedAt)"
            fullText = "От: \(authorTitle)\nОтправлено: \(sentAt)\nУдалено: \(deletedAt)\n\n\(bodyText)"
        } else {
            detailText = "From: \(authorTitle)\nSent: \(sentAt)\nDeleted: \(deletedAt)"
            fullText = "From: \(authorTitle)\nSent: \(sentAt)\nDeleted: \(deletedAt)\n\n\(bodyText)"
        }

        return DarkgramDialogDeletedHistoryItem(
            stableId: 1000 + Int32(index),
            message: entry.message,
            peer: entry.message.author,
            title: previewText,
            detailText: detailText,
            fullText: fullText
        )
    }
}

private func darkgramDialogDeletedHistoryEntries(
    presentationData: PresentationData,
    title: String,
    items: [DarkgramDialogDeletedHistoryItem]
) -> [DarkgramDialogDeletedHistoryEntry] {
    let lang = presentationData.strings.baseLanguageCode
    var entries: [DarkgramDialogDeletedHistoryEntry] = []

    entries.append(.header(0, .overview, "Darkgram.ChatDeleted.Overview.Header".i18n(lang)))
    entries.append(.text(1, .overview, (lang == "ru" ? "История удаленных сообщений для **\(title)**. Здесь сохраняется отдельная лента удаленок по текущему диалогу." : "Deleted-message history for **\(title)**. This is a separate Darkgram feed for the current dialog.")))

    if items.isEmpty {
        entries.append(.header(10, .empty, "Darkgram.ChatDeleted.Messages.Header".i18n(lang)))
        entries.append(.text(11, .empty, "Darkgram.ChatDeleted.Empty".i18n(lang)))
    } else {
        entries.append(.header(10, .messages, "Darkgram.ChatDeleted.Messages.Header".i18n(lang)))
        entries.append(contentsOf: items.map { .item($0) })
    }

    return entries
}

public func darkgramDialogDeletedHistoryController(
    context: AccountContext,
    peerId: PeerId,
    threadId: Int64?,
    title: String,
    latestRecordedAt: Int64,
    onMarkedSeen: (() -> Void)? = nil,
    replyToMessage: ((Message) -> Void)? = nil
) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let items = darkgramDialogDeletedHistoryItems(
        context: context,
        presentationData: presentationData,
        peerId: peerId,
        threadId: threadId
    )

    let arguments = DarkgramDialogDeletedHistoryArguments(
        context: context,
        openItem: { stableId in
            guard let item = items.first(where: { $0.stableId == stableId }) else {
                return
            }
            let canReply = SGSimpleSettings.shared.darkgramReplyToDeletedMessagesEnabled && replyToMessage != nil
            if canReply {
                let lang = presentationData.strings.baseLanguageCode
                let actionSheet = ActionSheetController(presentationData: presentationData)
                var actionItems: [ActionSheetItem] = [
                    ActionSheetButtonItem(title: "Darkgram.ChatDeleted.ActionReply".i18n(lang), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        replyToMessage?(item.message)
                    })
                ]
                if darkgramDialogDeletedHistoryHasOpenableMedia(item.message) {
                    actionItems.append(ActionSheetButtonItem(title: "Darkgram.Deleted.OpenMedia".i18n(lang), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        _ = darkgramOpenDeletedHistoryMedia(
                            context: context,
                            message: item.message,
                            pushController: pushControllerImpl,
                            presentController: presentControllerImpl
                        )
                    }))
                }
                actionItems.append(ActionSheetButtonItem(title: "Darkgram.ChatDeleted.ActionShowText".i18n(lang), color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    presentControllerImpl?(textAlertController(
                        context: context,
                        title: item.title,
                        text: item.fullText,
                        actions: [
                            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
                        ]
                    ), ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                }))
                actionItems.append(ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                }))
                actionSheet.setItemGroups([
                    ActionSheetItemGroup(items: [
                        ActionSheetTextItem(title: item.title)
                    ]),
                    ActionSheetItemGroup(items: actionItems)
                ])
                presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                return
            }
            if darkgramOpenDeletedHistoryMedia(
                context: context,
                message: item.message,
                pushController: pushControllerImpl,
                presentController: presentControllerImpl
            ) {
                return
            }
            presentControllerImpl?(textAlertController(
                context: context,
                title: item.title,
                text: item.fullText,
                actions: [
                    TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
                ]
            ), ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
        }
    )

    let entries = darkgramDialogDeletedHistoryEntries(
        presentationData: presentationData,
        title: title,
        items: items
    )
    let controllerState = ItemListControllerState(
        presentationData: ItemListPresentationData(presentationData),
        title: .text("Darkgram.ChatDeleted.Title".i18n(presentationData.strings.baseLanguageCode)),
        leftNavigationButton: nil,
        rightNavigationButton: nil,
        backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
    )
    let listState = ItemListNodeState(
        presentationData: ItemListPresentationData(presentationData),
        entries: entries,
        style: .blocks,
        ensureVisibleItemTag: nil,
        initialScrollToItem: nil
    )
    let signal = Signal<(ItemListControllerState, (ItemListNodeState, Any)), NoError>.single((controllerState, (listState, arguments)))

    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { firstTime in
        guard firstTime, latestRecordedAt > 0 else {
            return
        }
        Queue.mainQueue().justDispatch {
            SGSimpleSettings.shared.markDarkgramDeletedHistorySeen(
                peerId: peerId,
                threadId: threadId,
                recordedAt: latestRecordedAt
            )
            onMarkedSeen?()
        }
    }
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    return controller
}
