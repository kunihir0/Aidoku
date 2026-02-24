//
//  ReaderPagedViewController+Delegates.swift
//  Aidoku (iOS)
//
//  Created by Gemini on 2/16/26.
//

import UIKit
import AidokuRunner
import VisionKit

// MARK: - Reader Delegate
extension ReaderPagedViewController: ReaderReaderDelegate {
    func moveLeft() {
        if
            let currentViewController = pageViewController.viewControllers?.first,
            let targetViewController = pageViewController(pageViewController, viewControllerBefore: currentViewController)
        {
            let animated = UserDefaults.standard.bool(forKey: "Reader.animatePageTransitions")
            pageViewController.setViewControllers(
                [targetViewController],
                direction: .reverse,
                animated: animated
            ) { completed in
                self.pageViewController(
                    self.pageViewController,
                    didFinishAnimating: true,
                    previousViewControllers: [currentViewController],
                    transitionCompleted: completed
                )
            }
        }
    }

    func moveRight() {
        if
            let currentViewController = pageViewController.viewControllers?.last,
            let targetViewController = pageViewController(pageViewController, viewControllerAfter: currentViewController)
        {
            let animated = UserDefaults.standard.bool(forKey: "Reader.animatePageTransitions")
            pageViewController.setViewControllers(
                [targetViewController],
                direction: .forward,
                animated: animated
            ) { completed in
                self.pageViewController(
                    self.pageViewController,
                    didFinishAnimating: true,
                    previousViewControllers: [currentViewController],
                    transitionCompleted: completed
                )
            }
        }
    }

    func sliderMoved(value: CGFloat) {
        let displayPage = Int(round(value * CGFloat(displayPageCount - 1))) + 1
        let actualPage = actualPageIndex(from: displayPage)
        delegate?.displayPage(actualPage)
    }

    func sliderStopped(value: CGFloat) {
        let displayPage = Int(round(value * CGFloat(displayPageCount - 1))) + 1
        move(toPage: displayPage, animated: false)
    }

    func setChapter(_ chapter: AidokuRunner.Chapter, startPage: Int) {
        self.chapter = chapter
        Task {
            await loadChapter(startPage: startPage)
        }
    }

    func loadChapter(startPage: Int) async {
        guard let chapter else { return }
        await viewModel.loadPages(chapter: chapter)
        delegate?.setPages(viewModel.pages)
        if !viewModel.pages.isEmpty {
            await MainActor.run {
                // clear isolated and split pages when switching chapters
                isolatedPages = []
                splitPages = [:]

                loadPageControllers(chapter: chapter)

                let displayPageCount = displayPageCount
                var startPage = startPage
                if startPage < 1 {
                    startPage = 1
                } else if startPage > displayPageCount {
                    startPage = displayPageCount
                }
                // if we're moving to the previous chapter and the final page is split, move to the true final page
                if let targetSplitPages = splitPages[startPage] {
                    if navigationDirection == .backward {
                        startPage += targetSplitPages.count - 1
                    }
                }
                move(toPage: startPage, animated: false)
            }
        }
    }

    func refreshChapter(startPage: Int) {
        guard let chapter else { return }

        loadPageControllers(chapter: chapter)
        let displayPageCount = displayPageCount
        var startPage = startPage
        if startPage < 1 {
            startPage = 1
        } else if startPage > displayPageCount {
            startPage = displayPageCount
        }

        self.move(toPage: startPage, animated: false)
    }

    func loadPreviousChapter() {
        guard let previousChapter else { return }
        nextPreviewSplitPages = splitPages[1]
        delegate?.setChapter(previousChapter)
        setChapter(previousChapter, startPage: Int.max)
    }

    func loadNextChapter() {
        guard let nextChapter else { return }
        previousPreviewSplitPages = splitPages[viewModel.pages.count]
        delegate?.setChapter(nextChapter)
        setChapter(nextChapter, startPage: 1)
    }
}

