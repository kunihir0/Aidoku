//
//  ReaderWebtoonViewController.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 9/27/22.
//

import AidokuRunner
import AsyncDisplayKit
import Nuke
import UIKit

class ReaderWebtoonViewController: ZoomableCollectionViewController {

    let viewModel: ReaderWebtoonViewModel
    weak var delegate: ReaderHoldingDelegate?

    var chapter: AidokuRunner.Chapter?
    var readingMode: ReadingMode = .webtoon

//    private let prefetcher = ImagePrefetcher()

    // Indicates if infinite scroll is enabled
    lazy var infinite = UserDefaults.standard.bool(forKey: "Reader.verticalInfiniteScroll")
    var loadingPrevious = false
    var loadingNext = false

    // The chapters currently shown in the reader view
    var chapters: [AidokuRunner.Chapter] = []
    // The pages corresponding to the `chapters` variable
    var pages: [[Page]] = []

    // Indicates if the page slider is currently in use
    var isSliding = false
    // Indicates if a zoom gesture is in progress
    var isZooming = false
    // Indicates if a scroll is in progress
    var isScrolling = false
    // Indicates if an info refresh should be done if info pages are off screen
    var needsInfoRefresh = false

    // Stores the last calculated page number
    var previousPage = 0

    init(source: AidokuRunner.Source?, manga: AidokuRunner.Manga) {
        self.viewModel = ReaderWebtoonViewModel(source: source, manga: manga)
        super.init(layout: VerticalContentOffsetPreservingLayout())
    }

