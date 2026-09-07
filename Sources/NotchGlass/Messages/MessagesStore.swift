import Foundation
import SQLite3
import Contacts
import ObjCSupport

/// One recent conversation from the Messages database.
struct IMChat: Identifiable, Equatable {
    let id: Int64          // `chat.ROWID`
    let guid: String       // `chat.guid` — the AppleScript `chat id` for sending
    let handle: String     // `chat.chat_identifier` — phone/email, or a group id
    let displayName: String
    let lastText: String
    let lastFromMe: Bool
    let lastDate: Date
    /// Named group chats carry a `display_name`; 1:1s fall back to the raw handle.
    var title: String { displayName.isEmpty ? handle : displayName }
}

/// One message in a conversation.
struct IMMessage: Identifiable, Equatable {
    let id: Int64
    let text: String
    let fromMe: Bool
    let date: Date
}

/// Reads the local Messages database (`~/Library/Messages/chat.db`) for the recent
/// chats + their messages, and sends replies through Messages.app via AppleScript.
///
/// Everything is local: the read is a direct read-only SQLite open (fresh even while
/// Messages is running, since it honours the WAL), and message bodies are decoded from
/// the legacy `attributedBody` typedstream blob — on modern macOS the plain `text`
/// column is almost always NULL. Reading the file needs **Full Disk Access**; without
/// it the open fails and the tab shows a grant-access prompt. Sending triggers the
/// one-time Automation (Apple Events → Messages) consent.
@MainActor
final class MessagesStore: ObservableObject {
    /// Whether `chat.db` could be opened — false means Full Disk Access isn't granted.
    @Published var accessGranted = true
    @Published var chats: [IMChat] = []
    @Published var selectedChat: IMChat?
    @Published var messages: [IMMessage] = []
    @Published var sendError: String?

    private let dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"
    /// Seconds between 2001-01-01 (Apple's epoch) and 1970-01-01 (Unix).
    private static let appleEpoch: Double = 978_307_200
    private var pollTimer: Timer?
    /// Set once the DB has opened successfully. Guards `accessGranted` from flipping to
    /// the Full-Disk-Access prompt on a *transient* open failure (WAL checkpoint, brief
    /// lock) after we've already been reading fine.
    private var everOpened = false

    /// Handle → contact-name lookups, built once from Contacts. The Messages DB only
    /// stores handles (phone/email); names come from the address book. Phones are keyed
    /// by their last 9 digits so `+33 6…`, `06…` and `+336…` all match the same person.
    private var phoneNames: [String: String] = [:]
    private var emailNames: [String: String] = [:]
    private var contactsRequested = false

    // MARK: - Lifecycle (driven by the tab appearing / disappearing)