// MARK: - Page Controller Delegate
extension ReaderPagedViewController: UIPageViewControllerDelegate {

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        setLiveTextButtonHidden(delegate?.barsHidden ?? false)
        guard
            completed,
            let viewController = pageViewController.viewControllers?.first,
            let currentIndex = getIndex(of: viewController, pos: .first),
            pagesToPreload > 0
        else {
            return
        }
        let page = currentIndex + (previousChapter != nil ? -1 : 0)
        switch page {
            case -1: // previous chapter last page
                // move previous
                loadPreviousChapter()

            case 0: // previous chapter transition page
                delegate?.setCurrentPage(0)
                // preload previous
                if let previousChapter = previousChapter {
                    Task {
                        await viewModel.preload(chapter: previousChapter)
                        if currentIndex > 0, let lastPage = viewModel.preloadedPages.last {
                            pageViewControllers[currentIndex - 1].setPage(
                                lastPage,
                                sourceId: viewModel.source?.key ?? viewModel.manga.sourceKey
                            )
                        }
                    }
                }

            case displayPageCount + 1: // next chapter transition page
                delegate?.setCurrentPage(displayPageCount + 1)
                // preload next
                if let nextChapter = nextChapter {
                    Task {
                        await viewModel.preload(chapter: nextChapter)
                        if currentIndex + 1 < pageViewControllers.count, let firstPage = viewModel.preloadedPages.first {
                            pageViewControllers[currentIndex + 1].setPage(
                                firstPage,
                                sourceId: viewModel.source?.key ?? viewModel.manga.sourceKey
                            )
                        }
                    }
                }

            case displayPageCount + 2: // next chapter first page
                // move next
                loadNextChapter()

            default:
                // Track navigation direction for smart split page selection
                if page > lastPageIndex {
                    navigationDirection = .forward
                } else if page < lastPageIndex {
                    navigationDirection = .backward
                }
                lastPageIndex = page
                currentPage = page

                if usesDoublePages {
                    // For double pages, report the actual page range
                    let actualPage = actualPageIndex(from: page)
                    delegate?.setCurrentPages(actualPage...actualPage + 1)
                } else {
                    // For single pages, report the actual page index
                    let actualPage = actualPageIndex(from: page)
                    delegate?.setCurrentPage(actualPage)
                }
                // preload 1 before and pagesToPreload ahead
                loadPages(in: page - 1 - (usesDoublePages ? 1 : 0)...page + pagesToPreload + (usesDoublePages ? 1 : 0))
        }
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        setLiveTextButtonHidden(true)
        for controller in pendingViewControllers {
            if let controller = controller as? ReaderDoublePageViewController {
                if let first = getIndex(of: controller, pos: .first) {
                    let index = pageIndex(from: first) - 1
                    guard index >= 0, index < viewModel.pages.count else { break }
                    controller.setPage(viewModel.pages[index], for: .first)
                }
                if let second = getIndex(of: controller, pos: .second) {
                    let index = pageIndex(from: second) - 1
                    guard index >= 0, index < viewModel.pages.count else { break }
                    controller.setPage(viewModel.pages[index], for: .second)
                }
            } else {
                guard let index = getIndex(of: controller) else { continue }
                loadPage(at: index)
            }
        }
    }
}

// MARK: - Page Controller Data Source
extension ReaderPagedViewController: UIPageViewControllerDataSource {

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        switch readingMode {
            case .rtl:
                return getPageController(before: viewController)
            case .ltr, .vertical:
                return getPageController(after: viewController)
            default:
                return nil
        }
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        switch readingMode {
            case .rtl:
                return getPageController(after: viewController)
            case .ltr, .vertical:
                return getPageController(before: viewController)
            default:
                return nil
        }
    }

    func getPageController(after viewController: UIViewController) -> UIViewController? {
        guard let currentIndex = getIndex(of: viewController, pos: .second) else {
            return nil
        }
        if currentIndex + 1 < pageViewControllers.count {
            // check for double page layout
            if usesDoublePages && currentIndex + 2 < pageViewControllers.count {
                let firstPage = pageViewControllers[currentIndex + 1]
                let secondPage = pageViewControllers[currentIndex + 2]
                // make sure both pages are not info pages
                if case .page = firstPage.type, case .page = secondPage.type {
                    return createPageController(
                        firstPage: firstPage,
                        secondPage: secondPage,
                        page: pageIndex(from: currentIndex + 1)
                    )
                }
            }
            return pageViewControllers[currentIndex + 1]
        }
        return nil
    }

    func getPageController(before viewController: UIViewController) -> UIViewController? {
        guard let currentIndex = getIndex(of: viewController, pos: .first) else {
            return nil
        }
        if currentIndex - 1 >= 0 {
            // check for double page layout
            if usesDoublePages && currentIndex - 2 >= 0 {
                let firstPage = pageViewControllers[currentIndex - 2]
                let secondPage = pageViewControllers[currentIndex - 1]
                // make sure both pages are not info pages
                if case .page = firstPage.type, case .page = secondPage.type {
                    return createPageController(
                        firstPage: firstPage,
                        secondPage: secondPage,
                        page: pageIndex(from: currentIndex - 1),
                        forBefore: true
                    )
                }
            }
            return pageViewControllers[currentIndex - 1]
        }
        return nil
    }
}

