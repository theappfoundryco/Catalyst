import SwiftUI

/// The catalog surface for browsing, searching, and installing Smart Shortcuts.
///
/// Renders a searchable, category-filtered grid of ``ShortcutItem`` cards, each wired as
/// a `NavigationLink` into ``ShortcutDetailView``. All catalog data and derived state are
/// owned by ``SmartShortcutsViewModel``; this view is a pure projection of it.
///
/// ```swift
/// SmartShortcutsView(vm: smartShortcutsViewModel)
/// ```
///
/// > Warning: The scroll container is a plain `ScrollView`, never `SmoothPageScroll`. The
/// > latter wraps its content in a single `List` row, which turns any child link's tap
/// > highlight into a full-page blue flash. See `CODING_STANDARDS` §3.1.
///
/// > Warning: `.navigationDestination(for:)` must stay attached to the `ScrollView`,
/// > outside every lazy container. Declared inside the `LazyVGrid`, SwiftUI recycles the
/// > modifier as rows scroll and the destination silently stops resolving.
///
/// > Note: The loading, empty, and grid states are mutually exclusive. The empty state is
/// > gated on ``SmartShortcutsViewModel/hasLoadedOnce`` so it can never flash before the
/// > first load resolves; only a genuine "no results" outcome renders it. This is what
/// > removes the empty-card flicker on a populated catalog.
struct SmartShortcutsView: View {
    @ObservedObject var vm: SmartShortcutsViewModel
    @State private var showPrerequisiteWarning = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                MasterHeaderView(
                    title: "Smart Shortcuts",
                    subtitle: "Manage your shell aliases and functions",
                    image: "command.square.fill",
                    color: .blue
                )

                BannerView(
                    .tip,
                    message: "After installing a shortcut, close and reopen Terminal to start using it right away!"
                )

                if showPrerequisiteWarning && (!vm.isBrewInstalled || !vm.isPythonWithPipAvailable) {
                    VStack(spacing: 12) {
                        BannerView(
                            .warning,
                            title: "Missing Dependencies",
                            message: (!vm.isBrewInstalled && !vm.isPythonWithPipAvailable) ? "Homebrew and Python with pip are not installed\nShortcuts with dependencies may fail to install." :
                                     (!vm.isBrewInstalled) ? "Homebrew is not installed\nShortcuts with dependencies may fail to install." :
                                     "Python with pip is not installed\nShortcuts with dependencies may fail to install."
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("Find Shortcuts")
                        .font(.headline)

                    SectionDivider()

                    SearchBarView(placeholder: "Search shortcuts...", text: $vm.searchQuery)

                    SectionDivider()

                    if !vm.categories.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                CategoryPill(
                                    title: "All",
                                    isSelected: vm.selectedCategory == nil
                                ) {
                                    vm.selectedCategory = nil
                                }

                                ForEach(vm.categories, id: \.self) { category in
                                    CategoryPill(
                                        title: category,
                                        isSelected: vm.selectedCategory == category
                                    ) {
                                        vm.selectedCategory = category
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                        }
                    }
                }
                .cardStyle()

                if vm.isLoading || !vm.hasLoadedOnce {
                    LoadingStateView("Loading shortcuts...")
                        .padding(.vertical, 60)
                        .cardStyle()
                } else if vm.filteredShortcuts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: vm.searchQuery.isEmpty ? "tray" : "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)

                        Text(vm.searchQuery.isEmpty ? "No shortcuts available" : "No matching shortcuts")
                            .font(.headline)

                        if !vm.searchQuery.isEmpty {
                            Text("Try a different search term")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                    .cardStyle()
                } else {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 16) {
                        ForEach(vm.filteredShortcuts) { shortcut in
                            NavigationLink(value: shortcut.id) {
                                ShortcutCard(
                                    shortcut: shortcut,
                                    isInstalled: vm.isInstalled(shortcut.id),
                                    customName: vm.getCustomName(shortcut.id)
                                )
                            }
                            .appButton(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("SmartShortcuts")
        .onAppear {
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                showPrerequisiteWarning = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshToolbarContent(
                    isLoading: vm.isLoading,
                    minimumDelay: 1.5,
                    action: { await vm.refresh() }
                )
            }
        }
        .navigationDestination(for: String.self) { shortcutId in
            ShortcutDetailView(
                shortcutId: shortcutId,
                viewModel: vm
            )
        }
        .task {
            await vm.loadData()
        }
    }
}

/// A tappable pill that scopes the catalog to a single shortcut category.
///
/// Passing `isSelected` drives both the fill and the foreground contrast; the parent owns
/// selection state and mutates it inside `action`.
///
/// ```swift
/// CategoryPill(title: "Git", isSelected: true) { vm.selectedCategory = "Git" }
/// ```
struct CategoryPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(isSelected ? Color.blue : Color(NSColor.controlBackgroundColor))
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
        .appButton(.plain)
    }
}
