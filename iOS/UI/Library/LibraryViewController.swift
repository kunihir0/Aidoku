//
//  LibraryViewController.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 7/23/22.
//

import UIKit
import LocalAuthentication
import SwiftUI
import AidokuRunner

class LibraryViewController: OldMangaCollectionViewController {
    let viewModel = LibraryViewModel()

    // MARK: Bar Buttons
    private lazy var downloadBarButton = makeBarButton(
        systemName: "square.and.arrow.down",
        action: #selector(openDownloadQueue),
        titleKey: "DOWNLOAD_QUEUE",
        sharesBackground: false
    )
    private lazy var lockBarButton = makeBarButton(
        systemName: locked ? "lock" : "lock.open",
        action: #selector(performToggleLock),
        titleKey: "TOGGLE_LOCK"
    )
    lazy var moreBarButton =  makeBarButton(
        systemName: "ellipsis",
        action: nil,
        titleKey: "MORE_BARBUTTON"
    )
    private lazy var mangaUpdatesButton = makeBarButton(
        systemName: "bell",
        action: #selector(openMangaUpdates),
        titleKey: "MANGA_UPDATES",
        sharesBackground: false
    )

    private func makeBarButton(systemName: String? = nil, action: Selector?, titleKey: String, sharesBackground: Bool = true) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: systemName.flatMap { UIImage(systemName: $0) },
            style: .plain,
            target: self,
            action: action
        )
        item.title = NSLocalizedString(titleKey)
        if #available(iOS 26.0, *), !sharesBackground {
            item.sharesBackground = false
        }
        return item
    }

    private lazy var refreshControl = UIRefreshControl()
    private lazy var emptyStackView = EmptyPageStackView()
    private lazy var lockedStackView = LockedPageStackView()

    private lazy var locked = viewModel.isCategoryLocked()
    private var ignoreOptionChange = false
    private var lastSearch: String?

    private let libraryUndoManager = UndoManager()
    override var undoManager: UndoManager { libraryUndoManager }
    override var canBecomeFirstResponder: Bool { true }

    override var usesListLayout: Bool {
        get {
            UserDefaults.standard.bool(forKey: "Library.listView")
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: "Library.listView")
        }
    }

    override init() {
        super.init()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.isToolbarHidden = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // fix refresh control snapping height
        refreshControl.didMoveToSuperview()

        // hack to show search bar on initial presentation
        if !navigationItem.hidesSearchBarWhenScrolling {
            navigationItem.hidesSearchBarWhenScrolling = true
        }

        becomeFirstResponder()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // load stored download queue state on first load
        Task {
            await SourceManager.shared.loadSources() // make sure sources are loaded first
            await DownloadManager.shared.loadQueueState()
        }
    }

    override func configure() {
        super.configure()

        title = NSLocalizedString("LIBRARY")

        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.hidesSearchBarWhenScrolling = false

        collectionView.keyboardDismissMode = .onDrag

        // search controller
        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = NSLocalizedString("LIBRARY_SEARCH")
        navigationItem.searchController = searchController

        // navbar buttons
        updateMoreMenu()

        // toolbar buttons (editing)
        let deleteButton = UIBarButtonItem(
            title: nil,
            style: .plain,
            target: self,
            action: #selector(removeSelectedFromLibrary)
        )
        deleteButton.image = UIImage(systemName: "trash")
        if #unavailable(iOS 26.0) {
            deleteButton.tintColor = .systemRed
        }

        let addButton = UIBarButtonItem(
            title: nil,
            style: .plain,
            target: self,
            action: #selector(addSelectedToCategories)
        )
        addButton.image = UIImage(systemName: "folder.badge.plus")

        toolbarItems = [
            deleteButton,
            UIBarButtonItem(systemItem: .flexibleSpace),
            addButton
        ]

        // pull to refresh
        refreshControl.addTarget(self, action: #selector(updateLibraryRefresh(refreshControl:)), for: .valueChanged)
        collectionView.refreshControl = refreshControl

        collectionView.allowsMultipleSelection = !ProcessInfo.processInfo.isMacCatalystApp
        collectionView.allowsSelectionDuringEditing = true

        // header view
        let registration = UICollectionView.SupplementaryRegistration<MangaListSelectionHeader>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, _ in
            guard let self else { return }
            header.delegate = self
            header.options = [NSLocalizedString("ALL")] + self.viewModel.categories
            header.selectedOption = self.viewModel.currentCategory != nil
                ? (self.viewModel.categories.firstIndex(of: self.viewModel.currentCategory!) ?? -1) + 1
                : 0
            header.updateMenu()

            // load locked icons
            if UserDefaults.standard.bool(forKey: "Library.lockLibrary") {
                let lockedCategories = UserDefaults.standard.stringArray(forKey: "Library.lockedCategories") ?? []
                header.lockedOptions = [0] + lockedCategories.compactMap { category -> Int? in
                    if let index = self.viewModel.categories.firstIndex(of: category) {
                        return index + 1
                    }
                    return nil
                }
            }
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(
                    using: registration,
                    for: indexPath
                )
            }
            return nil
        }

        // empty text view
        emptyStackView.isHidden = true
        view.addSubview(emptyStackView)

        // locked text view
        lockedStackView.isHidden = true
        lockedStackView.text = viewModel.currentCategory == nil
            ? NSLocalizedString("LIBRARY_LOCKED")
            : NSLocalizedString("CATEGORY_LOCKED")
        lockedStackView.buttonText = NSLocalizedString("VIEW_LIBRARY")
        lockedStackView.button.addTarget(self, action: #selector(performUnlock), for: .touchUpInside)
        view.addSubview(lockedStackView)

        // load data
        Task {
            // load categories
            viewModel.categories = await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
                CoreDataManager.shared.getCategories(context: context).map { $0.title ?? "" }
            }
            // refresh header
            collectionView.collectionViewLayout = self.makeCollectionViewLayout()
            updateNavbarItems()

            // load library
            await viewModel.loadLibrary()
            updateEmptyStack()
            updateLockState()
        }
    }

    override func constrain() {
        super.constrain()

        emptyStackView.translatesAutoresizingMaskIntoConstraints = false
        lockedStackView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            emptyStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            lockedStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lockedStackView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func observe() {
        super.observe()

        let checkNavbarDownloadButton: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isEditing else { return }
                let shouldShowButton = await DownloadManager.shared.hasQueuedDownloads()
                let index = self.navigationItem.rightBarButtonItems?.firstIndex(of: self.downloadBarButton)
                if shouldShowButton && index == nil {
                    // rightmost button
                    self.navigationItem.rightBarButtonItems?.insert(
                        self.downloadBarButton,
                        at: (self.navigationItem.rightBarButtonItems?.count ?? 1) - 1
                    )
                } else if !shouldShowButton, let index = index {
                    self.navigationItem.rightBarButtonItems?.remove(at: index)
                }
            }
        }
        addObserver(forName: .downloadsQueued, using: checkNavbarDownloadButton)
        addObserver(forName: .downloadCancelled, using: checkNavbarDownloadButton)
        addObserver(forName: .downloadsCancelled, using: checkNavbarDownloadButton)

        let updateDownloadCounts: (Notification) -> Void = { [weak self] notification in
            guard let self else { return }
            if let id = notification.object as? ChapterIdentifier {
                Task {
                    await self.viewModel.fetchDownloadCounts(for: id.mangaIdentifier)
                    self.updateDataSource()
                }
            } else if let id = notification.object as? MangaIdentifier {
                Task {
                    await self.viewModel.fetchDownloadCounts(for: id)
                    self.updateDataSource()
                }
            }
        }
        addObserver(forName: .downloadFinished) { notification in
            checkNavbarDownloadButton(notification)
            updateDownloadCounts(.init(name: .downloadFinished, object: (notification.object as? Download)?.mangaIdentifier))
        }
        addObserver(forName: .downloadRemoved, using: updateDownloadCounts)
        addObserver(forName: .downloadsRemoved, using: updateDownloadCounts)

        addObserver(forName: .updateLibrary) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.viewModel.loadLibrary()
                self.updateEmptyStack()
                self.updateDataSource()
            }
        }
        addObserver(forName: .updateLibraryLock) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.locked = self.viewModel.isCategoryLocked()
                self.updateLockState()
            }
        }
        addObserver(forName: .updateCategories) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.viewModel.refreshCategories()
                self.collectionView.collectionViewLayout = self.makeCollectionViewLayout()
                self.updateDataSource()
                if !self.isEditing {
                    self.updateToolbar() // show/hide add category button
                }
                self.updateHeaderCategories()
                // update lock state
                if UserDefaults.standard.bool(forKey: "Library.lockLibrary") {
                    NotificationCenter.default.post(name: Notification.Name("updateLibraryLock"), object: nil)
                }
            }
        }
        addObserver(forName: .updateMangaCategories) { [weak self] _ in
            guard let self, self.viewModel.currentCategory != nil else { return }
            Task { @MainActor in
                await self.viewModel.loadLibrary()
                self.updateDataSource()
            }
        }
        addObserver(forName: .updateManga) { [weak self] notification in
            guard let self, let id = notification.object as? MangaIdentifier else { return }
            Task {
                let libraryReloaded = if !UserDefaults.standard.bool(forKey: "General.incognitoMode") {
                    await self.viewModel.mangaOpened(sourceId: id.sourceKey, mangaId: id.mangaKey)
                } else {
                    false
                }
                if !libraryReloaded {
                    if self.viewModel.sortMethod == .lastUpdated || self.viewModel.sortMethod == .lastChapter {
                        // if sorting by updated or last chapter, or pinning updated, we need to reload the library to update the order
                        await self.viewModel.loadLibrary()
                    } else {
                        // otherwise, just update the unread count (in case chapters were added)
                        await self.viewModel.fetchUnreads(for: id)
                    }
                }
                self.updateDataSource()
            }
        }

        addObserver(forName: .pinTitles) { [weak self] _ in
            guard let self else { return }
            self.viewModel.pinType = self.viewModel.getPinType()
            Task { @MainActor in
                await self.viewModel.loadLibrary()
                self.updateDataSource()
            }
        }

        // refresh badges
        addObserver(forName: "Library.unreadChapterBadges") { [weak self] _ in
            if UserDefaults.standard.bool(forKey: "Library.unreadChapterBadges") {
                self?.viewModel.badgeType.insert(.unread)
            } else {
                self?.viewModel.badgeType.remove(.unread)
            }
            self?.reloadItems()
        }
        addObserver(forName: "Library.downloadedChapterBadges") { [weak self] _ in
            if UserDefaults.standard.bool(forKey: "Library.downloadedChapterBadges") {
                self?.viewModel.badgeType.insert(.downloaded)
            } else {
                self?.viewModel.badgeType.remove(.downloaded)
            }
            self?.reloadItems()
        }

        // update history
        addObserver(forName: .updateHistory) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.viewModel.fetchUnreads()
                if self.viewModel.pinType != .unread {
                    await self.viewModel.loadLibrary()
                }
                self.updateDataSource()
            }
        }
        addObserver(forName: .historyAdded) { [weak self] notification in
            guard let self, let chapters = notification.object as? [Chapter] else { return }
            Task { @MainActor in
                let manga = Array(Set(chapters.map { MangaInfo(mangaId: $0.mangaId, sourceId: $0.sourceId) }))
                await self.viewModel.updateHistory(for: manga, read: true)
                self.updateDataSource()
            }
        }
        addObserver(forName: .historyRemoved) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                var manga: [MangaInfo] = []
                if let chapters = notification.object as? [Chapter] {
                    manga = Array(Set(chapters.map { MangaInfo(mangaId: $0.mangaId, sourceId: $0.sourceId) }))
                } else if let mangaObject = notification.object as? Manga {
                    manga = [mangaObject.toInfo()]
                }
                await self.viewModel.updateHistory(for: manga, read: false)
                self.updateDataSource()
            }
        }
        addObserver(forName: .historySet) { [weak self] notification in
            guard let self, let item = notification.object as? (chapter: Chapter, page: Int) else { return }
            Task { @MainActor in
                self.viewModel.mangaRead(sourceId: item.chapter.sourceId, mangaId: item.chapter.mangaId)
                self.updateDataSource()
            }
        }

        // lock library when moving to background
        addObserver(forName: UIApplication.willResignActiveNotification) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.locked = self.viewModel.isCategoryLocked()
                self.updateLockState()
            }
        }
    }

    // collection view layout with header
    override func makeCollectionViewLayout() -> UICollectionViewLayout {
        let layout = super.makeCollectionViewLayout()
        guard let layout = layout as? UICollectionViewCompositionalLayout else { return layout }

        let config = UICollectionViewCompositionalLayoutConfiguration()
        config.interSectionSpacing = layout.configuration.interSectionSpacing
        if !viewModel.categories.isEmpty {
            let globalHeader = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(40)
                ),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            config.boundarySupplementaryItems = [globalHeader]
        }
        layout.configuration = config

        return layout
    }

    // cells with badges
    override func configure(cell: MangaGridCell, info: MangaInfo) {
        super.configure(cell: cell, info: info)

        cell.badgeNumber = viewModel.badgeType.contains(.unread) ? info.unread : 0
        cell.badgeNumber2 = viewModel.badgeType.contains(.downloaded) ? info.downloads : 0

        cell.setEditing(self.isEditing, animated: false)
    }

    override func configure(cell: MangaListCell, info: MangaInfo) {
        super.configure(cell: cell, info: info)

        cell.badgeNumber = viewModel.badgeType.contains(.unread) ? info.unread : 0
        cell.badgeNumber2 = viewModel.badgeType.contains(.downloaded) ? info.downloads : 0

        cell.setEditing(isEditing, animated: false)
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        updateNavbarItems()
        updateToolbar()

        if ProcessInfo.processInfo.isMacCatalystApp {
            collectionView.allowsMultipleSelection = editing
        }

        for cell in collectionView.visibleCells {
            if let cell = cell as? MangaGridCell {
                cell.setEditing(editing, animated: animated)
            } else if let cell = cell as? MangaListCell {
                cell.setEditing(editing, animated: animated)
            }
        }
    }
}

