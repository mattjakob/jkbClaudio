import Foundation

struct TGResponse<T: Codable & Sendable>: Codable, Sendable {
    let ok: Bool
    let result: T?
    let description: String?
}

struct TGUpdate: Codable, Sendable {
    let updateId: Int
    let message: TGMessage?
    let callbackQuery: TGCallbackQuery?

    enum CodingKeys: String, CodingKey {
        case updateId = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

struct TGMessage: Codable, Sendable {
    let messageId: Int
    let from: TGUser?
    let chat: TGChat
    let text: String?
    let date: Int

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case from
        case chat
        case text
        case date
    }
}

struct TGCallbackQuery: Codable, Sendable {
    let id: String
    let from: TGUser
    let message: TGMessage?
    let data: String?
}

struct TGUser: Codable, Sendable {
    let id: Int
    let firstName: String
    let isBot: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case isBot = "is_bot"
    }
}

struct TGChat: Codable, Sendable {
    let id: Int
    let type: String
}

struct TGSendMessage: Codable, Sendable {
    let chatId: Int
    let text: String
    let parseMode: String?
    let replyMarkup: TGInlineKeyboardMarkup?

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case text
        case parseMode = "parse_mode"
        case replyMarkup = "reply_markup"
    }
}

struct TGInlineKeyboardMarkup: Codable, Sendable {
    let inlineKeyboard: [[TGInlineKeyboardButton]]

    enum CodingKeys: String, CodingKey {
        case inlineKeyboard = "inline_keyboard"
    }
}

struct TGInlineKeyboardButton: Codable, Sendable {
    let text: String
    let callbackData: String?

    enum CodingKeys: String, CodingKey {
        case text
        case callbackData = "callback_data"
    }
}

struct TGEditMessageReplyMarkup: Codable, Sendable {
    let chatId: Int
    let messageId: Int
    let replyMarkup: TGInlineKeyboardMarkup?

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case messageId = "message_id"
        case replyMarkup = "reply_markup"
    }
}
