import Foundation

// MARK: - Book identity

public enum BookFormat: String, Codable, Sendable, CaseIterable {
    case fb2
    case epub

    public var fileExtension: String { rawValue }
}

/// Chapters and their blocks are the single source of truth for translation and
/// rendering. Everything else on disk is derived from `chapters.json`.
public enum BlockKind: String, Codable, Sendable, CaseIterable {
    case heading
    case paragraph
    case listItem
    case blockquote
    case note
    case table
    case image
    case hr

    /// Only these kinds contribute characters to the translation budget and
    /// produce units in the batch plan.
    public var isTranslatable: Bool {
        switch self {
        case .heading, .paragraph, .listItem, .blockquote, .note: return true
        case .table, .image, .hr: return false
        }
    }
}

public struct Block: Codable, Sendable, Hashable {
    /// Stable within a book, assigned at import in reading order from 0.
    public var id: Int
    public var kind: BlockKind
    /// Flat text; the translation input.
    public var text: String
    /// Inline markup used to render the original.
    public var html: String
    /// Full element markup, only for `kind == .table`.
    public var rawHTML: String?
    /// `images/<file>` relative to the book directory, only for `.image`.
    public var imageRef: String?

    public init(
        id: Int,
        kind: BlockKind,
        text: String,
        html: String? = nil,
        rawHTML: String? = nil,
        imageRef: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.html = html ?? Self.escape(text)
        self.rawHTML = rawHTML
        self.imageRef = imageRef
    }

    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(ch)
            }
        }
        return out
    }
}

public struct Chapter: Codable, Sendable, Identifiable {
    public var index: Int
    public var title: String
    /// Source document path inside the EPUB; empty for FB2.
    public var docHref: String
    public var blocks: [Block]

    public var id: Int { index }

    public init(index: Int, title: String, docHref: String = "", blocks: [Block]) {
        self.index = index
        self.title = title
        self.docHref = docHref
        self.blocks = blocks
    }

    private enum CodingKeys: String, CodingKey {
        case index, title, docHref, blocks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        docHref = try c.decodeIfPresent(String.self, forKey: .docHref) ?? ""
        blocks = try c.decodeIfPresent([Block].self, forKey: .blocks) ?? []
    }
}

public struct BookMeta: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var author: String
    public var format: BookFormat
    public var sourceLang: String
    public var targetLang: String
    public var charCount: Int
    public var chapterCount: Int
    public var batchCount: Int
    /// Relative to the book directory, e.g. `parsed/images/cover.jpg`.
    public var coverPath: String?
    public var createdAt: Date
    public var schemaVersion: Int

    public static let currentSchemaVersion = 1

    public init(
        id: String,
        title: String,
        author: String,
        format: BookFormat,
        sourceLang: String = "en",
        targetLang: String = "ru",
        charCount: Int,
        chapterCount: Int,
        batchCount: Int,
        coverPath: String? = nil,
        createdAt: Date = Date(),
        schemaVersion: Int = BookMeta.currentSchemaVersion
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.sourceLang = sourceLang
        self.targetLang = targetLang
        self.charCount = charCount
        self.chapterCount = chapterCount
        self.batchCount = batchCount
        self.coverPath = coverPath
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, author, format, sourceLang, targetLang, charCount
        case chapterCount, batchCount, coverPath, createdAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        format = try c.decodeIfPresent(BookFormat.self, forKey: .format) ?? .fb2
        sourceLang = try c.decodeIfPresent(String.self, forKey: .sourceLang) ?? "en"
        targetLang = try c.decodeIfPresent(String.self, forKey: .targetLang) ?? "ru"
        charCount = try c.decodeIfPresent(Int.self, forKey: .charCount) ?? 0
        chapterCount = try c.decodeIfPresent(Int.self, forKey: .chapterCount) ?? 0
        batchCount = try c.decodeIfPresent(Int.self, forKey: .batchCount) ?? 0
        coverPath = try c.decodeIfPresent(String.self, forKey: .coverPath)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}

// MARK: - Batch plan

public enum BatchStatus: String, Codable, Sendable {
    case pending
    case running
    case done
    case failed
}

/// One line of the model's answer. A long source block is split into several
/// units (`part` 0..k) so that no single answer line exceeds `target` chars.
public struct PlanUnit: Codable, Sendable, Hashable {
    public var block: Int
    public var part: Int
    public var text: String

    public init(block: Int, part: Int, text: String) {
        self.block = block
        self.part = part
        self.text = text
    }
}