extension LibraryViewController {
    func updateNavbarItems() {
        if isEditing {
            let allItemsSelected = collectionView.indexPathsForSelectedItems?.count ?? 0 == dataSource.snapshot().itemIdentifiers.count
            navigationItem.leftBarButtonItem = if allItemsSelected {
                makeBarButton(
                    action: #selector(deselectAllItems),
                    titleKey: "DESELECT_ALL"
                )
            } else {
                makeBarButton(
                    action: #selector(selectAllItems),
                    titleKey: "SELECT_ALL"
                )
            }
            navigationItem.rightBarButtonItems = [UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(stopEditing)
            )]
        } else {
            var items: [UIBarButtonItem] = [moreBarButton]
            if viewModel.isCategoryLocked() {
                items.append(lockBarButton)
            }
            items.append(mangaUpdatesButton)
            navigationItem.rightBarButtonItems = items
            navigationItem.leftBarButtonItem = nil
            Task { @MainActor in
                if await DownloadManager.shared.hasQueuedDownloads() {
                    let index = (navigationItem.rightBarButtonItems?.count ?? 1) - 1
                    guard !(navigationItem.rightBarButtonItems?.contains(downloadBarButton) ?? true) else { return }
                    navigationItem.rightBarButtonItems?.insert(
                        downloadBarButton,
                        at: index
                    )
                }
            }
        }
    }

    func updateToolbar() {
        if isEditing {
            // show toolbar
            if navigationController?.isToolbarHidden ?? false {
                UIView.animate(withDuration: CATransaction.animationDuration()) {
                    self.navigationController?.isToolbarHidden = false
                    self.navigationController?.toolbar.alpha = 1
                    if #available(iOS 26.0, *) {
                        // hide tab bar on iOS 26 (it covers the toolbar)
                        self.tabBarController?.isTabBarHidden = true
                    }
                }
            }
            // show add to category button if categories exist
            if viewModel.categories.isEmpty {
                if #available(iOS 16.0, *) {
                    toolbarItems?.last?.isHidden = true
                } else {
                    toolbarItems?.last?.image = nil
                }
            } else {
                if !self.viewModel.categories.isEmpty {
                    if #available(iOS 16.0, *) {
                        toolbarItems?.last?.isHidden = false
                    } else {
                        toolbarItems?.last?.image = UIImage(systemName: "folder.badge.plus")
                    }
                }
            }
            // enable items
            let hasSelectedItems = !(collectionView.indexPathsForSelectedItems?.isEmpty ?? true)
            toolbarItems?.first?.isEnabled = hasSelectedItems
            toolbarItems?.last?.isEnabled = hasSelectedItems
        } else if !(self.navigationController?.isToolbarHidden ?? true) {
            // fade out toolbar
            UIView.animate(withDuration: CATransaction.animationDuration()) {
                self.navigationController?.toolbar.alpha = 0
                if #available(iOS 26.0, *) {
                    // reshow tab bar on iOS 26
                    self.tabBarController?.isTabBarHidden = false
                }
            } completion: { _ in
                self.navigationController?.isToolbarHidden = true
            }
        }
    }

    // updates library empty message
    // should be called when category changes and when library loads initially
    func updateEmptyStack() {
        emptyStackView.imageSystemName = "books.vertical.fill"
        emptyStackView.title = viewModel.currentCategory == nil
            ? NSLocalizedString("LIBRARY_EMPTY")
            : NSLocalizedString("CATEGORY_EMPTY")
        emptyStackView.text = viewModel.actuallyEmpty
            ? NSLocalizedString("LIBRARY_ADD_CONTENT")
            : NSLocalizedString("LIBRARY_ADJUST_FILTERS")
    }

    @objc func stopEditing() {
        setEditing(false, animated: true)
        deselectAllItems()
    }

    @objc func selectAllItems() {
        for item in dataSource.snapshot().itemIdentifiers {
            if let indexPath = dataSource.indexPath(for: item) {
                collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            }
        }
        updateNavbarItems()
        updateToolbar()
        reloadItems()
    }

    @objc func deselectAllItems() {
        for item in dataSource.snapshot().itemIdentifiers {
            if let indexPath = dataSource.indexPath(for: item) {
                collectionView.deselectItem(at: indexPath, animated: false)
            }
        }
        updateNavbarItems()
        updateToolbar()
        reloadItems()
    }

    @objc func updateLibraryRefresh(refreshControl: UIRefreshControl? = nil) {
        Task {
            // delay hiding refresh control to avoid buggy animation
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            refreshControl?.endRefreshing()
        }

        Task {
            await MangaManager.shared.backgroundRefreshLibrary(category: viewModel.currentCategory)
        }
    }

    @objc func openDownloadQueue() {
        let viewController = UIHostingController(rootView: DownloadQueueView())
        viewController.navigationItem.largeTitleDisplayMode = .never
        viewController.navigationItem.title = NSLocalizedString("DOWNLOAD_QUEUE")
        if #available(iOS 26.0, *) {
            viewController.preferredTransition = .zoom { _ in
                self.downloadBarButton
            }
        }
        viewController.modalPresentationStyle = .pageSheet
        present(viewController, animated: true)
    }

    @objc func openMangaUpdates() {
        let path = NavigationCoordinator(rootViewController: self)
        let viewController = UIHostingController(rootView: MangaUpdatesView().environmentObject(path))
        viewController.navigationItem.largeTitleDisplayMode = .never
        viewController.navigationItem.title = NSLocalizedString("MANGA_UPDATES")
        navigationController?.pushViewController(viewController, animated: true)
    }

    @objc func removeSelectedFromLibrary() {
        let inCategory = viewModel.currentCategory != nil
        let selectedItems = collectionView.indexPathsForSelectedItems ?? []
        confirmAction(
            actions: inCategory ? [
                UIAlertAction(
                    title: NSLocalizedString("REMOVE_FROM_CATEGORY"),
                    style: .destructive
                ) { _ in
                    Task {
                        let identifiers = selectedItems.compactMap { self.dataSource.itemIdentifier(for: $0) }
                        await self.removeFromCategory(mangaInfo: identifiers)?.value
                        self.updateNavbarItems()
                        self.updateToolbar()
                    }
                }
            ] : [],
            continueActionName: NSLocalizedString("REMOVE_FROM_LIBRARY"),
            sourceItem: toolbarItems?.first
        ) {
            Task {
                let identifiers = selectedItems.compactMap { self.dataSource.itemIdentifier(for: $0) }
                await self.removeFromLibrary(mangaInfo: identifiers)?.value
                self.updateNavbarItems()
                self.updateToolbar()
            }
        }
    }

    @objc func addSelectedToCategories() {
        let manga = (collectionView.indexPathsForSelectedItems ?? []).compactMap {
            dataSource.itemIdentifier(for: $0)
        }
        present(
            UINavigationController(rootViewController: AddToCategoryViewController(
                manga: manga,
                disabledCategories: viewModel.currentCategory != nil ? [viewModel.currentCategory!] : []
            )),
            animated: true
        )
    }
}

