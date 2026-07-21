import SwiftUI

struct SmartShortcutsView: View {
    @ObservedObject var vm: SmartShortcutsViewModel
    @State private var showPrerequisiteWarning = false
    
    var body: some View {
        // Plain ScrollView (not SmoothPageScroll) on purpose: this screen is a
        // grid of NavigationLinks, and SmoothPageScroll's single List row makes a
        // link tap highlight the whole page blue. See Formrules 3.1.
        ScrollView {
            VStack(spacing: 24) {
                
                MasterHeaderView(
                    title: "Smart Shortcuts",
                    subtitle: "Manage your shell aliases and functions",
                    image: "command.square.fill",
                    color: .blue
                )
                
                // Tip Box (consistent spacing from header)
                BannerView(
                    .tip,
                    message: "After installing a shortcut, close and reopen Terminal to start using it right away!"
                )
                
                // Prerequisites Warning
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
                
                // Search & Filter Card
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
                
                // Shortcuts Grid
                if vm.isLoading {
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
                            .buttonStyle(.plain)
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
        // navigationDestination MUST live outside the List (lazy container) or
        // SwiftUI ignores it and the detail never opens.
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

    // MARK: - Category Pill
    
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
            .buttonStyle(.plain)
        }
    }
