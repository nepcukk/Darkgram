import Foundation
import ItemListUI
import Display
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import Postbox
import TelegramCore
import PeerSelectionController
import SGSimpleSettings
import SGStrings

private struct DarkgramArchiveMobileDataExceptionArguments {
    let context: AccountContext
    let addPeer: () -> Void
    let removePeerId: (PeerId) -> Void
}

private enum DarkgramArchiveMobileDataExceptionSection: Int32 {
    case overview
    case actions
    case peers
    case empty
}

private enum DarkgramArchiveMobileDataExceptionEntry: ItemListNodeEntry, Equatable {
    case header(Int32, DarkgramArchiveMobileDataExceptionSection, String, DarkgramAccentBadge)
    case text(Int32, DarkgramArchiveMobileDataExceptionSection, String)
    case add(Int32, DarkgramArchiveMobileDataExceptionSection, String)
    case peer(Int32, DarkgramArchiveMobileDataExceptionSection, EnginePeer, String)

    var section: ItemListSectionId {
        switch self {
        case let .header(_, section, _, _):
            return section.rawValue
        case let .text(_, section, _):
            return section.rawValue
        case let .add(_, section, _):
            return section.rawValue
        case let .peer(_, section, _, _):
            return section.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(id, _, _, _):
            return id
        case let .text(id, _, _):
            return id
        case let .add(id, _, _):
            return id
        case let .peer(id, _, _, _):
            return id
        }
    }

    static func <(lhs: DarkgramArchiveMobileDataExceptionEntry, rhs: DarkgramArchiveMobileDataExceptionEntry) -> Bool {
        lhs.stableId < rhs.stableId
    }

    static func ==(lhs: DarkgramArchiveMobileDataExceptionEntry, rhs: DarkgramArchiveMobileDataExceptionEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(id1, section1, text1, badge1), .header(id2, section2, text2, badge2)):
            return id1 == id2 && section1 == section2 && text1 == text2 && badge1.text == badge2.text
        case let (.text(id1, section1, text1), .text(id2, section2, text2)):
            return id1 == id2 && section1 == section2 && text1 == text2
        case let (.add(id1, section1, title1), .add(id2, section2, title2)):
            return id1 == id2 && section1 == section2 && title1 == title2
        case let (.peer(id1, section1, peer1, label1), .peer(id2, section2, peer2, label2)):
            return id1 == id2 && section1 == section2 && peer1.id == peer2.id && label1 == label2
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        guard let arguments = arguments as? DarkgramArchiveMobileDataExceptionArguments else {
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain("Darkgram archive exceptions are temporarily unavailable."),
                sectionId: self.section
            )
        }

        switch self {
        case let .header(_, _, text, badge):
            return ItemListSectionHeaderItem(
                presentationData: presentationData,
                text: text,
                badge: badge.text,
                badgeStyle: badge.style,
                sectionId: self.section
            )
        case let .text(_, _, text):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .markdown(text),
                sectionId: self.section
            )
        case let .add(_, _, title):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.addPeer()
                }
            )
        case let .peer(_, _, peer, label):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                context: arguments.context,
                iconPeer: peer,
                title: peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder),
                label: label,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: {
                    arguments.removePeerId(peer.id)
                }
            )
        }
    }
}

private func darkgramArchiveMobileDataExceptionEntries(
    presentationData: PresentationData,
    peers: [EnginePeer]
) -> [DarkgramArchiveMobileDataExceptionEntry] {
    let lang = presentationData.strings.baseLanguageCode
    var entries: [DarkgramArchiveMobileDataExceptionEntry] = [
        .header(0, .overview, "Darkgram.Archive.MobileData.Exceptions.Header".i18n(lang), darkgramAccentBadge(.archiveMessageSaving)),
        .text(1, .overview, "Darkgram.Archive.MobileData.Exceptions.Notice".i18n(lang)),
        .header(10, .actions, "Darkgram.Archive.MobileData.Exceptions.Actions".i18n(lang), darkgramAccentBadge(.archiveContent)),
        .add(11, .actions, "Darkgram.Archive.MobileData.Exceptions.Add".i18n(lang))
    ]

    if peers.isEmpty {
        entries.append(.header(20, .empty, "Darkgram.Archive.MobileData.Exceptions.List".i18n(lang), darkgramAccentBadge(.archiveRetention)))
        entries.append(.text(21, .empty, "Darkgram.Archive.MobileData.Exceptions.Empty".i18n(lang)))
    } else {
        entries.append(.header(20, .peers, "Darkgram.Archive.MobileData.Exceptions.List".i18n(lang), darkgramAccentBadge(.archiveRetention)))
        for (index, peer) in peers.enumerated() {
            entries.append(.peer(100 + Int32(index), .peers, peer, "Darkgram.Archive.MobileData.Exceptions.Remove".i18n(lang)))
        }
    }

    return entries
}

public func darkgramArchiveMobileDataExceptionsController(context: AccountContext, updated: @escaping () -> Void) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?
    let reloadPromise = ValuePromise(true, ignoreRepeated: false)

    let arguments = DarkgramArchiveMobileDataExceptionArguments(
        context: context,
        addPeer: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let controller = context.sharedContext.makePeerSelectionController(
                PeerSelectionControllerParams(
                    context: context,
                    filter: [.excludeRecent, .excludeSavedMessages, .excludeDisabled, .doNotSearchMessages],
                    hasContactSelector: false,
                    title: "Darkgram.Archive.MobileData.Exceptions.Picker".i18n(presentationData.strings.baseLanguageCode)
                )
            )
            controller.peerSelected = { peer, _ in
                var ids = SGSimpleSettings.shared.darkgramDeletedMediaPrefetchExceptionPeerIds
                let rawId = String(peer.id.toInt64())
                if !ids.contains(rawId) {
                    ids.append(rawId)
                    SGSimpleSettings.shared.darkgramDeletedMediaPrefetchExceptionPeerIds = ids
                    updated()
                    reloadPromise.set(true)
                }
                controller.dismiss()
            }
            pushControllerImpl?(controller)
        },
        removePeerId: { peerId in
            var ids = SGSimpleSettings.shared.darkgramDeletedMediaPrefetchExceptionPeerIds
            ids.removeAll(where: { $0 == String(peerId.toInt64()) })
            SGSimpleSettings.shared.darkgramDeletedMediaPrefetchExceptionPeerIds = ids
            updated()
            reloadPromise.set(true)
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, reloadPromise.get())
    |> mapToSignal { presentationData, _ -> Signal<(ItemListControllerState, (ItemListNodeState, Any)), NoError> in
        let peerIds = SGSimpleSettings.shared.darkgramDeletedMediaPrefetchExceptionPeerIds.compactMap { Int64($0) }.map { PeerId($0) }
        return context.account.postbox.transaction { transaction -> [EnginePeer] in
            return peerIds.compactMap { transaction.getPeer($0) }.map(EnginePeer.init)
        }
        |> map { peers in
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text("Darkgram.Archive.MobileData.Exceptions".i18n(presentationData.strings.baseLanguageCode)),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            )
            let listState = ItemListNodeState(
                presentationData: ItemListPresentationData(presentationData),
                entries: darkgramArchiveMobileDataExceptionEntries(presentationData: presentationData, peers: peers),
                style: .blocks,
                ensureVisibleItemTag: nil,
                initialScrollToItem: nil
            )
            return (controllerState, (listState, arguments))
        }
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    return controller
}
