import Foundation
import UIKit
import SGAI
import SGItemListUI
import SGSimpleSettings
import SGStrings
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramPresentationData

private enum DarkgramAIUnusedSetting: Hashable {
}

private enum DarkgramAISection: Int32, SGItemListSection {
    case providers
    case features
    case privacy
    case debate
    case about
}

private enum DarkgramAIToggle: String {
    case enabled
    case messageSummaries
    case voiceSummaries
    case composeButton
    case replyDrafting
    case debateThreads
    case allowRecentChatContext
    case allowTranscriptUpload
    case redactUsernames
    case confirmLargeContext
}

private enum DarkgramAISelector: String {
    case provider
    case responseLanguage
    case geminiApiKeys
    case geminiModel
    case grokApiKeys
    case grokModel
}

private enum DarkgramAIAction: Hashable {
}

private typealias DarkgramAIEntry = SGItemListUIEntry<DarkgramAISection, DarkgramAIToggle, DarkgramAIUnusedSetting, DarkgramAISelector, DarkgramAIUnusedSetting, DarkgramAIAction>

private func darkgramAIProviderTitle(_ provider: DarkgramAIProviderKind, lang: String) -> String {
    switch provider {
    case .gemini:
        return "Darkgram.AI.Provider.Gemini".i18n(lang)
    case .grok:
        return "Darkgram.AI.Provider.Grok".i18n(lang)
    }
}

private func darkgramAIAPIKeysSummaryLabel(_ provider: DarkgramAIProviderKind, lang: String) -> String {
    let usage = DarkgramAIService.shared.apiKeyUsageSnapshots(for: provider)
    let keyCount = usage.count
    let requestCount = usage.reduce(0, { $0 + $1.requestsToday })
    if lang == "ru" {
        return "\(keyCount) ключ(ей) · \(requestCount) запросов сегодня"
    } else {
        return "\(keyCount) key(s) · \(requestCount) requests today"
    }
}

private func darkgramAIResponseLanguageLabel(_ snapshot: DarkgramAISettingsSnapshot, lang: String) -> String {
    let rawValue = snapshot.responseLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    if rawValue.isEmpty || rawValue.lowercased() == "system" {
        let resolved = DarkgramAIService.shared.resolvedResponseLanguage(from: rawValue)
        if lang == "ru" {
            return "Системный (\(resolved))"
        } else {
            return "System (\(resolved))"
        }
    }
    return rawValue
}

