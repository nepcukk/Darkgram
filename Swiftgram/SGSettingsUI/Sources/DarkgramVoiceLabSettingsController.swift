import Foundation
import SGItemListUI
import SGSimpleSettings
import SGStrings
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramPresentationData

private enum DarkgramVoiceLabSection: Int32, SGItemListSection {
    case general
    case tuning
    case about
}

private enum DarkgramVoiceLabToggle: String {
    case enabled
    case applyToVoiceMessages
    case applyToCalls
    case applyToGroupCalls
    case allowForwardWithVoiceChange
    case preserveDuration
    case dontSendOnFailure
    case sendToSavedMessagesOnFailure
}

private enum DarkgramVoiceLabSlider: String {
    case pitch
}

private enum DarkgramVoiceLabSelector: String {
    case exactPitch
    case exactGain
}

private enum DarkgramVoiceLabAction: Hashable {
    case reset
}

private typealias DarkgramVoiceLabEntry = SGItemListUIEntry<DarkgramVoiceLabSection, DarkgramVoiceLabToggle, DarkgramVoiceLabSlider, DarkgramVoiceLabSelector, DarkgramVoiceLabSelector, DarkgramVoiceLabAction>

private func darkgramVoiceLabPitchLabel(lang: String) -> String {
    let value = SGSimpleSettings.shared.darkgramVoiceLabPitchCents
    if value == 0 {
        return lang == "ru" ? "Натуральный (0 центов)" : "Natural (0 cents)"
    } else if value > 0 {
        return lang == "ru" ? "Выше (+\(value) центов)" : "Higher (+\(value) cents)"
    } else {
        return lang == "ru" ? "Ниже (\(value) центов)" : "Lower (\(value) cents)"
    }
}

private func darkgramVoiceLabGainLabel(lang: String) -> String {
    let value = SGSimpleSettings.shared.darkgramVoiceLabOutputGainPercent
    if lang == "ru" {
        return "\(value)% громкости"
    } else {
        return "\(value)% gain"
    }
}

