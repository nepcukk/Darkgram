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
import SGStrings
import AppBundle

private struct DarkgramDeletedMessagesBrowserArguments {
    let context: AccountContext
    let openFilter: () -> Void
    let openItem: (Int32) -> Void
}

private enum DarkgramDeletedMessagesBrowserSection: Int32 {
    case overview
    case filters
    case messages
    case empty
}

private enum DarkgramDeletedMessagesTimeFilter: Int32, CaseIterable {
    case last24Hours
    case last7Days
    case last30Days
    case all
}

private struct DarkgramDeletedMessagesBrowserItem {
    let stableId: Int32
    let message: Message
    let peer: Peer?
    let title: String
    let detailText: String
    let detailTitle: String
}

private struct DarkgramDeletedMessagesBrowserState: Equatable {
    var filter: DarkgramDeletedMessagesTimeFilter
}

private enum DarkgramDeletedMessagesBrowserEntry: ItemListNodeEntry, Equatable {
    case accentHeader(Int32, DarkgramDeletedMessagesBrowserSection, String, DarkgramAccentBadge)
    case text(Int32, DarkgramDeletedMessagesBrowserSection, String)
    case filter(Int32, String, String)
    case item(DarkgramDeletedMessagesBrowserItem)

    var section: ItemListSectionId {
        switch self {
        case let .accentHeader(_, section, _, _):
            return section.rawValue
        case let .text(_, section, _):
            return section.rawValue
        case .filter:
            return DarkgramDeletedMessagesBrowserSection.filters.rawValue
        case .item:
            return DarkgramDeletedMessagesBrowserSection.messages.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case let .accentHeader(id, _, _, _):
            return id
        case let .text(id, _, _):
            return id
        case let .filter(id, _, _):
            return id
        case let .item(item):
            return item.stableId
        }
    }

    static func <(lhs: DarkgramDeletedMessagesBrowserEntry, rhs: DarkgramDeletedMessagesBrowserEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func ==(lhs: DarkgramDeletedMessagesBrowserEntry, rhs: DarkgramDeletedMessagesBrowserEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.accentHeader(id1, section1, text1, badge1), .accentHeader(id2, section2, text2, badge2)):
            return id1 == id2 && section1 == section2 && text1 == text2 && badge1.text == badge2.text
        case let (.text(id1, section1, text1), .text(id2, section2, text2)):
            return id1 == id2 && section1 == section2 && text1 == text2
        case let (.filter(id1, title1, value1), .filter(id2, title2, value2)):
            return id1 == id2 && title1 == title2 && value1 == value2
        case let (.item(item1), .item(item2)):
            return item1.stableId == item2.stableId && item1.title == item2.title && item1.detailText == item2.detailText && item1.detailTitle == item2.detailTitle
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        guard let arguments = arguments as? DarkgramDeletedMessagesBrowserArguments else {
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain("Darkgram deleted messages are temporarily unavailable."),
                sectionId: self.section
            )
        }

