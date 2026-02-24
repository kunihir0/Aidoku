//
//  MangaView+Components.swift
//  Aidoku
//
//  Created by Gemini on 2/16/26.
//

import SwiftUI
import AidokuRunner

struct ChapterCellView<T: View>: View, Equatable {
    let source: AidokuRunner.Source?
    let sourceKey: String
    let chapter: AidokuRunner.Chapter
    let read: Bool
    let page: Int?
    let downloadStatus: DownloadStatus
    let downloadProgress: Float?
    let displayMode: ChapterTitleDisplayMode
    let isEditing: Bool

    var onPressed: (() -> Void)?
    var contextMenu: (() -> T)?

    private var locked: Bool {
        chapter.locked && !(downloadStatus == .finished)
    }

    var body: some View {
        let view = HStack {
            ChapterTableCell(
                source: source,
                sourceKey: sourceKey,
                chapter: chapter,
                read: read,
                page: page,
                downloadStatus: downloadStatus,
                downloadProgress: downloadProgress,
                displayMode: displayMode
            )
        }
        if isEditing {
            view
        } else {
            Button {
                onPressed?()
            } label: {
                view
            }
            .tint(.primary)
            .contextMenu {
                if !locked {
                    contextMenu?()
                }
            }
        }
    }

    static nonisolated func == (lhs: ChapterCellView<T>, rhs: ChapterCellView<T>) -> Bool {
        lhs.chapter == rhs.chapter
            && lhs.read == rhs.read
            && lhs.page == rhs.page
            && lhs.downloadStatus == rhs.downloadStatus
            && lhs.downloadProgress == rhs.downloadProgress
            && lhs.displayMode == rhs.displayMode
            && lhs.isEditing == rhs.isEditing
    }
}

struct RightNavbarButton: View, Equatable {
    let bookmarked: Bool
    let hasCategories: Bool
    let url: URL?
    let hasDownloads: Bool
    let isEditing: Bool

    let markAllRead: () -> Void
    let markAllUnread: () -> Void
    let editCategories: () -> Void
    let migrate: () -> Void
    let showShareSheet: (URL) -> Void
    let removeDownloads: () -> Void

    @Binding var editMode: EditMode

    init(
        viewModel: MangaView.ViewModel,
        markAllRead: @escaping () -> Void,
        markAllUnread: @escaping () -> Void,
        editCategories: @escaping () -> Void,
        migrate: @escaping () -> Void,
        showShareSheet: @escaping (URL) -> Void,
        removeDownloads: @escaping () -> Void,
        editMode: Binding<EditMode>
    ) {
        self.bookmarked = viewModel.bookmarked
        self.hasCategories = !CoreDataManager.shared.getCategories(sorted: false).isEmpty
        self.url = viewModel.manga.url
        self.hasDownloads = viewModel.downloadStatus.contains(where: { $0.value == .finished })
        self.markAllRead = markAllRead
        self.markAllUnread = markAllUnread
        self.editCategories = editCategories
        self.migrate = migrate
        self.showShareSheet = showShareSheet
        self.removeDownloads = removeDownloads
        self.isEditing = editMode.wrappedValue == .active
        self._editMode = editMode
    }

    var body: some View {
        if editMode == .inactive {
            Menu {
                Menu(NSLocalizedString("MARK_ALL")) {
                    Button {
                        markAllRead()
                    } label: {
                        Label(NSLocalizedString("READ"), systemImage: "eye")
                    }
                    Button {
                        markAllUnread()
                    } label: {
                        Label(NSLocalizedString("UNREAD"), systemImage: "eye.slash")
                    }
                }
                Button {
                    withAnimation {
                        editMode = .active
                    }
                } label: {
                    Label(NSLocalizedString("SELECT_CHAPTERS"), systemImage: "checkmark.circle")
                }
                if bookmarked {
                    if hasCategories {
                        Button {
                            editCategories()
                        } label: {
                            Label(NSLocalizedString("EDIT_CATEGORIES"), systemImage: "folder.badge.gearshape")
                        }
                    }
                    Button {
                        migrate()
                    } label: {
                        Label(NSLocalizedString("MIGRATE"), systemImage: "arrow.left.arrow.right")
                    }
                }
                if let url {
                    Button {
                        showShareSheet(url)
                    } label: {
                        Label(NSLocalizedString("SHARE"), systemImage: "square.and.arrow.up")
                    }
                }

                if hasDownloads {
                    Divider()
                    Button(role: .destructive) {
                        removeDownloads()
                    } label: {
                        Label(
                            NSLocalizedString("REMOVE_ALL_DOWNLOADS"),
                            systemImage: "trash"
                        )
                    }
                }
            } label: {
                MoreIcon()
            }
        } else {
            DoneButton {
                withAnimation {
                    editMode = .inactive
                }
            }
        }

    }

    static nonisolated func == (lhs: RightNavbarButton, rhs: RightNavbarButton) -> Bool {
        lhs.bookmarked == rhs.bookmarked
            && lhs.hasCategories == rhs.hasCategories
            && lhs.url == rhs.url
            && lhs.hasDownloads == rhs.hasDownloads
            && lhs.isEditing == rhs.isEditing
    }
}