// MARK: - Data Source Updating
extension LibraryViewController {
    func clearDataSource() {
        let snapshot = NSDiffableDataSourceSnapshot<Section, MangaInfo>()
        dataSource.apply(snapshot)
    }

    func updateDataSource() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, MangaInfo>()

        if !locked {
            if !viewModel.pinnedManga.isEmpty {
                snapshot.appendSections(Section.allCases)
                snapshot.appendItems(viewModel.pinnedManga, toSection: .pinned)
            } else {
                snapshot.appendSections([.regular])
            }

            snapshot.appendItems(viewModel.manga, toSection: .regular)
        }

        dataSource.apply(snapshot)

        // handle empty library or category
        if navigationItem.searchController?.searchBar.text?.isEmpty ?? true {
            emptyStackView.isHidden = !snapshot.itemIdentifiers.isEmpty
        }
        collectionView.isScrollEnabled = emptyStackView.isHidden && lockedStackView.isHidden
        collectionView.refreshControl = collectionView.isScrollEnabled ? refreshControl : nil
    }

    func reloadItems() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot)
    }
}

// MARK: - Locking
extension LibraryViewController {
    func lock() {
        locked = true
        updateLockState()
    }

    func unlock() {
        locked = false
        updateLockState()
    }

    func attemptUnlock() async {
        do {
            let success = try await LAContext().evaluatePolicy(
                .defaultPolicy,
                localizedReason: NSLocalizedString("AUTH_FOR_LIBRARY")
            )
            guard success else { return }
        } catch {
            // The error is displayed to users, so we can ignore it.
            return
        }

        unlock()
    }