private func darkgramAIEntries(presentationData: PresentationData) -> [DarkgramAIEntry] {
    let lang = presentationData.strings.baseLanguageCode
    let id = SGItemListCounter()
    let snapshot = SGSimpleSettings.shared.darkgramAISettingsSnapshot

    return [
        darkgramAccentHeader(id: id.count, section: .providers, text: "Darkgram.AI.Providers.Header".i18n(lang), accent: .aiProviders),
        .toggle(id: id.count, section: .providers, settingName: .enabled, value: snapshot.enabled, text: "Darkgram.AI.Enabled".i18n(lang), enabled: true),
        .oneFromManySelector(id: id.count, section: .providers, settingName: .provider, text: "Darkgram.AI.Provider.Active".i18n(lang), value: darkgramAIProviderTitle(snapshot.activeProvider, lang: lang), enabled: true),
        .oneFromManySelector(id: id.count, section: .providers, settingName: .geminiApiKeys, text: "Darkgram.AI.Provider.GeminiAPIKeys".i18n(lang), value: darkgramAIAPIKeysSummaryLabel(.gemini, lang: lang), enabled: true),
        .oneFromManySelector(id: id.count, section: .providers, settingName: .geminiModel, text: "Darkgram.AI.Provider.GeminiModel".i18n(lang), value: snapshot.geminiModel, enabled: true),
        .oneFromManySelector(id: id.count, section: .providers, settingName: .grokApiKeys, text: "Darkgram.AI.Provider.GrokAPIKeys".i18n(lang), value: darkgramAIAPIKeysSummaryLabel(.grok, lang: lang), enabled: true),
        .oneFromManySelector(id: id.count, section: .providers, settingName: .grokModel, text: "Darkgram.AI.Provider.GrokModel".i18n(lang), value: snapshot.grokModel, enabled: true),
        .notice(id: id.count, section: .providers, text: "Darkgram.AI.Providers.Notice".i18n(lang)),

        darkgramAccentHeader(id: id.count, section: .features, text: "Darkgram.AI.Features.Header".i18n(lang), accent: .aiFeatures),
        .toggle(id: id.count, section: .features, settingName: .messageSummaries, value: snapshot.messageSummariesEnabled, text: "Darkgram.AI.Features.MessageSummaries".i18n(lang), enabled: snapshot.enabled),
        .toggle(id: id.count, section: .features, settingName: .voiceSummaries, value: snapshot.voiceSummariesEnabled, text: "Darkgram.AI.Features.VoiceSummaries".i18n(lang), enabled: snapshot.enabled),
        .toggle(id: id.count, section: .features, settingName: .composeButton, value: snapshot.composeButtonEnabled, text: "Darkgram.AI.Features.ComposeButton".i18n(lang), enabled: snapshot.enabled),
        .toggle(id: id.count, section: .features, settingName: .replyDrafting, value: snapshot.replyDraftingEnabled, text: "Darkgram.AI.Features.ReplyDrafting".i18n(lang), enabled: snapshot.enabled),
        .oneFromManySelector(id: id.count, section: .features, settingName: .responseLanguage, text: "Darkgram.AI.Features.ResponseLanguage".i18n(lang), value: darkgramAIResponseLanguageLabel(snapshot, lang: lang), enabled: snapshot.enabled),
        .notice(id: id.count, section: .features, text: "Darkgram.AI.Features.Notice".i18n(lang)),

        darkgramAccentHeader(id: id.count, section: .privacy, text: "Darkgram.AI.Privacy.Header".i18n(lang), accent: .aiPrivacy),
        .toggle(id: id.count, section: .privacy, settingName: .allowRecentChatContext, value: snapshot.allowRecentChatContext, text: "Darkgram.AI.Privacy.AllowRecentChatContext".i18n(lang), enabled: snapshot.enabled),
        .toggle(id: id.count, section: .privacy, settingName: .allowTranscriptUpload, value: snapshot.allowTranscriptUpload, text: "Darkgram.AI.Privacy.AllowTranscriptUpload".i18n(lang), enabled: snapshot.enabled),
        .toggle(id: id.count, section: .privacy, settingName: .redactUsernames, value: snapshot.redactUsernames, text: "Darkgram.AI.Privacy.RedactUsernames".i18n(lang), enabled: snapshot.enabled),
        .toggle(id: id.count, section: .privacy, settingName: .confirmLargeContext, value: snapshot.confirmLargeContext, text: "Darkgram.AI.Privacy.ConfirmLargeContext".i18n(lang), enabled: snapshot.enabled),
        .notice(id: id.count, section: .privacy, text: "Darkgram.AI.Privacy.Notice".i18n(lang)),

        darkgramAccentHeader(id: id.count, section: .debate, text: "Darkgram.AI.Debate.Header".i18n(lang), accent: .aiDebate),
        .toggle(id: id.count, section: .debate, settingName: .debateThreads, value: snapshot.debateThreadsEnabled, text: "Darkgram.AI.Debate.Enabled".i18n(lang), enabled: snapshot.enabled),
        .notice(id: id.count, section: .debate, text: "Darkgram.AI.Debate.Notice".i18n(lang)),

        darkgramAccentHeader(id: id.count, section: .about, text: "Darkgram.AI.About.Header".i18n(lang), accent: .aiFeatures),
        .notice(id: id.count, section: .about, text: "Darkgram.AI.About.Notice".i18n(lang))
    ]
}

