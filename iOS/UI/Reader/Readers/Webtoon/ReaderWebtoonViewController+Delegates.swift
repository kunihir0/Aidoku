//
//  ReaderWebtoonViewController+Delegates.swift
//  Aidoku (iOS)
//
//  Created by Gemini on 2/16/26.
//

import UIKit
import AidokuRunner
import AsyncDisplayKit
import Nuke

// MARK: - Scroll View Delegate
extension ReaderWebtoonViewController {
    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        super.scrollViewWillBeginDragging(scrollView)
        setLiveTextButtonHidden(true)
    }

    // Update current page when scrolling
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)

        isScrolling = true

        // ignore if page slider is being used
        guard !isSliding && !isZooming else { return }

        guard
            let chapter = chapter,
            let chapterIndex = chapters.firstIndex(of: chapter)
        else { return }

        let pagePath = getCurrentPagePath()
        let pageSection = pagePath?.section ?? 0

        if infinite {
            // check if we need to switch chapters
            if chapterIndex > 0 && pageSection < chapterIndex {
                movePreviousChapter()
                needsInfoRefresh = true
            } else if chapterIndex < chapters.count - 1 {
                if pageSection > chapterIndex {
                    moveNextChapter()
                    needsInfoRefresh = true
                }
            }
        }

        // update page number
        let page = getCurrentPage()
        if previousPage != page {
            previousPage = page
            delegate?.setCurrentPage(page)
        }
    }

    // disable slider movement while zooming
    // zooming sometimes causes page count to jitter between two pages
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        isZooming = true
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        isZooming = false
        scrollViewDidScroll(scrollView)
    }

    // fix content size when rotating
    // TODO: fix scroll offset when rotating
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { _ in
            self.zoomView.adjustContentSize()
        }
    }
}