    @objc func performUnlock() {
        Task {
            await attemptUnlock()
        }
    }

    @objc func performToggleLock() {
        Task {
            if locked {
                await attemptUnlock()
            } else {
                lock()
            }
        }
    }

    func updateLockState() {
        if locked {
            guard emptyStackView.alpha != 0 else { return } // lock view already showing
            collectionView.isScrollEnabled = false
            emptyStackView.alpha = 0
            lockedStackView.alpha = 0
            lockedStackView.isHidden = false
            UIView.animate(withDuration: CATransaction.animationDuration()) {
                self.lockedStackView.alpha = 1
            }
        } else {
            collectionView.isScrollEnabled = emptyStackView.isHidden
            lockedStackView.isHidden = true
            UIView.animate(withDuration: CATransaction.animationDuration()) {
                self.emptyStackView.alpha = 1
            }
        }
        lockBarButton.image = UIImage(systemName: locked ? "lock" : "lock.open")

        lockedStackView.text = viewModel.currentCategory == nil
            ? NSLocalizedString("LIBRARY_LOCKED")
            : NSLocalizedString("CATEGORY_LOCKED")

        updateNavbarLock()
        updateHeaderLockIcons()
        updateDataSource()
    }

    func updateNavbarLock() {
        guard !isEditing else { return }
        let index = navigationItem.rightBarButtonItems?.firstIndex(of: lockBarButton)
        if locked && index == nil {
            if navigationItem.rightBarButtonItems?.count ?? 0 == 0 {
                navigationItem.rightBarButtonItems = [lockBarButton]
            } else {
                navigationItem.rightBarButtonItems?.insert(lockBarButton, at: 1)
            }
        } else if !locked, let index = index {
            navigationItem.rightBarButtonItems?.remove(at: index)
        }
    }