public func darkgramAISettingsController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    let simplePromise = ValuePromise(true, ignoreRepeated: false)

    let arguments = SGItemListArguments<DarkgramAIToggle, DarkgramAIUnusedSetting, DarkgramAISelector, DarkgramAIUnusedSetting, DarkgramAIAction>(
        context: context,
        setBoolValue: { toggle, value in
            switch toggle {
            case .enabled:
                SGSimpleSettings.shared.darkgramAIEnabled = value
            case .messageSummaries:
                SGSimpleSettings.shared.darkgramAIMessageSummariesEnabled = value
            case .voiceSummaries:
                SGSimpleSettings.shared.darkgramAIVoiceSummariesEnabled = value
            case .composeButton:
                SGSimpleSettings.shared.darkgramAIComposeButtonEnabled = value
            case .replyDrafting:
                SGSimpleSettings.shared.darkgramAIReplyDraftingEnabled = value
            case .debateThreads:
                SGSimpleSettings.shared.darkgramAIDebateThreadsEnabled = value
            case .allowRecentChatContext:
                SGSimpleSettings.shared.darkgramAIAllowRecentChatContext = value
            case .allowTranscriptUpload:
                SGSimpleSettings.shared.darkgramAIAllowTranscriptUpload = value
            case .redactUsernames:
                SGSimpleSettings.shared.darkgramAIRedactUsernames = value
            case .confirmLargeContext:
                SGSimpleSettings.shared.darkgramAIConfirmLargeContext = value
            }
            simplePromise.set(true)
        },
        setOneFromManyValue: { selector in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let lang = presentationData.strings.baseLanguageCode

            switch selector {
            case .provider:
                let actionSheet = ActionSheetController(presentationData: presentationData)
                let currentProvider = SGSimpleSettings.shared.darkgramAISettingsSnapshot.activeProvider
                var items: [ActionSheetItem] = DarkgramAIProviderKind.allCases.map { provider in
                    let title = provider == currentProvider ? "\(darkgramAIProviderTitle(provider, lang: lang)) ✓" : darkgramAIProviderTitle(provider, lang: lang)
                    return ActionSheetButtonItem(title: title, color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        SGSimpleSettings.shared.darkgramAIActiveProvider = provider.rawValue
                        simplePromise.set(true)
                    })
                }
                items.append(ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                }))
                actionSheet.setItemGroups([
                    ActionSheetItemGroup(items: [
                        ActionSheetTextItem(title: "Darkgram.AI.Provider.Active".i18n(lang))
                    ]),
                    ActionSheetItemGroup(items: items)
                ])
                presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
            case .responseLanguage:
                pushControllerImpl?(darkgramAITextValueController(
                    context: context,
                    title: "Darkgram.AI.Features.ResponseLanguage".i18n(lang),
                    notice: "Darkgram.AI.Features.ResponseLanguage.Notice".i18n(lang),
                    placeholder: "Darkgram.AI.Features.ResponseLanguage.Placeholder".i18n(lang),
                    value: SGSimpleSettings.shared.darkgramAIResponseLanguage,
                    updateValue: { input in
                        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
                        SGSimpleSettings.shared.darkgramAIResponseLanguage = trimmed.isEmpty ? "system" : trimmed
                        simplePromise.set(true)
                    }
                ))
            case .geminiApiKeys:
                pushControllerImpl?(darkgramAIAPIKeysController(
                    context: context,
                    provider: .gemini,
                    onUpdate: {
                        simplePromise.set(true)
                    }
                ))
            case .geminiModel:
                pushControllerImpl?(darkgramAITextValueController(
                    context: context,
                    title: "Darkgram.AI.Provider.GeminiModel".i18n(lang),
                    notice: "Darkgram.AI.Provider.GeminiModel.Notice".i18n(lang),
                    placeholder: DarkgramAIProviderKind.gemini.defaultModel,
                    value: SGSimpleSettings.shared.darkgramAIGeminiModel,
                    updateValue: { input in
                        SGSimpleSettings.shared.darkgramAIGeminiModel = input.isEmpty ? DarkgramAIProviderKind.gemini.defaultModel : input
                        simplePromise.set(true)
                    }
                ))
            case .grokApiKeys:
                pushControllerImpl?(darkgramAIAPIKeysController(
                    context: context,
                    provider: .grok,
                    onUpdate: {
                        simplePromise.set(true)
                    }
                ))
            case .grokModel:
                pushControllerImpl?(darkgramAITextValueController(
                    context: context,
                    title: "Darkgram.AI.Provider.GrokModel".i18n(lang),
                    notice: "Darkgram.AI.Provider.GrokModel.Notice".i18n(lang),
                    placeholder: DarkgramAIProviderKind.grok.defaultModel,
                    value: SGSimpleSettings.shared.darkgramAIGrokModel,
                    updateValue: { input in
                        SGSimpleSettings.shared.darkgramAIGrokModel = input.isEmpty ? DarkgramAIProviderKind.grok.defaultModel : input
                        simplePromise.set(true)
                    }
                ))
            }
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, simplePromise.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let entries = darkgramAIEntries(presentationData: presentationData)
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Darkgram.AI.Title".i18n(lang)),
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

