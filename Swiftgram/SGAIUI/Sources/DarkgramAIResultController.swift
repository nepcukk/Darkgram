import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import PresentationDataUtils

private struct DarkgramAIResultArguments {
    let copy: () -> Void
    let insert: (() -> Void)?
}

private enum DarkgramAIResultSection: Int32 {
    case result
    case actions
}

private enum DarkgramAIResultEntry: ItemListNodeEntry, Equatable {
    case text(Int32, String)
    case copy(Int32, String)
    case insert(Int32, String)

    var section: ItemListSectionId {
        switch self {
        case .text:
            return DarkgramAIResultSection.result.rawValue
        case .copy, .insert:
            return DarkgramAIResultSection.actions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case let .text(id, _):
            return id
        case let .copy(id, _):
            return id
        case let .insert(id, _):
            return id
        }
    }

    static func < (lhs: DarkgramAIResultEntry, rhs: DarkgramAIResultEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        guard let arguments = arguments as? DarkgramAIResultArguments else {
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain("Darkgram AI is temporarily unavailable."),
                sectionId: self.section
            )
        }

        switch self {
        case let .text(_, text):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain(text),
                sectionId: self.section
            )
        case let .copy(_, title):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: arguments.copy
            )
        case let .insert(_, title):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.insert?()
                }
            )
        }
    }
}

public func darkgramAIResultController(
    context: AccountContext,
    title: String,
    text: String,
    copyTitle: String,
    insertTitle: String?,
    onInsert: (() -> Void)?
) -> ViewController {
    let arguments = DarkgramAIResultArguments(
        copy: {
            UIPasteboard.general.string = text
        },
        insert: onInsert
    )

    let dismissImpl = Atomic<(() -> Void)?>(value: nil)

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [DarkgramAIResultEntry] = [
            .text(0, text),
            .copy(100, copyTitle)
        ]
        if let insertTitle, onInsert != nil {
            entries.append(.insert(101, insertTitle))
        }

        let leftNavigationButton = ItemListNavigationButton(
            content: .text(presentationData.strings.Common_Close),
            style: .regular,
            enabled: true,
            action: {
                dismissImpl.with { dismiss in
                    dismiss?()
                }
            }
        )

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(title),
            leftNavigationButton: leftNavigationButton,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            focusItemTag: nil,
            emptyStateItem: nil,
            initialScrollToItem: nil,
            crossfadeState: false,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    controller.acceptsFocusWhenInOverlay = true
    _ = dismissImpl.swap({ [weak controller] in
        controller?.dismiss()
    })
    return controller
}
