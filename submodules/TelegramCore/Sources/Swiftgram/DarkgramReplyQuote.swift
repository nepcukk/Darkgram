import Foundation
import Postbox

private func darkgramReplyQuoteFallbackText(_ message: Message) -> String {
    let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedText.isEmpty {
        return trimmedText
    }
    
    for media in message.media {
        if media is TelegramMediaImage {
            return "Photo"
        } else if let file = media as? TelegramMediaFile {
            if file.isInstantVideo {
                return "Round Video"
            }
            if file.isVoice {
                return "Voice Message"
            }
            if file.isVideo {
                return "Video"
            }
            if file.isMusic {
                return "Audio"
            }
            if let fileName = file.fileName, !fileName.isEmpty {
                return fileName
            }
            return "File"
        } else if media is TelegramMediaPoll {
            return "Poll"
        } else if media is TelegramMediaMap {
            return "Location"
        } else if media is TelegramMediaContact {
            return "Contact"
        }
    }
    
    return "Message"
}

public func darkgramReplyQuoteMedia(message: Message) -> Media? {
    for media in message.media {
        switch media {
        case _ as TelegramMediaImage, _ as TelegramMediaFile:
            return media
        default:
            break
        }
    }
    return nil
}

public func darkgramReplyQuote(message: Message, appConfig: AppConfiguration) -> EngineMessageReplyQuote? {
    let baseText = darkgramReplyQuoteFallbackText(message)
    let nsText = baseText as NSString
    let entities: [MessageTextEntity]
    if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        entities = []
    } else {
        entities = messageTextEntitiesInRange(
            entities: message.textEntitiesAttribute?.entities ?? [],
            range: NSRange(location: 0, length: (message.text as NSString).length),
            onlyQuoteable: true
        )
    }
    let trimmedText = trimStringWithEntities(
        string: baseText,
        entities: entities,
        maxLength: quoteMaxLength(appConfig: appConfig)
    )
    let finalText: String
    let finalEntities: [MessageTextEntity]
    if trimmedText.string.isEmpty {
        finalText = nsText.substring(with: NSRange(location: 0, length: min(nsText.length, quoteMaxLength(appConfig: appConfig))))
        finalEntities = []
    } else {
        finalText = trimmedText.string
        finalEntities = trimmedText.entities
    }
    
    let replyMedia = darkgramReplyQuoteMedia(message: message)
    if finalText.isEmpty && replyMedia == nil {
        return nil
    }
    return EngineMessageReplyQuote(
        text: finalText,
        offset: nil,
        entities: finalEntities,
        media: replyMedia
    )
}

public func darkgramShiftMessageTextEntities(_ entities: [MessageTextEntity], by offset: Int) -> [MessageTextEntity] {
    guard offset != 0 else {
        return entities
    }
    return entities.map { entity in
        MessageTextEntity(
            range: (entity.range.lowerBound + offset) ..< (entity.range.upperBound + offset),
            type: entity.type
        )
    }
}

public func darkgramReplyQuotePrefixText(_ quote: EngineMessageReplyQuote) -> String {
    return quote.text.trimmingCharacters(in: .whitespacesAndNewlines)
}