private func darkgramVoiceLabEntries(presentationData: PresentationData) -> [DarkgramVoiceLabEntry] {
    let lang = presentationData.strings.baseLanguageCode
    let id = SGItemListCounter()
    let snapshot = SGSimpleSettings.shared.darkgramVoiceLabSettingsSnapshot
    
    var entries: [DarkgramVoiceLabEntry] = [
        darkgramAccentHeader(id: id.count, section: .general, text: "Darkgram.VoiceLab.General.Header".i18n(lang), accent: .voiceGeneral),
        .toggle(id: id.count, section: .general, settingName: .enabled, value: snapshot.enabled, text: "Darkgram.VoiceLab.Enabled".i18n(lang), enabled: true),
        .toggle(id: id.count, section: .general, settingName: .applyToVoiceMessages, value: snapshot.applyToVoiceMessages, text: "Darkgram.VoiceLab.ApplyToVoiceMessages".i18n(lang), enabled: true),
        .toggle(id: id.count, section: .general, settingName: .applyToCalls, value: snapshot.applyToCalls, text: "Darkgram.VoiceLab.ApplyToCalls".i18n(lang), enabled: true),
        .toggle(id: id.count, section: .general, settingName: .applyToGroupCalls, value: snapshot.applyToGroupCalls, text: "Darkgram.VoiceLab.ApplyToGroupCalls".i18n(lang), enabled: true),
        .toggle(id: id.count, section: .general, settingName: .allowForwardWithVoiceChange, value: snapshot.allowForwardWithVoiceChange, text: "Darkgram.VoiceLab.AllowForwardWithVoiceChange".i18n(lang), enabled: snapshot.enabled),
        .toggle(id: id.count, section: .general, settingName: .preserveDuration, value: snapshot.preserveDuration, text: "Darkgram.VoiceLab.PreserveDuration".i18n(lang), enabled: true),
        .toggle(id: id.count, section: .general, settingName: .dontSendOnFailure, value: snapshot.dontSendOnFailure, text: "Darkgram.VoiceLab.DontSendOnFailure".i18n(lang), enabled: snapshot.enabled)
    ]
    
    if snapshot.dontSendOnFailure {
        entries.append(.toggle(id: id.count, section: .general, settingName: .sendToSavedMessagesOnFailure, value: snapshot.sendToSavedMessagesOnFailure, text: "Darkgram.VoiceLab.SendToSavedMessagesOnFailure".i18n(lang), enabled: snapshot.enabled))
    }
    
    entries.append(.notice(id: id.count, section: .general, text: "Darkgram.VoiceLab.General.Notice".i18n(lang)))
    
    entries.append(contentsOf: [
        darkgramAccentHeader(id: id.count, section: .tuning, text: "Darkgram.VoiceLab.Tuning.Header".i18n(lang), accent: .voiceTuning),
        .percentageSlider(id: id.count, section: .tuning, settingName: .pitch, value: SGSimpleSettings.shared.darkgramVoiceLabPitchSliderValue()),
        .oneFromManySelector(id: id.count, section: .tuning, settingName: .exactPitch, text: "Darkgram.VoiceLab.Pitch".i18n(lang), value: darkgramVoiceLabPitchLabel(lang: lang), enabled: true),
        .oneFromManySelector(id: id.count, section: .tuning, settingName: .exactGain, text: "Darkgram.VoiceLab.Gain".i18n(lang), value: darkgramVoiceLabGainLabel(lang: lang), enabled: true),
        .action(id: id.count, section: .tuning, actionType: .reset, text: "Darkgram.VoiceLab.Reset".i18n(lang), kind: .generic),
        .notice(id: id.count, section: .tuning, text: "Darkgram.VoiceLab.Tuning.Notice".i18n(lang)),
        
        darkgramAccentHeader(id: id.count, section: .about, text: "Darkgram.VoiceLab.About.Header".i18n(lang), accent: .voiceGeneral),
        .notice(id: id.count, section: .about, text: "Darkgram.VoiceLab.About.Notice".i18n(lang))
    ])
    
    return entries
}

