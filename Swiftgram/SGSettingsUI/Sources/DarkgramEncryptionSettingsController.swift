import Foundation
import SGDarkEncryption
import SGItemListUI
import SGSimpleSettings
import SGStrings
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramPresentationData

private enum DarkgramEncryptionSection: Int32, SGItemListSection {
    case general
    case password
    case about
}

private enum DarkgramEncryptionToggle: String {
    case enabled
}

private enum DarkgramEncryptionSelector: String {
    case password
}

private enum DarkgramEncryptionAction: Hashable {
    case clearPassword
}

private typealias DarkgramEncryptionEntry = SGItemListUIEntry<DarkgramEncryptionSection, DarkgramEncryptionToggle, DarkgramEncryptionToggle, DarkgramEncryptionSelector, DarkgramEncryptionSelector, DarkgramEncryptionAction>

private func darkgramEncryptionPasswordStatus(lang: String) -> String {
    if let suffix = DarkgramEncryption.passwordStatusSuffix() {
        return lang == "ru" ? "Свой пароль (••••\(suffix))" : "Custom password (••••\(suffix))"
    } else {
        return lang == "ru" ? "Стандартный пароль 0000" : "Default password 0000"
    }
}

private func darkgramEncryptionEntries(presentationData: PresentationData) -> [DarkgramEncryptionEntry] {
    let lang = presentationData.strings.baseLanguageCode
    let id = SGItemListCounter()

    return [
        darkgramAccentHeader(id: id.count, section: .general, text: "Darkgram.Encryption.General.Header".i18n(lang), accent: .encryptionGeneral),
        .toggle(id: id.count, section: .general, settingName: .enabled, value: SGSimpleSettings.shared.darkgramEncryptionEnabled, text: "Darkgram.Encryption.Enabled".i18n(lang), enabled: true),
        .notice(id: id.count, section: .general, text: "Darkgram.Encryption.General.Notice".i18n(lang)),

        darkgramAccentHeader(id: id.count, section: .password, text: "Darkgram.Encryption.Password.Header".i18n(lang), accent: .encryptionPassword),
        .oneFromManySelector(id: id.count, section: .password, settingName: .password, text: "Darkgram.Encryption.Password".i18n(lang), value: darkgramEncryptionPasswordStatus(lang: lang), enabled: true),
        .notice(id: id.count, section: .password, text: "Darkgram.Encryption.Password.Notice".i18n(lang)),

        darkgramAccentHeader(id: id.count, section: .about, text: "Darkgram.Encryption.About.Header".i18n(lang), accent: .encryptionAbout),
        .notice(id: id.count, section: .about, text: "Darkgram.Encryption.About.Notice".i18n(lang))
    ]
}

public func darkgramEncryptionSettingsController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?
    let refreshPromise = ValuePromise(true, ignoreRepeated: false)

    let arguments = SGItemListArguments<DarkgramEncryptionToggle, DarkgramEncryptionToggle, DarkgramEncryptionSelector, DarkgramEncryptionSelector, DarkgramEncryptionAction>(
        context: context,
        setBoolValue: { toggle, value in
            switch toggle {
            case .enabled:
                SGSimpleSettings.shared.darkgramEncryptionEnabled = value
            }
            refreshPromise.set(true)
        },
        setOneFromManyValue: { selector in
            switch selector {
            case .password:
                pushControllerImpl?(darkgramEncryptionPasswordController(context: context))
            }
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, refreshPromise.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Darkgram.Encryption.Title".i18n(lang)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: darkgramEncryptionEntries(presentationData: presentationData),
            style: .blocks,
            ensureVisibleItemTag: nil,
            initialScrollToItem: nil
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    return controller
}

private enum DarkgramEncryptionPasswordSection: Int32, SGItemListSection {
    case editor
    case actions
}

private typealias DarkgramEncryptionPasswordEntry = SGItemListUIEntry<DarkgramEncryptionPasswordSection, DarkgramEncryptionToggle, DarkgramEncryptionToggle, DarkgramEncryptionSelector, DarkgramEncryptionSelector, DarkgramEncryptionAction>

public func darkgramEncryptionPasswordController(context: AccountContext) -> ViewController {
    let initialText = (try? DarkgramEncryptionKeychainStore.shared.password()) ?? ""
    let textPromise = ValuePromise(initialText, ignoreRepeated: false)

    let arguments = SGItemListArguments<DarkgramEncryptionToggle, DarkgramEncryptionToggle, DarkgramEncryptionSelector, DarkgramEncryptionSelector, DarkgramEncryptionAction>(
        context: context,
        action: { action in
            switch action {
            case .clearPassword:
                try? DarkgramEncryptionKeychainStore.shared.clearPassword()
                textPromise.set("")
            }
        },
        searchInput: { input in
            try? DarkgramEncryptionKeychainStore.shared.setPassword(input)
            textPromise.set(input)
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, textPromise.get())
    |> map { presentationData, currentValue -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let currentStatus = darkgramEncryptionPasswordStatus(lang: lang)
        let entries: [DarkgramEncryptionPasswordEntry] = [
            .searchInput(id: 0, section: .editor, title: NSAttributedString(string: "Darkgram.Encryption.Password".i18n(lang)), text: currentValue, placeholder: "Darkgram.Encryption.Password.Placeholder".i18n(lang)),
            .notice(id: 1, section: .editor, text: "\(currentStatus)\n\n\("Darkgram.Encryption.Password.Notice".i18n(lang))"),
            .action(id: 2, section: .actions, actionType: .clearPassword, text: "Darkgram.Encryption.Password.Clear".i18n(lang), kind: .destructive)
        ]
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Darkgram.Encryption.Password".i18n(lang)),
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

    return ItemListController(context: context, state: signal)
}