// MARK: - Context Menu Delegate
extension ReaderPagedViewController: UIContextMenuInteractionDelegate {

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard
            !UserDefaults.standard.bool(forKey: "Reader.disableQuickActions"),
            let pageView = interaction.view as? UIImageView,
            pageView.image != nil
        else {
            return nil
        }
        // disable when live text highlighting is active
        if
            #available(iOS 16.0, *),
            let imageAnalaysisInteraction = pageView.interactions.first as? ImageAnalysisInteraction,
            imageAnalaysisInteraction.selectableItemsHighlighted
        {
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { _ in
            let saveToPhotosAction = UIAction(
                title: NSLocalizedString("SAVE_TO_PHOTOS", comment: ""),
                image: UIImage(systemName: "photo")
            ) { _ in
                if let image = pageView.image {
                    image.saveToAlbum(viewController: self)
                }
            }

            let shareAction = UIAction(
                title: NSLocalizedString("SHARE", comment: ""),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in
                if let image = pageView.image {
                    let items = [image]
                    let activityController = UIActivityViewController(activityItems: items, applicationActivities: nil)

                    activityController.popoverPresentationController?.sourceView = self.view
                    activityController.popoverPresentationController?.sourceRect = CGRect(origin: location, size: .zero)

                    self.present(activityController, animated: true)
                }
            }

            let reloadAction = UIAction(
                title: NSLocalizedString("RELOAD", comment: ""),
                image: UIImage(systemName: "arrow.clockwise")
            ) { _ in
                Task { @MainActor in
                    await self.reloadCurrentPageImage(for: pageView)
                }
            }

            var actions = [saveToPhotosAction, shareAction, reloadAction]

            // Only show isolate page action if using double pages and page is not already isolated
            if self.usesDoublePages {
                var isAlreadyIsolated = false
                for (index, pageViewController) in self.pageViewControllers.enumerated() {
                    if
                        case .page = pageViewController.type,
                        let readerPageView = pageViewController.pageView,
                        readerPageView.imageView == pageView
                    {
                        let page = self.pageIndex(from: index)
                        if self.isolatedPages.contains(page) {
                            isAlreadyIsolated = true
                        }
                        break
                    }
                }
                if !isAlreadyIsolated {
                    let isolatePageAction = UIAction(
                        title: NSLocalizedString("SET_AS_SINGLE_PAGE", comment: ""),
                        image: UIImage(systemName: "rectangle.portrait")
                    ) { _ in
                        Task { @MainActor in
                            self.isolateCurrentPage(for: pageView)
                        }
                    }
                    actions.insert(isolatePageAction, at: 2)
                }
            }

            return UIMenu(title: "", children: actions)
        })
    }

    @MainActor
    private func reloadCurrentPageImage(for imageView: UIImageView) async {
        for pageViewController in pageViewControllers {
            if
                case .page = pageViewController.type,
                let readerPageView = pageViewController.pageView,
                readerPageView.imageView == imageView
            {
                let success = await readerPageView.reloadCurrentImage()
                if !success {
                    showReloadError()
                }
                return
            }
        }
    }

    @MainActor
    private func isolateCurrentPage(for imageView: UIImageView) {
        for (index, pageViewController) in pageViewControllers.enumerated() {
            if
                case .page = pageViewController.type,
                let readerPageView = pageViewController.pageView,
                readerPageView.imageView == imageView
            {
                let page = pageIndex(from: index)
                isolatedPages.insert(page)

                refreshChapter(startPage: page)
                return
            }
        }
    }

    private func showReloadError() {
        let alert = UIAlertController(
            title: NSLocalizedString("RELOAD_FAILED"),
            message: NSLocalizedString("RELOAD_FAILED_TEXT"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .default))
        present(alert, animated: true)
    }
}