private enum DarkgramAITextValueSection: Int32, SGItemListSection {
    case editor
    case actions
}

private enum DarkgramAISecretAction: Hashable {
    case clear
}

private typealias DarkgramAITextValueEntry = SGItemListUIEntry<DarkgramAITextValueSection, DarkgramAIUnusedSetting, DarkgramAIUnusedSetting, DarkgramAIUnusedSetting, DarkgramAIUnusedSetting, DarkgramAISecretAction>

private func darkgramAITextValueController(
    context: AccountContext,
    title: String,
    notice: String,
    placeholder: String,
    value: String,
    updateValue: @escaping (String) -> Void
) -> ViewController {
    let textPromise = ValuePromise(value, ignoreRepeated: false)
    let arguments = SGItemListArguments<DarkgramAIUnusedSetting, DarkgramAIUnusedSetting, DarkgramAIUnusedSetting, DarkgramAIUnusedSetting, DarkgramAISecretAction>(
        context: context,
        searchInput: { input in
            updateValue(input.trimmingCharacters(in: .whitespacesAndNewlines))
            textPromise.set(input)
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, textPromise.get())
    |> map { presentationData, currentValue -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries: [DarkgramAITextValueEntry] = [
            .searchInput(id: 0, section: .editor, title: NSAttributedString(string: title), text: currentValue, placeholder: placeholder),
            .notice(id: 1, section: .editor, text: notice)
        ]
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(title),
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

private func darkgramAISecretValueController(
    context: AccountContext,
    title: String,
    notice: String,
    placeholder: String,
    currentStatus: String,
    updateValue: @escaping (String) -> Void,
    clearValue: @escaping () -> Void
) -> ViewController {
    let textPromise = ValuePromise("", ignoreRepeated: false)
    let arguments = SGItemListArguments<DarkgramAIUnusedSetting, DarkgramAIUnusedSetting, DarkgramAIUnusedSetting, DarkgramAIUnusedSetting, DarkgramAISecretAction>(
        context: context,
        action: { action in
            if case .clear = action {
                clearValue()
                textPromise.set("")
            }
        },
        searchInput: { input in
            updateValue(input)
            textPromise.set(input)
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, textPromise.get())
    |> map { presentationData, currentValue -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries: [DarkgramAITextValueEntry] = [
            .searchInput(id: 0, section: .editor, title: NSAttributedString(string: title), text: currentValue, placeholder: placeholder),
            .notice(id: 1, section: .editor, text: "\(notice)\n\n\(currentStatus)"),
            .action(id: 2, section: .actions, actionType: .clear, text: presentationData.strings.baseLanguageCode == "ru" ? "Очистить ключ" : "Clear Key", kind: .destructive)
        ]
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(title),
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