public func darkgramVoiceLabSettingsController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?
    let refreshPromise = ValuePromise(true, ignoreRepeated: false)
    
    let arguments = SGItemListArguments<DarkgramVoiceLabToggle, DarkgramVoiceLabSlider, DarkgramVoiceLabSelector, DarkgramVoiceLabSelector, DarkgramVoiceLabAction>(
        context: context,
        setBoolValue: { toggle, value in
            switch toggle {
            case .enabled:
                SGSimpleSettings.shared.darkgramVoiceLabEnabled = value
            case .applyToVoiceMessages:
                SGSimpleSettings.shared.darkgramVoiceLabApplyToVoiceMessages = value
            case .applyToCalls:
                SGSimpleSettings.shared.darkgramVoiceLabApplyToCalls = value
            case .applyToGroupCalls:
                SGSimpleSettings.shared.darkgramVoiceLabApplyToGroupCalls = value
            case .allowForwardWithVoiceChange:
                SGSimpleSettings.shared.darkgramVoiceLabAllowForwardWithVoiceChange = value
            case .preserveDuration:
                SGSimpleSettings.shared.darkgramVoiceLabPreserveDuration = value
            case .dontSendOnFailure:
                SGSimpleSettings.shared.darkgramVoiceLabDontSendOnFailure = value
                if !value {
                    SGSimpleSettings.shared.darkgramVoiceLabSendToSavedMessagesOnFailure = false
                }
            case .sendToSavedMessagesOnFailure:
                SGSimpleSettings.shared.darkgramVoiceLabSendToSavedMessagesOnFailure = value
            }
            refreshPromise.set(true)
        },
        updateSliderValue: { slider, value in
            switch slider {
            case .pitch:
                SGSimpleSettings.shared.setDarkgramVoiceLabPitchSliderValue(value)
            }
            refreshPromise.set(true)
        },
        setOneFromManyValue: { selector in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let lang = presentationData.strings.baseLanguageCode
            
            switch selector {
            case .exactPitch:
                pushControllerImpl?(darkgramVoiceLabNumericValueController(
                    context: context,
                    title: "Darkgram.VoiceLab.Pitch".i18n(lang),
                    notice: "Darkgram.VoiceLab.Pitch.Notice".i18n(lang),
                    placeholder: "-1200 ... 1200",
                    currentValue: "\(SGSimpleSettings.shared.darkgramVoiceLabPitchCents)",
                    applyValue: { input in
                        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
                        let parsed = Int32(trimmed) ?? 0
                        SGSimpleSettings.shared.darkgramVoiceLabPitchCents = max(-1200, min(1200, parsed))
                        refreshPromise.set(true)
                    }
                ))
            case .exactGain:
                pushControllerImpl?(darkgramVoiceLabNumericValueController(
                    context: context,
                    title: "Darkgram.VoiceLab.Gain".i18n(lang),
                    notice: "Darkgram.VoiceLab.Gain.Notice".i18n(lang),
                    placeholder: "25 ... 200",
                    currentValue: "\(SGSimpleSettings.shared.darkgramVoiceLabOutputGainPercent)",
                    applyValue: { input in
                        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
                        let parsed = Int32(trimmed) ?? 100
                        SGSimpleSettings.shared.darkgramVoiceLabOutputGainPercent = max(25, min(200, parsed))
                        refreshPromise.set(true)
                    }
                ))
            }
        },
        action: { action in
            switch action {
            case .reset:
                SGSimpleSettings.shared.darkgramVoiceLabEnabled = false
                SGSimpleSettings.shared.darkgramVoiceLabApplyToVoiceMessages = true
                SGSimpleSettings.shared.darkgramVoiceLabApplyToCalls = false
                SGSimpleSettings.shared.darkgramVoiceLabApplyToGroupCalls = false
                SGSimpleSettings.shared.darkgramVoiceLabAllowForwardWithVoiceChange = false
                SGSimpleSettings.shared.darkgramVoiceLabPitchCents = 0
                SGSimpleSettings.shared.darkgramVoiceLabOutputGainPercent = 100
                SGSimpleSettings.shared.darkgramVoiceLabPreserveDuration = true
                SGSimpleSettings.shared.darkgramVoiceLabDontSendOnFailure = false
                SGSimpleSettings.shared.darkgramVoiceLabSendToSavedMessagesOnFailure = false
                refreshPromise.set(true)
            }
        }
    )
    
    let signal = combineLatest(context.sharedContext.presentationData, refreshPromise.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Darkgram.VoiceLab.Title".i18n(lang)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: darkgramVoiceLabEntries(presentationData: presentationData),
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

private enum DarkgramVoiceLabNumericSection: Int32, SGItemListSection {
    case editor
}

private typealias DarkgramVoiceLabNumericEntry = SGItemListUIEntry<DarkgramVoiceLabNumericSection, DarkgramVoiceLabToggle, DarkgramVoiceLabSlider, DarkgramVoiceLabSelector, DarkgramVoiceLabSelector, DarkgramVoiceLabAction>

private func darkgramVoiceLabNumericValueController(
    context: AccountContext,
    title: String,
    notice: String,
    placeholder: String,
    currentValue: String,
    applyValue: @escaping (String) -> Void
) -> ViewController {
    let textPromise = ValuePromise(currentValue, ignoreRepeated: false)
    let arguments = SGItemListArguments<DarkgramVoiceLabToggle, DarkgramVoiceLabSlider, DarkgramVoiceLabSelector, DarkgramVoiceLabSelector, DarkgramVoiceLabAction>(
        context: context,
        searchInput: { input in
            applyValue(input)
            textPromise.set(input)
        }
    )
    
    let signal = combineLatest(context.sharedContext.presentationData, textPromise.get())
    |> map { presentationData, value -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries: [DarkgramVoiceLabNumericEntry] = [
            .searchInput(id: 0, section: .editor, title: NSAttributedString(string: title), text: value, placeholder: placeholder),
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