    func updateHeaderLockIcons() {
        guard let header = (collectionView.supplementaryView(
            forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(index: 0)
        ) as? MangaListSelectionHeader) else { return }
        if UserDefaults.standard.bool(forKey: "Library.lockLibrary") {
            let lockedCategories = UserDefaults.standard.stringArray(forKey: "Library.lockedCategories") ?? []
            header.lockedOptions = [0] + lockedCategories.compactMap { category -> Int? in
                if let index = viewModel.categories.firstIndex(of: category) {
                    return index + 1
                }
                return nil
            }
        } else {
            header.lockedOptions = []
        }
    }

    // update category options in header
    func updateHeaderCategories() {
        guard let header = (collectionView.supplementaryView(
            forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(index: 0)
        ) as? MangaListSelectionHeader) else { return }
        ignoreOptionChange = true
        header.options = [NSLocalizedString("ALL")] + viewModel.categories
        header.setSelectedOption(
            viewModel.currentCategory != nil
                ? (viewModel.categories.firstIndex(of: viewModel.currentCategory!) ?? -1) + 1
                : 0
        )
    }
}

// MARK: - Listing Header Delegate
extension LibraryViewController: MangaListSelectionHeaderDelegate {
    nonisolated func optionSelected(_ index: Int) {
        Task { @MainActor in
            guard !ignoreOptionChange else {
                ignoreOptionChange = false
                return
            }
            if index == 0 {
                viewModel.currentCategory = nil
            } else {
                viewModel.currentCategory = viewModel.categories[index - 1]
            }
            locked = viewModel.isCategoryLocked()
            updateLockState()
            deselectAllItems()
            updateToolbar()
            updateNavbarItems()

            await viewModel.loadLibrary()
            updateEmptyStack()
            updateDataSource()
        }
    }
}

// MARK: - Search Results
extension LibraryViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        guard searchController.searchBar.text != lastSearch else { return }
        lastSearch = searchController.searchBar.text
        Task {
            await viewModel.search(query: searchController.searchBar.text ?? "")
            updateDataSource()
        }
    }
}