    override func configure() {
        super.configure()

        collectionNode.delegate = self
        collectionNode.dataSource = self
//        collectionNode.view.prefetchDataSource = self
//        collectionNode.isPrefetchingEnabled = true

        // override texture's automatic decreased preloading range
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .display), for: .minimum, rangeType: .display)
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .preload), for: .minimum, rangeType: .preload)
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .display), for: .lowMemory, rangeType: .display)
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .preload), for: .lowMemory, rangeType: .preload)

        scrollView.contentInset = .zero
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bounces = false // bouncing can cause issues with page appending
        scrollView.scrollsToTop = false // dont want status bar tap to work
        scrollNode.insetsLayoutMarginsFromSafeArea = false

        collectionNode.contentInset = .zero
        collectionNode.showsVerticalScrollIndicator = false
        collectionNode.showsHorizontalScrollIndicator = false
        collectionNode.view.contentInsetAdjustmentBehavior = .never
        collectionNode.view.bounces = false
        collectionNode.view.scrollsToTop = false

        collectionNode.automaticallyManagesSubnodes = true
        collectionNode.shouldAnimateSizeChanges = false
        collectionNode.insetsLayoutMarginsFromSafeArea = false

        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5

        zoomView.onZoomScaleChanged = { [weak self] scale in
            self?.setLiveTextButtonHidden(scale != 1)
        }
    }

    override func observe() {
        addObserver(forName: "Reader.verticalInfiniteScroll") { [weak self] notification in
            self?.infinite = notification.object as? Bool
                ?? UserDefaults.standard.bool(forKey: "Reader.verticalInfiniteScroll")
        }
        addObserver(forName: .readerShowingBars) { [weak self] _ in
            self?.setLiveTextButtonHidden(false)
        }
        addObserver(forName: .readerHidingBars) { [weak self] _ in
            self?.setLiveTextButtonHidden(true)
        }

        addObserver(forName: UIApplication.didReceiveMemoryWarningNotification.rawValue) { [weak self] _ in
            // clear live text analysis
            LogManager.logger.warn("Received memory warning")

            if #available(iOS 16.0, *) {
                self?.collectionNode.visibleNodes.forEach { node in
                    guard let node = node as? ReaderWebtoonPageNode else { return }
                    node.imageNode.imageAnalaysisInteraction = nil
                }
            }
        }
    }

    enum ScreenPosition {
        case top
        case middle
        case bottom
    }

    /// Get the current row of the page view at `pos`
    func getCurrentPagePath(pos: ScreenPosition = .middle) -> IndexPath? {
        let additional: CGFloat
        switch pos {
            case .top: additional = 0
            case .middle: additional = collectionNode.bounds.height / 2
            case .bottom: additional = collectionNode.bounds.height
        }
        let currentPoint = CGPoint(x: collectionNode.contentOffset.x, y: collectionNode.contentOffset.y + additional)
        return collectionNode.indexPathForItem(at: currentPoint)
    }

    func getCurrentPage() -> Int {
        guard
            let chapter = chapter,
            let chapterIndex = chapters.firstIndex(of: chapter),
            let currentPages = pages[safe: chapterIndex]
        else { return 0 }
        let pageRow = getCurrentPagePath()?.row ?? 0
        let hasStartInfo = currentPages.first?.type != .imagePage
        return min(
            max(pageRow + (hasStartInfo ? 0 : 1), 0),
            currentPages.count - (hasStartInfo ? 1 : 0)
        )
    }

    func setLiveTextButtonHidden(_ hidden: Bool) {
        collectionNode.visibleNodes.forEach {
            guard let pageNode = $0 as? ReaderWebtoonPageNode else { return }
            if hidden || delegate?.barsHidden == true {
                pageNode.setLiveTextHidden(true)
            } else {
                let scale = zoomView.scrollNode.view.zoomScale
                pageNode.setLiveTextHidden(scale != 1)
            }
        }
    }

    // check if at the top or bottom to append the next/prev chapter
    func checkInfiniteLoad() {
        // prepend previous chapter
        if !loadingPrevious {
            let topPath = getCurrentPagePath(pos: .top)
            if topPath == nil || (topPath?.section == 0 && topPath?.row == 0) {
                loadingPrevious = true
                Task {
                    await prependPreviousChapter()
                    loadingPrevious = false
                }
            }
        }
        if !loadingNext {
            let bottomPath = getCurrentPagePath(pos: .bottom)
            // append next chapter
            if bottomPath == nil || (bottomPath?.section == pages.count - 1 && bottomPath?.item == pages[pages.count - 1].count - 1) {
                loadingNext = true
                delegate?.setCompleted()
                Task {
                    await appendNextChapter()
                    loadingNext = false
                }
            }
        }
    }

    /// Prepend the previous chapter's pages
    func prependPreviousChapter() async {
        guard let prevChapter = delegate?.getPreviousChapter() else { return }
        await viewModel.preload(chapter: prevChapter)

        // check if pages failed to load
        if viewModel.preloadedPages.isEmpty {
            return
        }

        // wait until zooming and scrolling stops
        while isZooming || isScrolling {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // queue remove last section if we have three already
//        let removeLast = chapters.count >= 3

        chapters.insert(prevChapter, at: 0)
        pages.insert(
            [Page(
                type: .prevInfoPage,
                sourceId: viewModel.source?.key ?? viewModel.manga.sourceKey,
                chapterId: prevChapter.key,
                index: -1
            )]  + viewModel.preloadedPages,
            at: 0
        )

        let layout = collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout
        layout?.isInsertingCellsAbove = true

        // disable animations and adjust offset before re-enabling
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        await collectionNode.performBatch(animated: false) {
            collectionNode.insertSections(IndexSet(integer: 0))
        }
//        if removeLast {
//            chapters.removeLast()
//            pages.removeLast()
//
//            // remove last section
//            await collectionNode.performBatchUpdates {
//                self.collectionNode.deleteSections(IndexSet(integer: self.pages.count - 1))
//            }
//        }
        self.scrollView.contentOffset = self.collectionNode.contentOffset
        self.zoomView.adjustContentSize()
        CATransaction.commit()
    }

    /// Append the next chapter's pages
    func appendNextChapter() async {
        guard let nextChapter = delegate?.getNextChapter() else { return }
        await viewModel.preload(chapter: nextChapter)

        // check if pages failed to load
        if viewModel.preloadedPages.isEmpty {
            return
        }

        // wait until zooming and scrolling stops
        while isZooming || isScrolling {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // queue remove first section if we have three already
//        let removeFirst = chapters.count >= 3

        chapters.append(nextChapter)
        pages.append(viewModel.preloadedPages + [Page(
            type: .nextInfoPage,
            sourceId: viewModel.source?.key ?? viewModel.manga.sourceKey,
            chapterId: nextChapter.id,
            index: -2
        )])

        // disable animations and adjust offset before re-enabling
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        await collectionNode.performBatch(animated: false) {
            collectionNode.insertSections(IndexSet(integer: pages.count - 1))
        }
//        if removeFirst {
//            chapters.removeFirst()
//            pages.removeFirst()
//            await collectionNode.performBatchUpdates {
//                collectionNode.deleteSections(IndexSet(integer: 0))
//            }
//        }
        scrollView.contentOffset = self.collectionNode.contentOffset
        zoomView.adjustContentSize()
        CATransaction.commit()
    }

    /// Switch current chapter to previous
    func movePreviousChapter() {
        guard
            let currChapter = chapter,
            let chapterIndex = chapters.firstIndex(of: currChapter),
            let chapter = chapters[safe: chapterIndex - 1],
            let pages = pages[safe: chapterIndex - 1]
        else { return }
        self.chapter = chapter
        delegate?.setChapter(chapter)
        delegate?.setPages(pages.filter({ $0.type == .imagePage }))
        viewModel.setPages(chapter: chapter, pages: pages)
    }

    /// Switch current chapter to next
    func moveNextChapter() {
        guard
            let currChapter = chapter,
            let chapterIndex = chapters.firstIndex(of: currChapter),
            let chapter = chapters[safe: chapterIndex + 1],
            let pages = pages[safe: chapterIndex + 1]
        else { return }
        self.chapter = chapter
        delegate?.setChapter(chapter)
        delegate?.setPages(pages.filter({ $0.type == .imagePage }))
        viewModel.setPages(chapter: chapter, pages: pages)
    }

    /// Refresh info page chapter info
    func refreshInfoPages() {
        let paths = pages.enumerated().flatMap { section, pages in
            pages.enumerated().compactMap { item, page in
                if page.type != .imagePage {
                    return IndexPath(item: item, section: section)
                } else {
                    return nil
                }
            }
        }
        collectionNode.performBatchUpdates {
            collectionNode.reloadItems(at: paths)
        } completion: { finished in
            if finished {
                Task { @MainActor in
                    self.zoomView.adjustContentSize()
                }
            }
        }
    }
}
