import Foundation
import Postbox
import TelegramCore
import AccountContext
import ChatInterfaceState
import SGSimpleSettings

func darkgramReplySubject(
    context: AccountContext,
    message: Message,
    todoItemId: Int32?
) -> ChatInterfaceState.ReplyMessageSubject? {
    let isDeletedMessage = darkgramArchivedState(message: message) == .deleted
    if isDeletedMessage && !SGSimpleSettings.shared.darkgramReplyToDeletedMessagesEnabled {
        return nil
    }
    
    let effectiveMessage: Message
    if isDeletedMessage {
        effectiveMessage = darkgramResolvedMediaMessage(
            accountBasePath: context.account.basePath,
            message: message
        )
    } else {
        effectiveMessage = message
    }
    
    let shouldAttachQuote = SGSimpleSettings.shared.darkgramQuotedRepliesEnabled || isDeletedMessage
    let quote = shouldAttachQuote ? darkgramReplyQuote(
        message: effectiveMessage,
        appConfig: context.currentAppConfiguration.with({ $0 })
    ) : nil
    
    return ChatInterfaceState.ReplyMessageSubject(
        messageId: effectiveMessage.id,
        quote: quote,
        todoItemId: todoItemId
    )
}
