//
//  LibraryView.swift
//  long-exposures
//
//  The in-app gallery of saved long exposures. Grid of thumbnails;
//  tapping one opens a detail view to share, save to Photos, or delete.
//

import SwiftUI

struct LibraryView: View {

    @Bindable var library: LibraryStore
    @State private var selected: Exposure?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 4)]

    var body: some View {
        Group {
            if library.exposures.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(library.exposures) { exposure in
                            thumbnail(for: exposure)
                                .onTapGesture { selected = exposure }
                        }
                    }
                    .padding(4)
                }
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { exposure in
            ExposureDetailView(library: library, exposure: exposure)
        }
    }

    private func thumbnail(for exposure: Exposure) -> some View {
        Group {
            if let image = library.image(for: exposure) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No saved exposures yet")
                .font(.headline)
            Text("Blend a Live Photo and tap Save to add it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct ExposureDetailView: View {

    @Bindable var library: LibraryStore
    let exposure: Exposure
    @Environment(\.dismiss) private var dismiss

    @State private var isSharing = false
    @State private var saveMessage: String?
    @State private var isSavingToPhotos = false

    private var image: UIImage? { library.image(for: exposure) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }

                Text("\(exposure.mode.capitalized) · \(exposure.frameCount) frames")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let saveMessage {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await saveToPhotos() }
                    } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSavingToPhotos)

                    Button {
                        isSharing = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Exposure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        library.delete(exposure)
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete exposure")
                }
            }
            .sheet(isPresented: $isSharing) {
                if let image { ShareSheet(items: [image]) }
            }
        }
    }

    private func saveToPhotos() async {
        guard let cgImage = image?.cgImage else { return }
        isSavingToPhotos = true
        defer { isSavingToPhotos = false }
        do {
            try await ExportService.saveToPhotos(cgImage)
            saveMessage = "Saved to Photos."
        } catch {
            saveMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}