public struct Batch: Codable, Sendable, Identifiable {
    public var index: Int
    public var chars: Int
    public var status: BatchStatus
    public var attempts: Int
    public var error: String?
    public var finishedAt: Date?
    public var units: [PlanUnit]
    /// True once the lookahead terminology request has run for this batch.
    /// Without it every retry would spend another request on the same text.
    public var lookaheadDone: Bool

    public var id: Int { index }

    public init(
        index: Int,
        chars: Int,
        status: BatchStatus = .pending,
        attempts: Int = 0,
        error: String? = nil,
        finishedAt: Date? = nil,
        units: [PlanUnit],
        lookaheadDone: Bool = false
    ) {
        self.index = index
        self.chars = chars
        self.status = status
        self.attempts = attempts
        self.error = error
        self.finishedAt = finishedAt
        self.units = units
        self.lookaheadDone = lookaheadDone
    }

    private enum CodingKeys: String, CodingKey {
        case index, chars, status, attempts, error, finishedAt, units, lookaheadDone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        chars = try c.decodeIfPresent(Int.self, forKey: .chars) ?? 0
        status = try c.decodeIfPresent(BatchStatus.self, forKey: .status) ?? .pending
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        units = try c.decodeIfPresent([PlanUnit].self, forKey: .units) ?? []
        lookaheadDone = try c.decodeIfPresent(Bool.self, forKey: .lookaheadDone) ?? false
    }
}

public struct BatchPlan: Codable, Sendable {
    /// Clamped 5% character budget, in characters.
    public var target: Int
    public var totalChars: Int
    public var batches: [Batch]

    public init(target: Int, totalChars: Int, batches: [Batch]) {
        self.target = target
        self.totalChars = totalChars
        self.batches = batches
    }

    public var doneCount: Int { batches.filter { $0.status == .done }.count }

    public var nextPendingIndex: Int? {
        batches.first { $0.status != .done }?.index
    }
}

// MARK: - Batch results and glossary

public struct GlossaryAddition: Codable, Sendable, Hashable {
    public var term: String
    public var translation: String
    public var note: String

    public init(term: String, translation: String, note: String = "") {
        self.term = term
        self.translation = translation
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case term, translation, note }

