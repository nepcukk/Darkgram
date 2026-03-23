import Foundation
import ItemListUI
import Display
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import SGStrings

private enum DarkgramAboutSection: Int32 {
    case overview
    case links
    case version
}

private enum DarkgramAboutEntry: ItemListNodeEntry, Equatable {
    case header(Int32, DarkgramAboutSection, String, DarkgramAccentBadge)
    case text(Int32, DarkgramAboutSection, String)
    case channel(Int32, DarkgramAboutSection, String, String)
    case version(Int32, DarkgramAboutSection, String, String)

    var section: ItemListSectionId {
        switch self {
        case let .header(_, section, _, _):
            return section.rawValue
        case let .text(_, section, _):
            return section.rawValue
        case let .channel(_, section, _, _):
            return section.rawValue
        case let .version(_, section, _, _):
            return section.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(id, _, _, _):
            return id
        case let .text(id, _, _):
            return id
        case let .channel(id, _, _, _):
            return id
        case let .version(id, _, _, _):
            return id
        }
    }

    static func <(lhs: DarkgramAboutEntry, rhs: DarkgramAboutEntry) -> Bool {
        lhs.stableId < rhs.stableId
    }

    static func ==(lhs: DarkgramAboutEntry, rhs: DarkgramAboutEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(id1, section1, text1, badge1), .header(id2, section2, text2, badge2)):
            return id1 == id2 && section1 == section2 && text1 == text2 && badge1.text == badge2.text
        case let (.text(id1, section1, text1), .text(id2, section2, text2)):
            return id1 == id2 && section1 == section2 && text1 == text2
        case let (.channel(id1, section1, title1, value1), .channel(id2, section2, title2, value2)):
            return id1 == id2 && section1 == section2 && title1 == title2 && value1 == value2
        case let (.version(id1, section1, title1, value1), .version(id2, section2, title2, value2)):
            return id1 == id2 && section1 == section2 && title1 == title2 && value1 == value2
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        guard let arguments = arguments as? AccountContext else {
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain("Darkgram information is temporarily unavailable."),
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
        case let .channel(_, _, title, value):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                label: value,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.sharedContext.applicationBindings.openUrl("https://t.me/darkgraam")
                }
            )
        case let .version(_, _, title, value):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                enabled: false,
                label: value,
                sectionId: self.section,
                style: .blocks,
                disclosureStyle: .none,
                action: {
                }
            )
        }
    }
}

private func darkgramAboutEntries(presentationData: PresentationData) -> [DarkgramAboutEntry] {
    let lang = presentationData.strings.baseLanguageCode
    return [
        .header(0, .overview, "Darkgram.About.Header".i18n(lang), darkgramAccentBadge(.root)),
        .text(1, .overview, "Darkgram.About.Description".i18n(lang)),
        .header(10, .links, "Darkgram.About.Channel.Header".i18n(lang), darkgramAccentBadge(.syncGeneral)),
        .channel(11, .links, "Darkgram.About.Channel".i18n(lang), "@darkgraam"),
        .text(12, .links, "Darkgram.About.Channel.Notice".i18n(lang)),
        .header(20, .version, "Darkgram.About.Version.Header".i18n(lang), darkgramAccentBadge(.customizationMarks)),
        .version(21, .version, "Darkgram.About.Version".i18n(lang), darkgramCurrentVersion)
    ]
}

public func darkgramAboutController(context: AccountContext) -> ViewController {
    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Darkgram.About.Title".i18n(presentationData.strings.baseLanguageCode)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: darkgramAboutEntries(presentationData: presentationData),
            style: .blocks,
            ensureVisibleItemTag: nil,
            initialScrollToItem: nil
        )
        return (controllerState, (listState, context))
    }

    return ItemListController(context: context, state: signal)
}