        switch self {
        case let .accentHeader(_, _, text, badge):
            return ItemListSectionHeaderItem(
                presentationData: presentationData,
                text: text,
                badge: badge.text,
                badgeStyle: badge.style,
                sectionId: self.section
            )
        case let .text(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case let .filter(_, title, value):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: UIImage(bundleImageName: "Chat/Context Menu/Timer")?.precomposed(),
                title: title,
                label: value,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.openFilter()
                }
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

private func darkgramDeletedBrowserFilterLabel(_ filter: DarkgramDeletedMessagesTimeFilter, lang: String) -> String {
    switch filter {
    case .last24Hours:
        return "Darkgram.DeletedBrowser.Filter.24h".i18n(lang)
    case .last7Days:
        return "Darkgram.DeletedBrowser.Filter.7d".i18n(lang)
    case .last30Days:
        return "Darkgram.DeletedBrowser.Filter.30d".i18n(lang)
    case .all:
        return "Darkgram.DeletedBrowser.Filter.All".i18n(lang)
    }
}

private func darkgramDeletedBrowserRecordedAfter(_ filter: DarkgramDeletedMessagesTimeFilter) -> Int64? {
    let now = Int64(Date().timeIntervalSince1970 * 1000.0)
    switch filter {
    case .last24Hours:
        return now - 24 * 60 * 60 * 1000
    case .last7Days:
        return now - 7 * 24 * 60 * 60 * 1000
    case .last30Days:
        return now - 30 * 24 * 60 * 60 * 1000
    case .all:
        return nil
    }
}

private func darkgramDeletedBrowserTimestampString(_ timestampMs: Int64, lang: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: lang == "ru" ? "ru_RU" : "en_US_POSIX")
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter.string(from: Date(timeIntervalSince1970: Double(timestampMs) / 1000.0))
}

private func darkgramDeletedBrowserContentText(message: Message, lang: String) -> String {
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

private func darkgramDeletedBrowserPreviewText(message: Message, lang: String) -> String {
    let content = darkgramDeletedBrowserContentText(message: message, lang: lang)
    let singleLine = content.components(separatedBy: CharacterSet.newlines).joined(separator: " ")
    return String(singleLine.prefix(80))
}

private func darkgramDeletedBrowserHasOpenableMedia(_ message: Message) -> Bool {
    for media in message.media {
        if media is TelegramMediaImage || media is TelegramMediaFile {
            return true
        }
    }
    return false
}

private func darkgramOpenDeletedBrowserMedia(
    context: AccountContext,
    message: Message,
    pushController: ((ViewController) -> Void)?,
    presentController: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
) -> Bool {
    let resolvedMessage = darkgramResolvedMediaMessage(accountBasePath: context.account.basePath, message: message)
    guard darkgramDeletedBrowserHasOpenableMedia(resolvedMessage) else {
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

private func darkgramDeletedBrowserPeerTitle(
    peer: Peer?,
    accountPeerId: PeerId,
    strings: PresentationStrings,
    lang: String
) -> String {
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
    } else if let associatedPeerId = peer.associatedPeerId, associatedPeerId == accountPeerId {
        return strings.DialogList_SavedMessages
    } else {
        return lang == "ru" ? "Чат" : "Chat"
    }
}

private func darkgramDeletedBrowserItems(
    context: AccountContext,
    presentationData: PresentationData,
    state: DarkgramDeletedMessagesBrowserState
) -> [DarkgramDeletedMessagesBrowserItem] {
    let lang = presentationData.strings.baseLanguageCode
    let deletedEntries = darkgramGlobalDeletedEntries(
        accountBasePath: context.account.basePath,
        recordedAfter: darkgramDeletedBrowserRecordedAfter(state.filter),
        limit: 2048
    )

    return deletedEntries.enumerated().map { index, entry in
        let peer = entry.message.peers[entry.message.id.peerId]
        let peerTitle = darkgramDeletedBrowserPeerTitle(
            peer: peer,
            accountPeerId: context.account.peerId,
            strings: presentationData.strings,
            lang: lang
        )
        let authorTitle = darkgramDeletedBrowserPeerTitle(
            peer: entry.message.author,
            accountPeerId: context.account.peerId,
            strings: presentationData.strings,
            lang: lang
        )
        let sentAt = darkgramDeletedBrowserTimestampString(Int64(entry.message.timestamp) * 1000, lang: lang)
        let deletedAt = darkgramDeletedBrowserTimestampString(entry.recordedAt, lang: lang)
        let previewText = darkgramDeletedBrowserPreviewText(message: entry.message, lang: lang)

        let detailText: String
        let detailTitle: String
        if lang == "ru" {
            detailText = "Чат: \(peerTitle)\nОт: \(authorTitle)\nОтправлено: \(sentAt)\nУдалено: \(deletedAt)"
            detailTitle = "\(peerTitle)\n\(authorTitle)\n\(deletedAt)\n\n\(darkgramDeletedBrowserContentText(message: entry.message, lang: lang))"
        } else {
            detailText = "Chat: \(peerTitle)\nFrom: \(authorTitle)\nSent: \(sentAt)\nDeleted: \(deletedAt)"
            detailTitle = "\(peerTitle)\n\(authorTitle)\n\(deletedAt)\n\n\(darkgramDeletedBrowserContentText(message: entry.message, lang: lang))"
        }

        return DarkgramDeletedMessagesBrowserItem(
            stableId: 1000 + Int32(index),
            message: entry.message,
            peer: peer,
            title: previewText,
            detailText: detailText,
            detailTitle: detailTitle
        )
    }
}

private func darkgramDeletedMessagesBrowserEntries(
    presentationData: PresentationData,
    state: DarkgramDeletedMessagesBrowserState,
    items: [DarkgramDeletedMessagesBrowserItem]
) -> [DarkgramDeletedMessagesBrowserEntry] {
    let lang = presentationData.strings.baseLanguageCode
    var entries: [DarkgramDeletedMessagesBrowserEntry] = []

    entries.append(.accentHeader(0, .overview, "Darkgram.DeletedBrowser.Overview.Header".i18n(lang), darkgramAccentBadge(.archiveSpy)))
    entries.append(.text(1, .overview, "Darkgram.DeletedBrowser.Overview.Text".i18n(lang)))

    entries.append(.accentHeader(10, .filters, "Darkgram.DeletedBrowser.Filters.Header".i18n(lang), darkgramAccentBadge(.archiveContent)))
    entries.append(.filter(11, "Darkgram.DeletedBrowser.Filters.Period".i18n(lang), darkgramDeletedBrowserFilterLabel(state.filter, lang: lang)))

    if items.isEmpty {
        entries.append(.accentHeader(20, .empty, "Darkgram.DeletedBrowser.Messages.Header".i18n(lang), darkgramAccentBadge(.archiveRetention)))
        entries.append(.text(21, .empty, "Darkgram.DeletedBrowser.Empty".i18n(lang)))
    } else {
        entries.append(.accentHeader(20, .messages, "Darkgram.DeletedBrowser.Messages.Header".i18n(lang), darkgramAccentBadge(.archiveRetention)))
        entries.append(contentsOf: items.map { .item($0) })
    }

    return entries
}

public func darkgramDeletedMessagesBrowserController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    let stateValue = Atomic(value: DarkgramDeletedMessagesBrowserState(filter: .all))
    let statePromise = ValuePromise(DarkgramDeletedMessagesBrowserState(filter: .all), ignoreRepeated: false)

    let updateState: (((DarkgramDeletedMessagesBrowserState) -> DarkgramDeletedMessagesBrowserState) -> Void) = { f in
        let updated = stateValue.modify(f)
        statePromise.set(updated)
    }

    let arguments = DarkgramDeletedMessagesBrowserArguments(
        context: context,
        openFilter: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let lang = presentationData.strings.baseLanguageCode
            let actionSheet = ActionSheetController(presentationData: presentationData)

            var actionItems: [ActionSheetItem] = [
                ActionSheetTextItem(title: "Darkgram.DeletedBrowser.Filters.Period".i18n(lang))
            ]

            let currentFilter = stateValue.with { $0.filter }

            for filter in DarkgramDeletedMessagesTimeFilter.allCases {
                let title = darkgramDeletedBrowserFilterLabel(filter, lang: lang)
                let isCurrent = filter == currentFilter
                let itemTitle = isCurrent ? "\(title) ✓" : title
                actionItems.append(ActionSheetButtonItem(title: itemTitle, color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    updateState { state in
                        var state = state
                        state.filter = filter
                        return state
                    }
                }))
            }

            actionItems.append(ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            }))

            actionSheet.setItemGroups([ActionSheetItemGroup(items: actionItems)])
            presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
        },
        openItem: { stableId in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let currentState = stateValue.with { $0 }
            let items = darkgramDeletedBrowserItems(context: context, presentationData: presentationData, state: currentState)
            guard let item = items.first(where: { $0.stableId == stableId }) else {
                return
            }
            if darkgramOpenDeletedBrowserMedia(
                context: context,
                message: item.message,
                pushController: pushControllerImpl,
                presentController: presentControllerImpl
            ) {
                return
            }
            let actionSheet = ActionSheetController(presentationData: presentationData)
            actionSheet.setItemGroups([
                ActionSheetItemGroup(items: [
                    ActionSheetTextItem(title: item.detailTitle)
                ]),
                ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: presentationData.strings.Common_Close, color: .accent, font: .bold, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                    })
                ])
            ])
            presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let items = darkgramDeletedBrowserItems(context: context, presentationData: presentationData, state: state)
        let entries = darkgramDeletedMessagesBrowserEntries(
            presentationData: presentationData,
            state: state,
            items: items
        )

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Darkgram.DeletedBrowser.Title".i18n(presentationData.strings.baseLanguageCode)),
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
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    return controller
}