    public init(from decoder: Decoder) throws {
        // The model occasionally omits `note` or sends null.
        if let single = try? decoder.singleValueContainer(), let string = try? single.decode(String.self) {
            term = string
            translation = ""
            note = ""
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        term = try c.decodeIfPresent(String.self, forKey: .term) ?? ""
        translation = try c.decodeIfPresent(String.self, forKey: .translation) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

public struct BatchResult: Codable, Sendable {
    public var index: Int
    public var createdAt: Date
    public var modelId: String
    /// Exactly as many entries as the batch has units.
    public var translations: [String]
    public var glossaryAdditions: [GlossaryAddition]
    public var rawChars: Int

    public init(
        index: Int,
        createdAt: Date = Date(),
        modelId: String,
        translations: [String],
        glossaryAdditions: [GlossaryAddition] = [],
        rawChars: Int = 0
    ) {
        self.index = index
        self.createdAt = createdAt
        self.modelId = modelId
        self.translations = translations
        self.glossaryAdditions = glossaryAdditions
        self.rawChars = rawChars
    }

    private enum CodingKeys: String, CodingKey {
        case index, createdAt, modelId, translations, glossaryAdditions, rawChars
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId) ?? ""
        translations = try c.decodeIfPresent([String].self, forKey: .translations) ?? []
        glossaryAdditions = try c.decodeIfPresent([GlossaryAddition].self, forKey: .glossaryAdditions) ?? []
        rawChars = try c.decodeIfPresent(Int.self, forKey: .rawChars) ?? 0
    }
}

public enum TermKind: String, Codable, Sendable {
    case term
    case abbr
    case name
}

public enum TermSource: String, Codable, Sendable {
    case auto
    case user
}

public struct GlossaryTerm: Codable, Sendable, Hashable {
    /// `term.lowercased()` — the merge key.
    public var key: String
    public var term: String
    public var translation: String
    public var note: String
    public var kind: TermKind
    public var source: TermSource
    public var count: Int
    /// Id of the first block the term was seen in; -1 when unknown.
    public var firstBlock: Int
    public var updatedAt: Date

    public init(
        term: String,
        translation: String,
        note: String = "",
        kind: TermKind = .term,
        source: TermSource = .auto,
        count: Int = 1,
        firstBlock: Int = -1,
        updatedAt: Date = Date()
    ) {
        self.key = GlossaryTerm.key(for: term)
        self.term = term
        self.translation = translation
        self.note = note
        self.kind = kind
        self.source = source
        self.count = count
        self.firstBlock = firstBlock
        self.updatedAt = updatedAt
    }

    public static func key(for term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case key, term, translation, note, kind, source, count, firstBlock, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        term = try c.decodeIfPresent(String.self, forKey: .term) ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? GlossaryTerm.key(for: term)
        translation = try c.decodeIfPresent(String.self, forKey: .translation) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        kind = try c.decodeIfPresent(TermKind.self, forKey: .kind) ?? .term
        source = try c.decodeIfPresent(TermSource.self, forKey: .source) ?? .auto
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
        firstBlock = try c.decodeIfPresent(Int.self, forKey: .firstBlock) ?? -1
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

public struct Glossary: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var terms: [GlossaryTerm]

    public init(version: Int = Glossary.currentVersion, terms: [GlossaryTerm] = []) {
        self.version = version
        self.terms = terms
    }

    public var isEmpty: Bool { terms.isEmpty }

    private enum CodingKeys: String, CodingKey { case version, terms }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        terms = try c.decodeIfPresent([GlossaryTerm].self, forKey: .terms) ?? []
    }
}

// MARK: - Queue state and reading progress

public enum QueueStatus: String, Codable, Sendable {
    case idle
    case running
    case paused
    case waitingQuota
    case waitingAuth
    case failed

    public var isActive: Bool {
        self == .running || self == .waitingQuota || self == .waitingAuth
    }
}

public struct QueueState: Codable, Sendable {
    public var status: QueueStatus
    public var bookId: String?
    public var currentBatch: Int
    public var message: String?
    public var updatedAt: Date

    public init(
        status: QueueStatus = .idle,
        bookId: String? = nil,
        currentBatch: Int = 0,
        message: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.status = status
        self.bookId = bookId
        self.currentBatch = currentBatch
        self.message = message
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case status, bookId, currentBatch, message, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(QueueStatus.self, forKey: .status) ?? .idle
        bookId = try c.decodeIfPresent(String.self, forKey: .bookId)
        currentBatch = try c.decodeIfPresent(Int.self, forKey: .currentBatch) ?? 0
        message = try c.decodeIfPresent(String.self, forKey: .message)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

public struct ReadingProgress: Codable, Sendable {
    public var chapterIndex: Int
    public var blockId: Int
    /// Pixel offset of the block's top from the viewport top.
    public var dy: Int
    /// Reader mode toggle; persisted here rather than in book.json because it is
    /// per-device reading state.
    public var showTranslation: Bool
    public var updatedAt: Date

    public init(
        chapterIndex: Int = 0,
        blockId: Int = 0,
        dy: Int = 0,
        showTranslation: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.chapterIndex = chapterIndex
        self.blockId = blockId
        self.dy = dy
        self.showTranslation = showTranslation
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case chapterIndex, blockId, dy, showTranslation, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapterIndex = try c.decodeIfPresent(Int.self, forKey: .chapterIndex) ?? 0
        blockId = try c.decodeIfPresent(Int.self, forKey: .blockId) ?? 0
        dy = try c.decodeIfPresent(Int.self, forKey: .dy) ?? 0
        showTranslation = try c.decodeIfPresent(Bool.self, forKey: .showTranslation) ?? true
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

// MARK: - Library

public struct LibraryEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var author: String
    public var coverPath: String?
    public var batchesDone: Int
    public var batchesTotal: Int
    public var status: QueueStatus
    public var lastOpenedAt: Date

    public init(
        id: String,
        title: String,
        author: String,
        coverPath: String? = nil,
        batchesDone: Int = 0,
        batchesTotal: Int = 0,
        status: QueueStatus = .idle,
        lastOpenedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverPath = coverPath
        self.batchesDone = batchesDone
        self.batchesTotal = batchesTotal
        self.status = status
        self.lastOpenedAt = lastOpenedAt
    }

    public var progressFraction: Double {
        guard batchesTotal > 0 else { return 0 }
        return Double(batchesDone) / Double(batchesTotal)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, author, coverPath, batchesDone, batchesTotal, status, lastOpenedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        coverPath = try c.decodeIfPresent(String.self, forKey: .coverPath)
        batchesDone = try c.decodeIfPresent(Int.self, forKey: .batchesDone) ?? 0
        batchesTotal = try c.decodeIfPresent(Int.self, forKey: .batchesTotal) ?? 0
        status = try c.decodeIfPresent(QueueStatus.self, forKey: .status) ?? .idle
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt) ?? Date()
    }
}
