//
//  LibraryViewController+CollectionView.swift
//  Aidoku (iOS)
//
//  Created by Gemini on 2/16/26.
//

import UIKit
import AidokuRunner
import SwiftUI

// MARK: - Collection View Delegate
extension LibraryViewController {
    // support two finger drag to select
    func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        true
    }

    func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        setEditing(true, animated: true)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let info = dataSource.itemIdentifier(for: indexPath) else { return }

        if isEditing {
            let cell = collectionView.cellForItem(at: indexPath)
            guard let cell else { return }
            if let cell = cell as? MangaGridCell {
                cell.setSelected(true)
            } else if let cell = cell as? MangaListCell {
                cell.setSelected(true)
            }
            if #available(iOS 17.5, *) {
                UISelectionFeedbackGenerator().selectionChanged(at: cell.center)
            } else {
                UISelectionFeedbackGenerator().selectionChanged()
            }
            updateNavbarItems()
            updateToolbar()
            return
        }

        if UserDefaults.standard.bool(forKey: "Library.opensReaderView") {
            Task {
                // get next chapter to read
                let history = await CoreDataManager.shared.getReadingHistory(
                    sourceId: info.sourceId,
                    mangaId: info.mangaId
                )
                let chapters = await CoreDataManager.shared.getChapters(sourceId: info.sourceId, mangaId: info.mangaId)
                let chapter = chapters.reversed().first(where: { history[$0.id]?.page ?? 0 != -1 })

                if let chapter = chapter {
                    // open reader view
                    guard let source = SourceManager.shared.source(for: chapter.sourceId) else {
                        return
                    }
                    let manga = AidokuRunner.Manga(
                        sourceKey: chapter.sourceId,
                        key: chapter.mangaId,
                        title: info.title ?? "",
                        chapters: chapters.map { $0.toNew() }
                    )
                    let readerController = ReaderViewController(
                        source: source,
                        manga: manga,
                        chapter: chapter.toNew()
                    )
                    let navigationController = ReaderNavigationController(
                        readerViewController: readerController,
                        mangaInfo: info
                    )
                    if #available(iOS 18.0, *) {
                        navigationController.preferredTransition = .zoom { context in
                            guard
                                let navigationController = context.zoomedViewController as? ReaderNavigationController,
                                let info = navigationController.mangaInfo,
                                let indexPath = self.dataSource.indexPath(for: info),
                                let cell = self.collectionView.cellForItem(at: indexPath)
                            else {
                                return nil
                            }
                            if let cell = cell as? MangaListCell {
                                return cell.coverImageView
                            } else {
                                return cell.contentView
                            }
                        }
                    }
                    navigationController.modalPresentationStyle = .fullScreen
                    present(navigationController, animated: true)
                } else {
                    // no chapter to read, open manga page
                    let indexPath = dataSource.indexPath(for: info) ?? indexPath // get new index path in case it changed
                    super.collectionView(collectionView, didSelectItemAt: indexPath)
                }
            }
        } else {
            super.collectionView(collectionView, didSelectItemAt: indexPath)
        }

        if !UserDefaults.standard.bool(forKey: "General.incognitoMode") {
            Task {
                await CoreDataManager.shared.setOpened(sourceId: info.sourceId, mangaId: info.mangaId)
                await self.viewModel.mangaOpened(sourceId: info.sourceId, mangaId: info.mangaId)
                self.updateDataSource()
            }
        }

        collectionView.deselectItem(at: indexPath, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if isEditing {
            let cell = collectionView.cellForItem(at: indexPath)
            if let cell = cell as? MangaGridCell {
                cell.setSelected(false)
            } else if let cell = cell as? MangaListCell {
                cell.setSelected(false)
            }
            updateNavbarItems()
            updateToolbar()
        }
    }

    // don't highlighting when selecting during editing
    override func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        guard !isEditing else { return }
        super.collectionView(collectionView, didHighlightItemAt: indexPath)
    }

    private func mangaInfo(at path: IndexPath) -> MangaInfo {
        let manga: [MangaInfo] = if path.section == 0 && !viewModel.pinnedManga.isEmpty {
            viewModel.pinnedManga
        } else {
            viewModel.manga
        }

        return manga[path.row]
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first else { return nil }

        let manga = mangaInfo(at: indexPath)
        let mangaInfo = indexPaths.map(mangaInfo(at:))

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ -> UIMenu? in
            var actions: [UIMenuElement] = []
            let singleAttributes = mangaInfo.count > 1
                ? .disabled
                : UIMenuElement.Attributes()

            if let url = manga.url {
                actions.append(UIMenu(identifier: .share, options: .displayInline, children: [
                    UIAction(
                        title: NSLocalizedString("SHARE"),
                        image: UIImage(systemName: "square.and.arrow.up"),
                        attributes: singleAttributes
                    ) { _ in
                        let activityViewController = UIActivityViewController(
                            activityItems: [url],
                            applicationActivities: nil
                        )
                        activityViewController.popoverPresentationController?.sourceView = self.view
                        activityViewController.popoverPresentationController?.sourceRect = collectionView.cellForItem(at: indexPath)?.frame ?? .zero

                        self.present(activityViewController, animated: true)
                    }
                ]))
            }

            if UserDefaults.standard.bool(forKey: "Library.opensReaderView"), mangaInfo.count == 1 {
                actions.append(UIAction(
                    title: NSLocalizedString("MANGA_INFO"),
                    image: UIImage(systemName: "info.circle"),
                    attributes: singleAttributes
                ) { _ in
                    self.openInfoView(info: mangaInfo[0], zoom: false)
                })
            }

            if !self.viewModel.categories.isEmpty {
                actions.append(UIAction(
                    title: NSLocalizedString("EDIT_CATEGORIES"),
                    image: UIImage(systemName: "folder.badge.gearshape"),
                    attributes: singleAttributes
                ) { _ in
                    let manga = manga.toManga()
                    self.present(
                        UINavigationController(
                            rootViewController: CategorySelectViewController(
                                manga: manga.toNew()
                            )
                        ),
                        animated: true
                    )
                })
            }

            actions.append(UIAction(
                title: NSLocalizedString("MIGRATE"),
                image: UIImage(systemName: "arrow.left.arrow.right")
            ) { [weak self] _ in
                let manga = mangaInfo.map { $0.toManga() }
                let migrateView = MigrateMangaView(manga: manga)
                self?.present(UIHostingController(rootView: SwiftUINavigationView(rootView: migrateView)), animated: true)
            })

            var bottomMenuChildren: [UIMenuElement] = []

            bottomMenuChildren.append(UIMenu(title: NSLocalizedString("MARK_ALL"), image: nil, children: [
                // read chapters
                UIAction(title: NSLocalizedString("READ"), image: UIImage(systemName: "eye")) { _ in
                    (UIApplication.shared.delegate as? AppDelegate)?.showLoadingIndicator()

                    Task {
                        for manga in mangaInfo {
                            let manga = manga.toManga()
                            let chapters = await CoreDataManager.shared.getChapters(sourceId: manga.sourceId, mangaId: manga.id)

                            await HistoryManager.shared.addHistory(
                                sourceId: manga.sourceId,
                                mangaId: manga.id,
                                chapters: chapters.map { $0.toNew() }
                            )
                        }

                        await (UIApplication.shared.delegate as? AppDelegate)?.hideLoadingIndicator()
                    }
                },
                // unread chapters
                UIAction(title: NSLocalizedString("UNREAD"), image: UIImage(systemName: "eye.slash")) { _ in
                    (UIApplication.shared.delegate as? AppDelegate)?.showLoadingIndicator()

                    Task {
                        for manga in mangaInfo {
                            let manga = manga.toManga()
                            let chapters = await CoreDataManager.shared.getChapters(sourceId: manga.sourceId, mangaId: manga.id)

                            await HistoryManager.shared.removeHistory(
                                sourceId: manga.sourceId,
                                mangaId: manga.id,
                                chapterIds: chapters.map { $0.id }
                            )
                        }

                        await (UIApplication.shared.delegate as? AppDelegate)?.hideLoadingIndicator()
                    }
                }
            ]))

            let downloadAllAction = UIAction(title: NSLocalizedString("ALL")) { _ in
                if UserDefaults.standard.bool(forKey: "Library.downloadOnlyOnWifi") &&
                    Reachability.getConnectionType() == .wifi ||
                    !UserDefaults.standard.bool(forKey: "Library.downloadOnlyOnWifi") {
                    Task {
                        for mangaInfo in mangaInfo {
                            await DownloadManager.shared.downloadAll(manga: mangaInfo.toManga().toNew())
                        }
                    }
                } else {
                    self.presentAlert(
                        title: NSLocalizedString("NO_WIFI_ALERT_TITLE"),
                        message: NSLocalizedString("NO_WIFI_ALERT_MESSAGE")
                    )
                }
            }

            let downloadUnreadAction = UIAction(title: NSLocalizedString("UNREAD")) { _ in
                if UserDefaults.standard.bool(forKey: "Library.downloadOnlyOnWifi") &&
                    Reachability.getConnectionType() == .wifi ||
                    !UserDefaults.standard.bool(forKey: "Library.downloadOnlyOnWifi") {
                    Task {
                        for manga in mangaInfo {
                            await DownloadManager.shared.downloadUnread(manga: manga.toManga().toNew())
                        }
                    }
                } else {
                    self.presentAlert(
                        title: NSLocalizedString("NO_WIFI_ALERT_TITLE"),
                        message: NSLocalizedString("NO_WIFI_ALERT_MESSAGE")
                    )
                }
            }

            if manga.sourceId != LocalSourceRunner.sourceKey && SourceManager.shared.hasSourceInstalled(id: manga.sourceId) {
                bottomMenuChildren.append(UIMenu(
                    title: NSLocalizedString("DOWNLOAD"),
                    image: UIImage(systemName: "arrow.down.circle"),
                    children: [downloadAllAction, downloadUnreadAction]
                ))
            }

            if self.viewModel.currentCategory != nil {
                bottomMenuChildren.append(UIAction(
                    title: NSLocalizedString("REMOVE_FROM_CATEGORY"),
                    image: UIImage(systemName: "folder.badge.minus"),
                    attributes: .destructive
                ) { _ in
                    self.removeFromCategory(mangaInfo: mangaInfo)
                })
            }

            bottomMenuChildren.append(UIAction(
                title: NSLocalizedString("REMOVE_FROM_LIBRARY"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                self.removeFromLibrary(mangaInfo: mangaInfo)
            })

            actions.append(UIMenu(options: .displayInline, children: bottomMenuChildren))

            return UIMenu(title: "", children: actions)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        self.collectionView(collectionView, contextMenuConfigurationForItemsAt: [indexPath], point: point)
    }
}
