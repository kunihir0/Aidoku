//
//  LibraryViewController+Filter.swift
//  Aidoku (iOS)
//
//  Created by Gemini on 2/16/26.
//

import UIKit
import AidokuRunner

// MARK: - Sorting and Filtering
extension LibraryViewController {
    func setSort(method: LibraryViewModel.SortMethod, ascending: Bool) {
        Task {
            await viewModel.setSort(method: method, ascending: ascending)
            updateDataSource()
            updateMoreMenu()
        }
    }

    func toggleFilter(method: LibraryViewModel.FilterMethod, value: String? = nil) {
        Task {
            await viewModel.toggleFilter(method: method, value: value)
            updateDataSource()
            if #available(iOS 26.0, *) {
                updateFilterMenuState()
            } else {
                updateMoreMenu()
            }
        }
    }

    func filterState(for method: LibraryViewModel.FilterMethod, value: String? = nil) -> UIMenuElement.State {
        if let filter = viewModel.filters.first(where: { $0.type == method && $0.value == value }) {
            filter.exclude ? .mixed : .on
        } else {
            .off
        }
    }

    func removeFilterAction() -> UIAction {
        UIAction(
            title: NSLocalizedString("REMOVE_FILTER"),
            image: UIImage(systemName: "minus.circle")
        ) { [weak self] _ in
            Task {
                self?.viewModel.filters = []
                await self?.viewModel.loadLibrary()
                self?.updateDataSource()
                self?.updateMoreMenu()
            }
        }
    }

    func filtersSubtitle() -> String? {
        guard !viewModel.filters.isEmpty else { return nil }
        var options: [String] = []
        var methods: Set<LibraryViewModel.FilterMethod> = []
        for filterMethod in LibraryViewModel.FilterMethod.allCases {
            // ensure we only list each method type once (e.g. for multiple source filters)
            guard methods.insert(filterMethod).inserted else {
                continue
            }
            if let filter = viewModel.filters.first(where: { $0.type == filterMethod }) {
                guard options.count < 3 else {
                    options.removeLast() // make subtitle fit in two lines
                    options.append(NSLocalizedString("AND_MORE"))
                    break
                }
                if filter.exclude {
                    options.append(String(format: NSLocalizedString("NOT_%@"), filterMethod.title))
                } else {
                    options.append(filterMethod.title)
                }
            }
        }
        return options.joined(separator: NSLocalizedString("FILTER_SEPARATOR"))
    }

    @available(iOS 26.0, *)
    func updateFilterMenuState() {
        // _contextMenuInteraction only exists on ios 26+
        // a similar thing could probably be achieved on lower versions by putting a UIButton in the bar button custom view
        let contextMenuInteraction = moreBarButton.value(forKey: "_contextMenuInteraction") as? UIContextMenuInteraction
        guard let contextMenuInteraction else { return }

        func updateFilterSubmenu(_ menu: UIMenu) -> UIMenu {
            menu.subtitle = self.filtersSubtitle()
            return menu.replacingChildren(menu.children.map { element in
                guard let action = element as? UIAction else { return element }
                if let method = LibraryViewModel.FilterMethod.allCases.first(where: { $0.title == action.title }) {
                    action.state = filterState(for: method)
                }
                return action
            })
        }

        contextMenuInteraction.updateVisibleMenu { menu in
            if menu.title == NSLocalizedString("BUTTON_FILTER") {
                updateFilterSubmenu(menu)
            } else if menu.title == LibraryViewModel.FilterMethod.source.title {
                menu.replacingChildren(self.viewModel.sourceKeys.map { key in
                    UIAction(
                        title: SourceManager.shared.source(for: key)?.name ?? key,
                        attributes: .keepsMenuPresented,
                        state: self.filterState(for: .source, value: key)
                    ) { [weak self] _ in
                        self?.toggleFilter(method: .source, value: key)
                    }
                })
            } else if menu.title == LibraryViewModel.FilterMethod.contentRating.title {
                menu.replacingChildren(MangaContentRating.allCases.map { rating in
                    UIAction(
                        title: rating.title,
                        attributes: .keepsMenuPresented,
                        state: self.filterState(for: .contentRating, value: rating.stringValue)
                    ) { [weak self] _ in
                        self?.toggleFilter(method: .contentRating, value: rating.stringValue)
                    }
                })
            } else {
                menu.replacingChildren(menu.children.map { element in
                    guard let menu = element as? UIMenu else { return element }
                    if menu.children.first?.title == NSLocalizedString("SORT_BY") {
                        let shouldShowRemoveFilter = !self.viewModel.filters.isEmpty
                        let isShowingRemoveFilter = menu.children.last?.title == NSLocalizedString("REMOVE_FILTER")

                        let updatedChildren = menu.children.map { element in
                            if element.title == NSLocalizedString("BUTTON_FILTER"), let menu = element as? UIMenu {
                                updateFilterSubmenu(menu) as UIMenuElement
                            } else {
                                element
                            }
                        }

                        if shouldShowRemoveFilter && !isShowingRemoveFilter {
                            return menu.replacingChildren(updatedChildren + [removeFilterAction()])
                        } else if !shouldShowRemoveFilter && isShowingRemoveFilter {
                            return menu.replacingChildren(updatedChildren.dropLast())
                        }
                    }
                    return element
                })
            }
        }

        if !viewModel.filters.isEmpty {
            moreBarButton.isSelected = true
            moreBarButton.image = UIImage(systemName: "line.3.horizontal.decrease")?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
        } else {
            moreBarButton.isSelected = false
            moreBarButton.image = UIImage(systemName: "ellipsis")
        }
    }

    func updateMoreMenu() {
        let selectAction = UIAction(
            title: NSLocalizedString("SELECT"),
            image: UIImage(systemName: "checkmark.circle")
        ) { [weak self] _ in
            guard let self else { return }
            self.setEditing(true, animated: true)
        }

        let layoutActions = [
            UIAction(
                title: NSLocalizedString("LAYOUT_GRID"),
                image: UIImage(systemName: "square.grid.2x2"),
                state: usesListLayout ? .off : .on
            ) { [weak self] _ in
                guard let self, self.usesListLayout else { return }
                self.usesListLayout = false
                self.collectionView.setCollectionViewLayout(self.makeCollectionViewLayout(), animated: true)
                self.collectionView.reloadData()
                self.updateMoreMenu()
            },
            UIAction(
                title: NSLocalizedString("LAYOUT_LIST"),
                image: UIImage(systemName: "list.bullet"),
                state: usesListLayout ? .on : .off
            ) { [weak self] _ in
                guard let self, !self.usesListLayout else { return }
                self.usesListLayout = true
                self.collectionView.setCollectionViewLayout(self.makeCollectionViewLayout(), animated: true)
                self.collectionView.reloadData()
                self.updateMoreMenu()
            }
        ]

        let sortMenu = UIMenu(
            title: NSLocalizedString("SORT_BY"),
            subtitle: viewModel.sortMethod.title,
            image: UIImage(systemName: "arrow.up.arrow.down"),
            children: [
                UIMenu(options: .displayInline, children: LibraryViewModel.SortMethod.allCases.map { method in
                    UIAction(
                        title: method.title,
                        state: viewModel.sortMethod == method ? .on : .off
                    ) { [weak self] _ in
                        self?.setSort(method: method, ascending: false)
                    }
                }),
                UIMenu(options: .displayInline, children: [false, true].map { ascending in
                    UIAction(
                        title: ascending ? viewModel.sortMethod.ascendingTitle : viewModel.sortMethod.descendingTitle,
                        state: viewModel.sortAscending == ascending ? .on : .off
                    ) { [weak self] _ in
                        guard let self else { return }
                        self.setSort(method: self.viewModel.sortMethod, ascending: ascending)
                    }
                })
            ]
        )

        let filterMenu = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else {
                completion([])
                return
            }
            let attributes: UIMenuElement.Attributes = if #available(iOS 16.0, *) {
                .keepsMenuPresented
            } else {
                []
            }
            let filters = UIMenu(
                title: NSLocalizedString("BUTTON_FILTER"),
                subtitle: self.filtersSubtitle(),
                image: UIImage(systemName: "line.3.horizontal.decrease"),
                children: LibraryViewModel.FilterMethod.allCases.compactMap { method in
                    guard method.isAvailable else { return nil }
                    return UIAction(
                        title: method.title,
                        image: method.image,
                        attributes: attributes,
                        state: self.filterState(for: method)
                    ) { [weak self] _ in
                        self?.toggleFilter(method: method)
                    }
                } + [
                    UIMenu(
                        title: LibraryViewModel.FilterMethod.contentRating.title,
                        image: LibraryViewModel.FilterMethod.contentRating.image,
                        children: MangaContentRating.allCases.map { rating in
                            UIAction(
                                title: rating.title,
                                attributes: attributes,
                                state: self.filterState(for: .contentRating, value: rating.stringValue)
                            ) { [weak self] _ in
                                self?.toggleFilter(method: .contentRating, value: rating.stringValue)
                            }
                        }
                    ),
                    UIMenu(
                        title: LibraryViewModel.FilterMethod.source.title,
                        image: LibraryViewModel.FilterMethod.source.image,
                        children: self.viewModel.sourceKeys.map { key in
                            UIAction(
                                title: SourceManager.shared.source(for: key)?.name ?? key,
                                attributes: attributes,
                                state: self.filterState(for: .source, value: key)
                            ) { [weak self] _ in
                                self?.toggleFilter(method: .source, value: key)
                            }
                        }
                    )
                ]
            )
            if self.viewModel.filters.isEmpty {
                completion([filters])
            } else {
                completion([filters, self.removeFilterAction()])
            }
        }

        moreBarButton.menu = UIMenu(
            children: [
                UIMenu(options: .displayInline, children: [selectAction]),
                UIMenu(options: .displayInline, children: layoutActions),
                UIMenu(options: .displayInline, children: [sortMenu, filterMenu])
            ]
        )

        if #available(iOS 26.0, *) {
            if !viewModel.filters.isEmpty {
                moreBarButton.isSelected = true
                moreBarButton.image = UIImage(systemName: "line.3.horizontal.decrease")?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
            } else {
                moreBarButton.isSelected = false
                moreBarButton.image = UIImage(systemName: "ellipsis")
            }
        }
    }
}
