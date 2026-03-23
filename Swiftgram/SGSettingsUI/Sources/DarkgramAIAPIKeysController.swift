import Foundation
import UIKit
import SGAI
import SGItemListUI
import SGStrings
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramPresentationData
import PromptUI
import PresentationDataUtils

private enum DarkgramAIAPIKeysSection: Int32, SGItemListSection {
    case keys
    case actions
    case notice
}

private enum DarkgramAIAPIKeysUnusedSetting: Hashable {
}

private enum DarkgramAIAPIKeysAction: Hashable {
    case add
    case replace(String)
    case remove(String)
    case clearAll
}

private typealias DarkgramAIAPIKeysEntry = SGItemListUIEntry<DarkgramAIAPIKeysSection, DarkgramAIAPIKeysUnusedSetting, DarkgramAIAPIKeysUnusedSetting, DarkgramAIAPIKeysUnusedSetting, DarkgramAIAPIKeysUnusedSetting, DarkgramAIAPIKeysAction>

private func darkgramAIAPIKeysTitle(_ provider: DarkgramAIProviderKind, lang: String) -> String {
    switch provider {
    case .gemini:
        return "Darkgram.AI.Provider.GeminiAPIKeys".i18n(lang)
    case .grok:
        return "Darkgram.AI.Provider.GrokAPIKeys".i18n(lang)
    }
}

private func darkgramAIAPIKeysNotice(_ provider: DarkgramAIProviderKind, lang: String) -> String {
    switch provider {
    case .gemini:
        return "Darkgram.AI.Provider.GeminiAPIKeys.Notice".i18n(lang)
    case .grok:
        return "Darkgram.AI.Provider.GrokAPIKeys.Notice".i18n(lang)
    }
}

private func darkgramStableFingerprintId(_ fingerprint: String) -> Int {
    var hash: UInt64 = 1469598103934665603
    for byte in fingerprint.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1099511628211
    }
    return Int(hash % 1_000_000_000)
}

private func darkgramAIAPIKeysEntries(provider: DarkgramAIProviderKind, presentationData: PresentationData) -> [DarkgramAIAPIKeysEntry] {
    let lang = presentationData.strings.baseLanguageCode
    let usageSnapshots = DarkgramAIService.shared.apiKeyUsageSnapshots(for: provider)
    let providerOffset: Int = provider == .gemini ? 0 : 10_000

    var entries: [DarkgramAIAPIKeysEntry] = []
    entries.append(darkgramAccentHeader(id: providerOffset + 1, section: .keys, text: darkgramAIAPIKeysTitle(provider, lang: lang), accent: .aiProviders))

    if usageSnapshots.isEmpty {
        entries.append(.notice(id: providerOffset + 100, section: .keys, text: "Darkgram.AI.Provider.APIKeys.Empty".i18n(lang)))
    } else {
        for (index, snapshot) in usageSnapshots.enumerated() {
            let title = String(
                format: "Darkgram.AI.Provider.APIKeys.Item".i18n(lang),
                index + 1,
                snapshot.descriptor.maskedSuffix,
                snapshot.requestsToday
            )
            let fingerprintId = darkgramStableFingerprintId(snapshot.descriptor.fingerprint)
            let replaceId = providerOffset + 1_000_000_000 + fingerprintId * 2
            entries.append(.action(id: replaceId, section: .keys, actionType: .replace(snapshot.descriptor.fingerprint), text: title, kind: .generic))
            let removeTitle = String(
                format: "Darkgram.AI.Provider.APIKeys.Remove".i18n(lang),
                index + 1,
                snapshot.descriptor.maskedSuffix
            )
            entries.append(.action(id: replaceId + 1, section: .keys, actionType: .remove(snapshot.descriptor.fingerprint), text: removeTitle, kind: .destructive))
        }
    }

    entries.append(darkgramAccentHeader(id: providerOffset + 8_000, section: .actions, text: "Darkgram.AI.Provider.APIKeys.Actions".i18n(lang), accent: .aiFeatures))
    entries.append(.action(id: providerOffset + 8_100, section: .actions, actionType: .add, text: "Darkgram.AI.Provider.APIKeys.Add".i18n(lang), kind: .generic))
    if !usageSnapshots.isEmpty {
        entries.append(.action(id: providerOffset + 8_101, section: .actions, actionType: .clearAll, text: "Darkgram.AI.Provider.APIKeys.ClearAll".i18n(lang), kind: .destructive))
    }
    entries.append(.notice(id: providerOffset + 9_000, section: .notice, text: darkgramAIAPIKeysNotice(provider, lang: lang)))

    return entries
}

public func darkgramAIAPIKeysController(
    context: AccountContext,
    provider: DarkgramAIProviderKind,
    onUpdate: @escaping () -> Void
) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    let simplePromise = ValuePromise(true, ignoreRepeated: false)

    func refresh() {
        onUpdate()
        simplePromise.set(true)
    }

    func presentAPIKeyPrompt(
        title: String,
        subtitle: String,
        placeholder: String,
        apply: @escaping (String) -> Void
    ) {
        let controller = promptController(
            context: context,
            text: title,
            subtitle: subtitle,
            value: nil,
            placeholder: placeholder,
            characterLimit: 4096,
            displayCharacterLimit: false,
            apply: { value in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                    return
                }
                apply(value)
            }
        )
        presentControllerImpl?(controller, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }

    let arguments = SGItemListArguments<DarkgramAIAPIKeysUnusedSetting, DarkgramAIAPIKeysUnusedSetting, DarkgramAIAPIKeysUnusedSetting, DarkgramAIAPIKeysUnusedSetting, DarkgramAIAPIKeysAction>(
        context: context,
        action: { action in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let lang = presentationData.strings.baseLanguageCode
            switch action {
            case .add:
                presentAPIKeyPrompt(
                    title: "Darkgram.AI.Provider.APIKeys.Add".i18n(lang),
                    subtitle: darkgramAIAPIKeysNotice(provider, lang: lang),
                    placeholder: "Darkgram.AI.Provider.APIKeys.Placeholder".i18n(lang),
                    apply: { value in
                        try? DarkgramAIService.shared.appendAPIKey(value, for: provider)
                        refresh()
                    }
                )
            case let .replace(fingerprint):
                presentAPIKeyPrompt(
                    title: "Darkgram.AI.Provider.APIKeys.Replace.Title".i18n(lang),
                    subtitle: "Darkgram.AI.Provider.APIKeys.Replace.Notice".i18n(lang),
                    placeholder: "Darkgram.AI.Provider.APIKeys.Placeholder".i18n(lang),
                    apply: { value in
                        try? DarkgramAIService.shared.replaceAPIKey(value, fingerprint: fingerprint, for: provider)
                        refresh()
                    }
                )
            case let .remove(fingerprint):
                try? DarkgramAIService.shared.removeAPIKey(fingerprint: fingerprint, for: provider)
                Queue.mainQueue().after(0.05, {
                    refresh()
                })
            case .clearAll:
                try? DarkgramAIService.shared.clearAPIKey(for: provider)
                Queue.mainQueue().after(0.05, {
                    refresh()
                })
            }
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, simplePromise.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = darkgramAIAPIKeysEntries(provider: provider, presentationData: presentationData)
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(darkgramAIAPIKeysTitle(provider, lang: presentationData.strings.baseLanguageCode)),
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
    return controller
}
