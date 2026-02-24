//
//  LibraryViewController+Actions.swift
//  Aidoku (iOS)
//
//  Created by Gemini on 2/16/26.
//

import UIKit
import AidokuRunner

// MARK: - Undoable Methods
extension LibraryViewController {
    @discardableResult
    func removeFromLibrary(mangaInfo: [MangaInfo]) -> Task<Void, Never>? {
        let mangaCount = mangaInfo.count
        let actionName =
            mangaCount > 1
            ? String(
                format: NSLocalizedString("REMOVING_%i_ITEMS_FROM_LIBRARY"), mangaCount
            ) : NSLocalizedString("REMOVING_(ONE)_ITEM_FROM_LIBRARY")
        undoManager.setActionName(actionName)

        let removedManga = mangaInfo.map {
            let manga = CoreDataManager.shared.getManga(sourceId: $0.sourceId, mangaId: $0.mangaId)?
                .toManga()

            let chapters = CoreDataManager.shared.getChapters(
                sourceId: $0.sourceId, mangaId: $0.mangaId
            ).map { $0.toChapter() }

            let trackItems = CoreDataManager.shared.getTracks(
                sourceId: $0.sourceId, mangaId: $0.mangaId
            ).map { $0.toItem() }

            let categories = CoreDataManager.shared.getCategories(
                sourceId: $0.sourceId, mangaId: $0.mangaId
            ).compactMap { $0.title }

            return (manga, chapters, trackItems, categories)
        }

        undoManager.registerUndo(withTarget: self) { target in
            target.undoManager.registerUndo(withTarget: target) { redoTarget in
                redoTarget.removeFromLibrary(mangaInfo: mangaInfo)
            }

            Task {
                for (manga, chapters, trackItems, categories) in removedManga {
                    guard let manga = manga else { continue }
                    await MangaManager.shared.restoreToLibrary(
                        manga: manga, chapters: chapters, trackItems: trackItems,
                        categories: categories)
                }

                NotificationCenter.default.post(
                    name: Notification.Name("updateLibrary"), object: nil)
            }
        }

        return Task {
            for manga in mangaInfo {
                await viewModel.removeFromLibrary(manga: manga)
            }

            updateDataSource()
        }
    }

    @discardableResult
    func removeFromCategory(mangaInfo: [MangaInfo]) -> Task<Void, Never>? {
        guard let currentCategory = viewModel.currentCategory else { return nil }
        let mangaCount = mangaInfo.count
        let actionName =
            mangaCount > 1
            ? String(
                format: NSLocalizedString("REMOVING_%i_ITEMS_FROM_CATEGORY_%@"),
                mangaCount, currentCategory)
            : String(
                format: NSLocalizedString("REMOVING_(ONE)_ITEM_FROM_CATEGORY_%@"),
                currentCategory)
        undoManager.setActionName(actionName)

        undoManager.registerUndo(withTarget: self) { target in
            target.undoManager.registerUndo(withTarget: target) { redoTarget in
                redoTarget.removeFromCategory(mangaInfo: mangaInfo)
            }

            Task {
                for manga in mangaInfo {
                    await target.viewModel.addToCurrentCategory(manga: manga)
                }

                NotificationCenter.default.post(
                    name: NSNotification.Name("updateMangaCategories"),
                    object: nil)
            }
        }

        return Task {
            for manga in mangaInfo {
                await viewModel.removeFromCurrentCategory(manga: manga)
            }

            updateDataSource()
        }
    }
}