    func start() {
        loadContacts()
        refresh()
        // A gentle poll so new/incoming messages and sent replies show up without a
        // manual reload. Only runs while the tab is on screen (see `stop`).
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func select(_ chat: IMChat) {
        selectedChat = chat
        sendError = nil
        loadMessages(for: chat)
    }

    func back() {
        selectedChat = nil
        messages = []
    }

    /// Reload the chat list and, if one is open, its thread.
    func refresh() {
        loadChats()
        if let chat = selectedChat { loadMessages(for: chat) }
    }

    // MARK: - Reads

    private func loadChats() {
        guard let db = openDB() else {
            // Only surface the access prompt if we've *never* gotten in — otherwise this
            // is a transient failure and the open thread should stay put.
            if !everOpened { accessGranted = false }
            return
        }
        defer { sqlite3_close(db) }
        everOpened = true
        accessGranted = true

        // Each chat with its single latest message (for the preview line + ordering).
        let sql = """
        SELECT c.ROWID, c.guid, c.chat_identifier, IFNULL(c.display_name, ''),
               m.date, m.text, m.attributedBody, m.is_from_me
        FROM chat c
        JOIN chat_message_join j ON j.chat_id = c.ROWID
        JOIN message m ON m.ROWID = j.message_id
        WHERE m.ROWID = (
            SELECT j2.message_id FROM chat_message_join j2
            JOIN message m2 ON m2.ROWID = j2.message_id
            WHERE j2.chat_id = c.ROWID
            ORDER BY m2.date DESC LIMIT 1
        )
        ORDER BY m.date DESC
        LIMIT 40;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var rows: [IMChat] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            let guid = column(stmt, 1)
            let handle = column(stmt, 2)
            let display = column(stmt, 3)
            let date = decodeDate(sqlite3_column_int64(stmt, 4))
            let text = messageText(stmt, textCol: 5, blobCol: 6)
            let fromMe = sqlite3_column_int(stmt, 7) == 1
            // Named group chats keep their `display_name`; 1:1s resolve the handle to a
            // contact name (falling back to the raw handle via `IMChat.title`).
            let name = display.isEmpty ? (contactName(for: handle) ?? "") : display
            // A photo / tapback / other attachment-only latest message decodes to empty
            // text — show a placeholder rather than a blank preview line.
            rows.append(IMChat(id: rowid, guid: guid, handle: handle, displayName: name,
                               lastText: text.isEmpty ? "Attachment" : text,
                               lastFromMe: fromMe, lastDate: date))
        }
        // Avoid republishing (and rebuilding the list) when nothing changed.
        if rows != chats { chats = rows }
        // Keep the open thread's summary object in sync with the refreshed list.
        if let sel = selectedChat {
            let updated = rows.first { $0.id == sel.id } ?? sel
            if updated != selectedChat { selectedChat = updated }
        }
    }

    private func loadMessages(for chat: IMChat) {
        // `accessGranted` is owned by `loadChats`; a transient failure here just skips
        // this refresh rather than tearing down the open thread.
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date
        FROM message m
        JOIN chat_message_join j ON j.message_id = m.ROWID
        WHERE j.chat_id = ?
        ORDER BY m.date DESC
        LIMIT 60;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, chat.id)

        var rows: [IMMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = messageText(stmt, textCol: 1, blobCol: 2)
            guard !text.isEmpty else { continue }   // skip tapbacks / attachment-only rows
            rows.append(IMMessage(id: sqlite3_column_int64(stmt, 0),
                                  text: text,
                                  fromMe: sqlite3_column_int(stmt, 3) == 1,
                                  date: decodeDate(sqlite3_column_int64(stmt, 4))))
        }
        // Query is newest-first (so the LIMIT keeps the most recent); show oldest-first.
        let ordered = Array(rows.reversed())
        if ordered != messages { messages = ordered }
    }

    // MARK: - Send (AppleScript → Messages.app)

    /// Send `text` to the open chat via Messages.app. Outward-facing — only ever called
    /// from the reply field's Send. Runs `osascript` off the main thread so the UI never
    /// blocks, then refreshes so the sent line appears.
    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let chat = selectedChat else { return }
        sendError = nil
        let guid = chat.guid
        Task.detached(priority: .userInitiated) {
            let err = Self.runSend(text: text, chatGUID: guid)
            await MainActor.run {
                if let err { self.sendError = err } else { self.refresh() }
            }
        }
    }

    /// Escapes the text for an AppleScript string literal and sends to the existing
    /// thread by its GUID (works for both 1:1 and group chats).
    nonisolated private static func runSend(text: String, chatGUID: String) -> String? {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Messages"
            send "\(escaped)" to chat id "\(chatGUID)"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return "Couldn't reach Messages: \(error.localizedDescription)"
        }
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return msg.isEmpty ? "Message couldn't be sent." : msg
        }
        return nil
    }

    // MARK: - SQLite helpers

    /// Read-only open. `chat.db` is WAL-mode and Messages may be writing to it; a plain
    /// read-only open still reads the latest committed rows (verified against a live DB),
    /// so there's no need to copy the file. A failure here means no Full Disk Access.
    private func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 1500)
        return db
    }

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    /// Prefer the plain `text` column; fall back to decoding `attributedBody` (which is
    /// where the body lives on modern macOS).
    private func messageText(_ stmt: OpaquePointer?, textCol: Int32, blobCol: Int32) -> String {
        let plain = column(stmt, textCol)
        if !plain.isEmpty { return plain }
        if let bytes = sqlite3_column_blob(stmt, blobCol) {
            let count = Int(sqlite3_column_bytes(stmt, blobCol))
            if count > 0 {
                let data = Data(bytes: bytes, count: count)
                return Self.decodeAttributedBody(data) ?? ""
            }
        }
        return ""
    }

    private func decodeDate(_ raw: Int64) -> Date {
        // Modern rows are Apple-epoch *nanoseconds*; very old ones were seconds.
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSince1970: seconds + Self.appleEpoch)
    }

    /// Decode a Messages `attributedBody` blob to its text. The blob is a legacy
    /// `streamtyped` NSArchiver stream; `NSUnarchiver` (deprecated but present on macOS)
    /// turns it straight into an `NSAttributedString`. We only attempt it on data that
    /// actually starts with the typedstream magic, so `NSUnarchiver` never sees input
    /// that could make it raise an (uncatchable) Objective-C exception.
    nonisolated private static func decodeAttributedBody(_ data: Data) -> String? {
        let magic: [UInt8] = [0x04, 0x0b] + Array("streamtyped".utf8)
        guard data.count > magic.count, data.starts(with: magic) else { return nil }
        guard let cls = NSClassFromString("NSUnarchiver") else { return nil }
        let sel = NSSelectorFromString("unarchiveObjectWithData:")
        guard (cls as AnyObject).responds(to: sel) else { return nil }
        // Guard against a malformed blob making NSUnarchiver raise an (uncatchable in
        // Swift) Obj-C exception, on top of the typedstream-magic check above.
        var result: String?
        _ = NGRunCatchingExceptions {
            guard let obj = (cls as AnyObject).perform(sel, with: data)?.takeUnretainedValue()
            else { return }
            if let attr = obj as? NSAttributedString { result = attr.string }
            else if let str = obj as? NSString { result = str as String }
        }
        return result
    }

    // MARK: - Contacts

    /// Build the handle → name maps from Contacts (once). Enumerates off the main
    /// thread — `enumerateContacts` is blocking — then hops back to publish and refresh
    /// so resolved names appear. If access is denied, handles are shown as-is.
    private func loadContacts() {
        guard !contactsRequested else { return }
        contactsRequested = true
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { [weak self] granted, _ in
            guard granted else { return }
            // Must include every key the formatter reads — otherwise touching an
            // unfetched key (e.g. a middle name) makes `enumerateContacts` raise an
            // Obj-C exception that Swift's `try?` can't catch, aborting the app.
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
            ]
            var phones: [String: String] = [:]
            var emails: [String: String] = [:]
            let request = CNContactFetchRequest(keysToFetch: keys)
            try? store.enumerateContacts(with: request) { contact, _ in
                let full = CNContactFormatter.string(from: contact, style: .fullName)
                let name = (full?.isEmpty == false ? full : nil) ?? contact.organizationName
                guard !name.isEmpty else { return }
                for phone in contact.phoneNumbers {
                    if let key = Self.phoneKey(phone.value.stringValue) { phones[key] = name }
                }
                for email in contact.emailAddresses {
                    emails[(email.value as String).lowercased()] = name
                }
            }
            Task { @MainActor [weak self] in
                self?.phoneNames = phones
                self?.emailNames = emails
                self?.refresh()   // re-map the already-loaded chats with real names
            }
        }
    }

    /// The name for a handle, or nil if it isn't in Contacts.
    private func contactName(for handle: String) -> String? {
        if handle.contains("@") { return emailNames[handle.lowercased()] }
        if let key = Self.phoneKey(handle) { return phoneNames[key] }
        return nil
    }

    /// Normalize a phone handle to a comparable key: its last 9 digits, so the same
    /// number matches across national/international formats. Nil for non-phone handles.
    nonisolated private static func phoneKey(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(9))
    }
}
