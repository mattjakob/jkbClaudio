import Foundation

actor TelegramService {
    private let baseURL: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var offset: Int = 0
    private var pollingTask: Task<Void, Never>?

    private(set) var chatId: Int?

    func setChatId(_ id: Int) { chatId = id }

    var isConfigured: Bool { !baseURL.isEmpty }

    init(token: String) {
        baseURL = token.isEmpty ? "" : "https://api.telegram.org/bot\(token)/"
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 35
        session = URLSession(configuration: config)
    }

    // MARK: - Polling

    func startPolling(handler: @escaping @Sendable (TGUpdate) async -> Void) {
        pollingTask?.cancel()
        pollingTask = Task {
            var consecutiveErrors = 0

            while !Task.isCancelled {
                do {
                    let updates = try await getUpdates(timeout: 30)
                    consecutiveErrors = 0
                    for update in updates {
                        offset = update.updateId + 1
                        await handler(update)
                    }
                } catch {
                    if Task.isCancelled { return }
                    consecutiveErrors += 1
                    let delay = backoffDelay(attempt: consecutiveErrors)
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s (capped), with jitter.
    private func backoffDelay(attempt: Int) -> Double {
        let base = min(pow(2.0, Double(attempt - 1)), 30.0)
        let jitter = Double.random(in: 0...1)
        return base + jitter
    }

    // MARK: - API Methods

    func getUpdates(timeout: Int = 30) async throws -> [TGUpdate] {
        struct Body: Encodable {
            let offset: Int
            let timeout: Int
            let allowed_updates: [String]
        }

        let body = Body(
            offset: offset,
            timeout: timeout,
            allowed_updates: ["message", "callback_query"]
        )

        return try await post("getUpdates", body: body)
    }

    @discardableResult
    func sendMessage(
        chatId: Int,
        text: String,
        parseMode: String? = nil,
        replyMarkup: TGInlineKeyboardMarkup? = nil
    ) async throws -> TGMessage {
        let body = TGSendMessage(
            chatId: chatId,
            text: text,
            parseMode: parseMode,
            replyMarkup: replyMarkup
        )

        return try await post("sendMessage", body: body)
    }

    func answerCallbackQuery(id: String, text: String? = nil) async throws {
        struct Body: Encodable {
            let callback_query_id: String
            let text: String?
        }

        let _: Bool = try await post(
            "answerCallbackQuery",
            body: Body(callback_query_id: id, text: text)
        )
    }

    func editMessageReplyMarkup(chatId: Int, messageId: Int) async throws {
        let body = TGEditMessageReplyMarkup(
            chatId: chatId,
            messageId: messageId,
            replyMarkup: nil
        )

        let _: Bool = try await post("editMessageReplyMarkup", body: body)
    }

    func getMe() async throws -> TGUser {
        struct Empty: Encodable {}
        return try await post("getMe", body: Empty())
    }

    func setMyCommands(_ commands: [TGBotCommand]) async throws {
        let body = TGSetMyCommands(commands: commands)
        let _: Bool = try await post("setMyCommands", body: body)
    }

    func setMyDescription(_ description: String) async throws {
        let body = TGSetMyDescription(description: description)
        let _: Bool = try await post("setMyDescription", body: body)
    }

    /// Send a message, returning true on success. Logs failures but does not throw.
    @discardableResult
    func send(_ text: String, replyMarkup: TGInlineKeyboardMarkup? = nil) async -> Bool {
        guard let chatId else { return false }

        let truncated = text.count > 4000 ? String(text.prefix(4000)) : text

        do {
            _ = try await sendMessage(
                chatId: chatId,
                text: truncated,
                parseMode: "HTML",
                replyMarkup: replyMarkup
            )
            return true
        } catch {
            // Fall back to plain text if HTML parsing failed
            if let data = (error as? TelegramAPIError)?.description,
               data.contains("can't parse entities") {
                _ = try? await sendMessage(chatId: chatId, text: truncated)
            }
            return false
        }
    }

    // MARK: - Private

    private func post<B: Encodable, R: Codable & Sendable>(
        _ method: String,
        body: B
    ) async throws -> R {
        let url = URL(string: baseURL + method)!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let decoded = try decoder.decode(TGResponse<R>.self, from: data)

        guard decoded.ok, let result = decoded.result else {
            throw TelegramAPIError(
                code: http.statusCode,
                description: decoded.description ?? "Unknown error"
            )
        }

        return result
    }
}

/// Typed error for Telegram API failures
struct TelegramAPIError: Error, Sendable {
    let code: Int
    let description: String
}
