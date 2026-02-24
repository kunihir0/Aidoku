//
//  ReaderViewModel.swift
//  Aidoku (iOS)
//
//  Created by Gemini on 2/16/26.
//

import AidokuRunner
import Foundation

@MainActor
public class ReaderViewModel: ObservableObject {
    let source: AidokuRunner.Source?
    let manga: AidokuRunner.Manga

    @Published var chapter: AidokuRunner.Chapter
    @Published var pages: [Page] = []
    @Published var readingMode: ReadingMode = .rtl
    @Published var currentPage = 1

    var chapterList: [AidokuRunner.Chapter] = []
    var chaptersToMark: [AidokuRunner.Chapter] = []
    var chaptersToRemoveDownload: [AidokuRunner.Chapter] = [] {
        didSet {
            // ensure chapters queued for deletion are persistent, in case of app termination
            if chaptersToRemoveDownload.isEmpty {
                UserDefaults.standard.removeObject(forKey: "chaptersToBeDeleted")
            } else {
                let data = try? JSONEncoder().encode(chaptersToRemoveDownload.map {
                    ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key)
                })
                UserDefaults.standard.set(data, forKey: "chaptersToBeDeleted")
            }
        }
    }

    private var sessionReadPages: Set<Int> = []
    private var sessionStartDate: Date?
    private var sessionLastInteraction: Date?

    var defaultReadingMode: ReadingMode?

    public init(source: AidokuRunner.Source?, manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) {
        self.source = source
        self.manga = manga
        self.chapter = chapter
        self.chapterList = manga.chapters ?? []
        self.chaptersToMark = [chapter]

        self.defaultReadingMode = switch manga.viewer {
            case .rightToLeft: .rtl
            case .leftToRight: .ltr
            case .vertical: .vertical
            case .webtoon: .webtoon
            case .unknown: .none
        }
    }

    func loadChapterList() async {
        let updatedManga = try? await source?.getMangaUpdate(
            manga: manga,
            needsDetails: false,
            needsChapters: true
        )
        chapterList = updatedManga?.chapters ?? []
    }

    func loadCurrentChapter() -> Int {
        if chapterList.isEmpty {
            Task {
                await loadChapterList()
            }
        }

        let (completed, startPage) = CoreDataManager.shared.getProgress(
            sourceId: source?.key ?? manga.sourceKey,
            mangaId: manga.key,
            chapterId: chapter.key
        )

        if !completed, let startPage {
            currentPage = startPage
        } else {
            currentPage = -1
        }
        return currentPage
    }

    func setReadingMode(_ mode: String?) {
        switch mode {
            case "rtl": readingMode = .rtl
            case "ltr": readingMode = .ltr
            case "vertical": readingMode = .vertical
            case "scroll", "webtoon": readingMode = .webtoon
            case "continuous": readingMode = .continuous
            case "default":
                let defaultMode = UserDefaults.standard.string(forKey: "Reader.readingMode")
                if defaultMode == "default" {
                    setReadingMode("auto")
                } else {
                    setReadingMode(defaultMode)
                }
                return
            default: // auto
                // use given default reading mode
                if let defaultReadingMode {
                    readingMode = defaultReadingMode
                } else if CoreDataManager.shared.hasManga(
                    sourceId: source?.key ?? manga.sourceKey,
                    mangaId: manga.key
                ) {
                    // fall back to stored manga viewer
                    let sourceMode = CoreDataManager.shared.getMangaSourceReadingMode(
                        sourceId: source?.key ?? manga.sourceKey,
                        mangaId: manga.key
                    )
                    if let mode = ReadingMode(rawValue: sourceMode) {
                        readingMode = mode
                    } else {
                        readingMode = .rtl
                    }
                } else {
                    // fall back to rtl reading mode
                    readingMode = .rtl
                }
        }
    }

    func updateReadPosition(
        currentPage: Int? = nil,
        totalPages: Int? = nil,
        chapter: AidokuRunner.Chapter? = nil
    ) async {
        guard
            !UserDefaults.standard.bool(forKey: "General.incognitoMode"),
            (totalPages ?? 0) > 0 // ensure chapter pages are loaded
        else {
            return
        }

        let currentPage = currentPage ?? self.currentPage
        let chapter = chapter ?? self.chapter

        let sourceId = manga.sourceKey
        let mangaId = manga.key
        let chapterId = chapter.key
        let (completed, progress) = await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
            CoreDataManager.shared.getProgress(
                sourceId: sourceId,
                mangaId: mangaId,
                chapterId: chapterId,
                context: context
            )
        }
        let hasHistory = completed || progress != nil

        // don't add history if there is none and we're at the first page
        if currentPage == 1 && !hasHistory {
            return
        }

        await HistoryManager.shared.setProgress(
            chapter: chapter.toOld(sourceId: sourceId, mangaId: mangaId),
            progress: currentPage,
            totalPages: totalPages,
            completed: completed
        )
        await saveReadingSession(chapter: chapter)
    }

    private func saveReadingSession(chapter: AidokuRunner.Chapter? = nil) async {
        guard let sessionStartDate else { return }
        let pagesRead = sessionReadPages.count
        if pagesRead > 0 && sessionLastInteraction != nil {
            let chapter = chapter ?? self.chapter
            await HistoryManager.shared.addSession(
                chapterIdentifier: .init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key),
                data: .init(startDate: sessionStartDate, endDate: .now, pagesRead: pagesRead)
            )
        }
        self.sessionStartDate = nil
    }

    func startSession() {
        if sessionStartDate == nil {
            sessionReadPages = [currentPage]
            sessionStartDate = Date.now
            sessionLastInteraction = nil
        }
    }

    func endSession() async {
        await updateReadPosition()
    }

    func recordPageRead(_ page: Int, totalPages: Int) {
        sessionLastInteraction = Date.now
        if page >= 1 && page <= totalPages {
            sessionReadPages.insert(page)
        }
    }

    func setChapter(_ chapter: AidokuRunner.Chapter, totalPages: Int) {
        guard chapter != self.chapter else { return }

        // store current history data since it will change when new chapter loads
        let currentPage = currentPage
        let oldChapter = self.chapter

        Task {
            await updateReadPosition(currentPage: currentPage, totalPages: totalPages, chapter: oldChapter)
            sessionReadPages = [self.currentPage]
            sessionStartDate = Date.now
            sessionLastInteraction = nil
        }

        self.chapter = chapter
        self.chaptersToMark = [chapter]
    }

    func setCompleted() {
        if !UserDefaults.standard.bool(forKey: "General.incognitoMode") {
            Task {
                await HistoryManager.shared.addHistory(
                    sourceId: manga.sourceKey,
                    mangaId: manga.key,
                    chapters: chaptersToMark
                )
            }
        }
        if UserDefaults.standard.bool(forKey: "Library.deleteDownloadAfterReading") {
            chaptersToRemoveDownload.append(chapter)
        }
    }

    // MARK: - Navigation Logic

    private func areDuplicates(_ a: AidokuRunner.Chapter, _ b: AidokuRunner.Chapter) -> Bool {
        a.chapterNumber == b.chapterNumber
            && a.volumeNumber == b.volumeNumber
            && (!(a.chapterNumber == nil && a.volumeNumber == nil) || a.title == b.title)
    }

    private func isValidScanlatorMatch(for next: AidokuRunner.Chapter, current: Set<String>) -> Bool {
        let nextScanlators = Set(next.scanlators ?? [])
        return current.isEmpty ? nextScanlators.isEmpty : !current.isDisjoint(with: nextScanlators)
    }

    private func findBestChapterMatch(from index: Int, step: Int) -> AidokuRunner.Chapter {
        let firstCandidate = chapterList[index]
        let currentScanlators = Set(chapter.scanlators ?? [])

        var i = index
        while i >= 0 && i < chapterList.count {
            let next = chapterList[i]
            guard areDuplicates(next, firstCandidate) else { break }

            let identifier = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: next.key)
            let isReadable = !next.locked || DownloadManager.shared.getDownloadStatus(for: identifier) == .finished

            if isReadable && isValidScanlatorMatch(for: next, current: currentScanlators) {
                return next
            }
            i += step
        }

        return firstCandidate
    }

    func getNextChapter() -> AidokuRunner.Chapter? {
        guard
            var index = chapterList.firstIndex(of: chapter)
        else {
            return nil
        }

        let skipDuplicates = UserDefaults.standard.bool(forKey: "Reader.skipDuplicateChapters")
        let markDuplicates = UserDefaults.standard.bool(forKey: "Reader.markDuplicateChapters")

        index -= 1
        var nextChapterInList: AidokuRunner.Chapter?

        while index >= 0 {
            let new = chapterList[index]
            let identifier = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: new.key)

            let readable = !new.locked
                || DownloadManager.shared.getDownloadStatus(for: identifier) == .finished

            if readable {
                let isDuplicate = areDuplicates(new, chapter)

                if nextChapterInList == nil {
                    nextChapterInList = new
                }
                if markDuplicates && isDuplicate {
                    chaptersToMark.append(new)
                }
                if !isDuplicate {
                    return skipDuplicates ? findBestChapterMatch(from: index, step: -1) : nextChapterInList
                } else if !skipDuplicates && !markDuplicates {
                    return new
                }
            }
            index -= 1
        }
        return nil
    }

    func getPreviousChapter() -> AidokuRunner.Chapter? {
        guard
            var index = chapterList.firstIndex(of: chapter)
        else {
            return nil
        }
        // find previous non-duplicate chapter
        let markDuplicates = UserDefaults.standard.bool(forKey: "Reader.markDuplicateChapters")

        index += 1
        while index < chapterList.count {
            let new = chapterList[index]
            let identifier = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: new.key)

            let readable = !new.locked
                || DownloadManager.shared.getDownloadStatus(for: identifier) == .finished

            if readable {
                let isDuplicate = areDuplicates(new, chapter)
                if !isDuplicate {
                    return findBestChapterMatch(from: index, step: 1)
                }
                if markDuplicates {
                    chaptersToMark.append(new)
                }
            }
            index += 1
        }
        return nil
    }
}
