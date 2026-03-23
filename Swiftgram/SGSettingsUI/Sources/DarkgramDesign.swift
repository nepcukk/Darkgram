import Foundation
import UIKit
import ItemListUI
import SGItemListUI
import TelegramCore

let darkgramCurrentVersion = "1.1.2"

struct DarkgramAccentBadge {
    let text: String
    let style: ItemListSectionHeaderItem.BadgeStyle
}

enum DarkgramAccentSection {
    case root
    case aiProviders
    case aiFeatures
    case aiPrivacy
    case aiDebate
    case encryptionGeneral
    case encryptionPassword
    case encryptionAbout
    case voiceGeneral
    case voiceTuning
    case archiveSpy
    case archiveMessageSaving
    case archiveRetention
    case archiveContent
    case ghostPrivacy
    case ghostPackets
    case ghostDelivery
    case qolCore
    case qolFilters
    case syncGeneral
    case syncActions
    case syncDebug
    case customizationMarks
    case customizationQuickActions
}

private func darkgramColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1.0) -> UIColor {
    return UIColor(red: red / 255.0, green: green / 255.0, blue: blue / 255.0, alpha: alpha)
}

private enum DarkgramPalette {
    static let night = darkgramColor(10, 14, 24)
    static let graphite = darkgramColor(22, 27, 39)
    static let purple = darkgramColor(124, 58, 237)
    static let violet = darkgramColor(139, 92, 246)
    static let blue = darkgramColor(37, 99, 235)
    static let cyan = darkgramColor(6, 182, 212)
    static let ice = darkgramColor(231, 238, 255)
    static let lavender = darkgramColor(221, 214, 254)
    static let sky = darkgramColor(191, 219, 254)
}

func darkgramAccentBadge(_ section: DarkgramAccentSection) -> DarkgramAccentBadge {
    switch section {
    case .root:
        return DarkgramAccentBadge(
            text: "AYU",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.graphite.withAlphaComponent(0.92),
                foreground: DarkgramPalette.lavender
            )
        )
    case .aiProviders:
        return DarkgramAccentBadge(
            text: "MODELS",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.blue.withAlphaComponent(0.18),
                foreground: DarkgramPalette.sky
            )
        )
    case .aiFeatures:
        return DarkgramAccentBadge(
            text: "AI",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.purple.withAlphaComponent(0.18),
                foreground: DarkgramPalette.lavender
            )
        )
    case .aiPrivacy:
        return DarkgramAccentBadge(
            text: "PRIVACY",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.graphite.withAlphaComponent(0.92),
                foreground: DarkgramPalette.ice
            )
        )
    case .aiDebate:
        return DarkgramAccentBadge(
            text: "DEBATE",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.cyan.withAlphaComponent(0.18),
                foreground: DarkgramPalette.ice
            )
        )
    case .encryptionGeneral:
        return DarkgramAccentBadge(
            text: "LOCK",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.violet.withAlphaComponent(0.18),
                foreground: DarkgramPalette.lavender
            )
        )
    case .encryptionPassword:
        return DarkgramAccentBadge(
            text: "KEY",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.blue.withAlphaComponent(0.18),
                foreground: DarkgramPalette.sky
            )
        )
    case .encryptionAbout:
        return DarkgramAccentBadge(
            text: "AES",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.graphite.withAlphaComponent(0.92),
                foreground: DarkgramPalette.ice
            )
        )
    case .voiceGeneral:
        return DarkgramAccentBadge(
            text: "VOICE",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.violet.withAlphaComponent(0.18),
                foreground: DarkgramPalette.lavender
            )
        )
    case .voiceTuning:
        return DarkgramAccentBadge(
            text: "TUNE",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.blue.withAlphaComponent(0.18),
                foreground: DarkgramPalette.sky
            )
        )
    case .archiveSpy:
        return DarkgramAccentBadge(
            text: "SPY",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.purple.withAlphaComponent(0.18),
                foreground: DarkgramPalette.lavender
            )
        )
    case .archiveMessageSaving:
        return DarkgramAccentBadge(
            text: "MEDIA",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.blue.withAlphaComponent(0.18),
                foreground: DarkgramPalette.sky
            )
        )
    case .archiveRetention:
        return DarkgramAccentBadge(
            text: "KEEP",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.night.withAlphaComponent(0.92),
                foreground: DarkgramPalette.ice
            )
        )
    case .archiveContent:
        return DarkgramAccentBadge(
            text: "CHATS",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.cyan.withAlphaComponent(0.16),
                foreground: DarkgramPalette.ice
            )
        )
    case .ghostPrivacy:
        return DarkgramAccentBadge(
            text: "STEALTH",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.purple.withAlphaComponent(0.2),
                foreground: DarkgramPalette.lavender
            )
        )
    case .ghostPackets:
        return DarkgramAccentBadge(
            text: "PACKETS",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.blue.withAlphaComponent(0.2),
                foreground: DarkgramPalette.sky
            )
        )
    case .ghostDelivery:
        return DarkgramAccentBadge(
            text: "DELAY",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.graphite.withAlphaComponent(0.92),
                foreground: DarkgramPalette.ice
            )
        )
    case .qolCore:
        return DarkgramAccentBadge(
            text: "CORE",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.violet.withAlphaComponent(0.18),
                foreground: DarkgramPalette.lavender
            )
        )
    case .qolFilters:
        return DarkgramAccentBadge(
            text: "FILTERS",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.cyan.withAlphaComponent(0.18),
                foreground: DarkgramPalette.ice
            )
        )
    case .syncGeneral:
        return DarkgramAccentBadge(
            text: "LINK",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.blue.withAlphaComponent(0.18),
                foreground: DarkgramPalette.sky
            )
        )
    case .syncActions:
        return DarkgramAccentBadge(
            text: "CTRL",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.purple.withAlphaComponent(0.18),
                foreground: DarkgramPalette.lavender
            )
        )
    case .syncDebug:
        return DarkgramAccentBadge(
            text: "DEBUG",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.graphite.withAlphaComponent(0.92),
                foreground: DarkgramPalette.ice
            )
        )
    case .customizationMarks:
        return DarkgramAccentBadge(
            text: "MARKS",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.purple.withAlphaComponent(0.18),
                foreground: DarkgramPalette.lavender
            )
        )
    case .customizationQuickActions:
        return DarkgramAccentBadge(
            text: "MENU",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.blue.withAlphaComponent(0.18),
                foreground: DarkgramPalette.sky
            )
        )
    }
}