// MARK: - Context Menu
extension ReaderWebtoonViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard
            case let point = interaction.location(in: collectionNode.view),
            let indexPath = collectionNode.indexPathForItem(at: point),
            let node = collectionNode.nodeForItem(at: indexPath) as? ReaderWebtoonPageNode,
            let image = node.imageNode.image,
            !UserDefaults.standard.bool(forKey: "Reader.disableQuickActions")
        else {
            return nil
        }
        // disable when live text highlighting is active
        if
            #available(iOS 16.0, *),
            let imageAnalaysisInteraction = node.imageNode.imageAnalaysisInteraction,
            imageAnalaysisInteraction.selectableItemsHighlighted
        {
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { [weak self] _ in
            guard let self else { return nil }
            let saveToPhotosAction = UIAction(
                title: NSLocalizedString("SAVE_TO_PHOTOS", comment: ""),
                image: UIImage(systemName: "photo")
            ) { _ in
                image.saveToAlbum(viewController: self)
            }
            let shareAction = UIAction(
                title: NSLocalizedString("SHARE", comment: ""),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in
                let items = [image]
                let activityController = UIActivityViewController(activityItems: items, applicationActivities: nil)

                activityController.popoverPresentationController?.sourceView = self.view
                activityController.popoverPresentationController?.sourceRect = CGRect(origin: location, size: .zero)

                self.present(activityController, animated: true)
            }

            let reloadAction = UIAction(
                title: NSLocalizedString("RELOAD", comment: ""),
                image: UIImage(systemName: "arrow.clockwise")
            ) { _ in
                Task { @MainActor in
                    await self.reloadPageImage(for: node)
                }
            }

            return UIMenu(title: "", children: [saveToPhotosAction, shareAction, reloadAction])
        })
    }

    /// Reloads the page image for the given webtoon page node
    @MainActor
    func reloadPageImage(for node: ReaderWebtoonPageNode) async {
        let success = await node.reloadCurrentImage()
        if !success {
            // Show error feedback if reload failed
            showReloadError()
        }
    }

    /// Shows an error message when image reload fails
    func showReloadError() {
        let alert = UIAlertController(
            title: NSLocalizedString("RELOAD_FAILED"),
            message: NSLocalizedString("RELOAD_FAILED_TEXT"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Reader Delegate
extension ReaderWebtoonViewController: ReaderReaderDelegate {
    func moveLeft() {
        let offset = CGPoint(
            x: collectionNode.contentOffset.x,
            y: max(
                0,
                collectionNode.contentOffset.y - collectionNode.bounds.height * 2/3
            )
        )
        scrollView.setContentOffset(
            offset,
            animated: UserDefaults.standard.bool(forKey: "Reader.animatePageTransitions")
        )
    }

    func moveRight() {
        let offset = CGPoint(
            x: collectionNode.contentOffset.x,
            y: min(
                scrollView.contentSize.height - scrollView.bounds.height,
                collectionNode.contentOffset.y + collectionNode.bounds.height * 2/3
            )
        )
        scrollView.setContentOffset(
            offset,
            animated: UserDefaults.standard.bool(forKey: "Reader.animatePageTransitions")
        )
    }

    func sliderMoved(value: CGFloat) {
        isSliding = true

        // get slider area
        guard
            let chapter = chapter,
            let chapterIndex = chapters.firstIndex(of: chapter),
            let layout = self.collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout,
            let currentPages = pages[safe: chapterIndex]
        else { return }

        var offset: CGFloat = 0
        for idx in 0..<chapterIndex {
            offset += layout.getHeightFor(section: idx)
        }

        let hasStartInfo = currentPages.first?.type != .imagePage
        let hasEndInfo = currentPages.last?.type != .imagePage

        if hasStartInfo {
            offset += layout.getHeightFor(section: chapterIndex, range: 0..<1)
        }

        let height = layout.getHeightFor(
            section: chapterIndex,
            range: (hasStartInfo ? 1 : 0)..<currentPages.count - (hasEndInfo ? 1 : 0)
        ) - collectionNode.bounds.height

        scrollView.setContentOffset(
            CGPoint(x: collectionNode.contentOffset.x, y: offset + height * value),
            animated: false
        )

        let page = getCurrentPage()
        delegate?.displayPage(page)
    }

    func sliderStopped(value: CGFloat) {
        isSliding = false
        scrollViewDidScroll(collectionNode.view)
    }

    func setChapter(_ chapter: AidokuRunner.Chapter, startPage: Int) {
        self.chapter = chapter
        chapters = [chapter]

        Task {
            await viewModel.loadPages(chapter: chapter)
            delegate?.setPages(viewModel.pages)
            if viewModel.pages.isEmpty {
                pages = []
                await collectionNode.reloadData()
                return
            }
            let sourceId = viewModel.source?.key ?? viewModel.manga.sourceKey
            pages = [[
                Page(
                    type: .prevInfoPage,
                    sourceId: sourceId,
                    chapterId: chapter.key,
                    index: -1
                )
            ] + viewModel.pages + [
                Page(
                    type: .nextInfoPage,
                    sourceId: sourceId,
                    chapterId: chapter.key,
                    index: -2
                )
            ]]

            var startPage = startPage
            if startPage < 1 {
                startPage = 1
            } else if startPage > viewModel.pages.count {
                startPage = viewModel.pages.count
            }

            await collectionNode.reloadData()
            zoomView.adjustContentSize()

            // scroll to first page
            collectionNode.scrollToItem(
                at: IndexPath(row: startPage, section: 0),
                at: .top,
                animated: false
            )
            scrollView.contentOffset = collectionNode.contentOffset
        }
    }
}

// MARK: - Collection View Delegate
extension ReaderWebtoonViewController: ASCollectionDelegate {

    // Refresh info pages after they move off screen
    func collectionNode(_ collectionNode: ASCollectionNode, didEndDisplayingItemWith node: ASCellNode) {
        guard needsInfoRefresh else { return }
        if node is ReaderWebtoonTransitionNode {
            needsInfoRefresh = false
            refreshInfoPages()
        }
    }
}

// MARK: - Data Source
extension ReaderWebtoonViewController: ASCollectionDataSource {

    func numberOfSections(in collectionNode: ASCollectionNode) -> Int {
        pages.count
    }

    func collectionNode(
        _ collectionNode: ASCollectionNode,
        numberOfItemsInSection section: Int
    ) -> Int {
        pages[section].count
    }

    func collectionNode(
        _ collectionNode: ASCollectionNode,
        nodeBlockForItemAt indexPath: IndexPath
    ) -> ASCellNodeBlock {
        guard let chapter else { return { ASCellNode() } }
        var page = pages[indexPath.section][indexPath.item]
        if page.type == .imagePage {
            // image page
            return { [weak self] in
                guard let self else { return ASCellNode() }
                let cell = ReaderWebtoonPageNode(source: self.viewModel.source, page: page)
                cell.delegate = self
                return cell
            }
        } else {
            // transition page
            let chapterIndex = chapters.firstIndex(of: chapter) ?? 0

            // determine page type
            if (indexPath.section == chapterIndex && indexPath.item == 0)
                || (indexPath.section == chapterIndex - 1 && indexPath.item > 0) {
                page.type = .prevInfoPage
            } else {
                page.type = .nextInfoPage
            }

            let to = page.type == .prevInfoPage
                ? self.delegate?.getPreviousChapter()
                : self.delegate?.getNextChapter()
            return { [weak self] in
                guard let self else { return ASCellNode() }
                return ReaderWebtoonTransitionNode(transition: .init(
                    type: page.type == .prevInfoPage ? .prev : .next,
                    from: chapter.toOld(
                        sourceId: self.viewModel.source?.key ?? self.viewModel.manga.sourceKey,
                        mangaId: self.viewModel.manga.key
                    ),
                    to: to?.toOld(
                        sourceId: self.viewModel.source?.key ?? self.viewModel.manga.sourceKey,
                        mangaId: self.viewModel.manga.key
                    )
                ))
            }
        }
    }
}