func darkgramSyncDebugBadge(state: DarkgramSyncRuntimeState) -> DarkgramAccentBadge {
    switch state.connectionState {
    case .connected:
        return DarkgramAccentBadge(
            text: "LIVE",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.cyan.withAlphaComponent(0.22),
                foreground: DarkgramPalette.ice
            )
        )
    case .connecting, .registering:
        return DarkgramAccentBadge(
            text: "BOOT",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.blue.withAlphaComponent(0.2),
                foreground: DarkgramPalette.sky
            )
        )
    case .disabled:
        return DarkgramAccentBadge(
            text: "OFF",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.graphite.withAlphaComponent(0.92),
                foreground: DarkgramPalette.ice
            )
        )
    case .disconnected, .notRegistered, .noToken:
        return DarkgramAccentBadge(
            text: "WAIT",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: DarkgramPalette.violet.withAlphaComponent(0.18),
                foreground: DarkgramPalette.lavender
            )
        )
    case .invalidConfiguration, .invalidToken:
        return DarkgramAccentBadge(
            text: "FAIL",
            style: ItemListSectionHeaderItem.BadgeStyle(
                background: darkgramColor(127, 29, 29, 0.85),
                foreground: darkgramColor(254, 226, 226)
            )
        )
    }
}

func darkgramAccentHeader<Section, BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>(
    id: Int,
    section: Section,
    text: String,
    accent: DarkgramAccentSection,
    badgeOverride: String? = nil
) -> SGItemListUIEntry<Section, BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType> where Section: SGItemListSection {
    let badge = darkgramAccentBadge(accent)
    return .accentHeader(id: id, section: section, text: text, badge: badgeOverride ?? badge.text, badgeStyle: badge.style)
}
