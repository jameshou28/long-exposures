//
//  EditorView.swift
//  long-exposures
//
//  photo editting
//

import SwiftUI

struct EditorView: View {

    @Bindable var model: EditorViewModel
    @State private var isSharingVideo = false
    @State private var adjustmentsExpanded = true
    @State private var exportExpanded = true

    var body: some View {
        VStack(spacing: 16) {
            previewCanvas
                .padding(.horizontal)
            ScrollView {
                VStack(spacing: 20) {
                    adjustments
                    exportSection
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }
        }
        .padding(.top)
    }

    private var exportSection: some View {
        DisclosureGroup(isExpanded: $exportExpanded) {
            VStack(spacing: 10) {
                Picker("Resolution", selection: $model.exportResolution) {
                    Text("Full").tag(ExportResolution.full)
                    Text("Standard").tag(ExportResolution.standard)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    Button {
                        Task { await model.export(saveToPhotos: false) }
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await model.export(saveToPhotos: true) }
                    } label: {
                        Label("Save to Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .disabled(model.isExporting || model.isExportingVideo)

                Button {
                    Task { await model.exportVideo() }
                } label: {
                    Label("Build-up video", systemImage: "film")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isExporting || model.isExportingVideo)

                if model.isExportingVideo {
                    ProgressView(value: model.videoProgress)
                } else if model.isExporting {
                    ProgressView()
                }

                if model.videoURL != nil && !model.isExportingVideo {
                    HStack(spacing: 12) {
                        Button {
                            Task { await model.saveVideoToPhotos() }
                        } label: {
                            Label("Save video", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            isSharingVideo = true
                        } label: {
                            Label("Share video", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let message = model.exportMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Export")
                .font(.headline)
                .foregroundStyle(.black)
        }
        .sheet(isPresented: $isSharingVideo) {
            if let url = model.videoURL { ShareSheet(items: [url]) }
        }
    }

    private var previewCanvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black)
            if let error = model.previewError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            } else if let image = model.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                ProgressView()
                    .tint(.white)
            }
            if model.isBlending || model.isComputingFlow {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding()
            }
            if model.isComparing {
                Text("Original frame")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .frame(minHeight: 260)
        .layoutPriority(1)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !model.isComparing { model.isComparing = true } }
                .onEnded { _ in model.isComparing = false }
        )
    }

    private var adjustments: some View {
        DisclosureGroup(isExpanded: $adjustmentsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                modePicker
                toggleRow(
                    title: "Align frames",
                    caption: "Sharpen background",
                    isOn: $model.registrationEnabled
                )
                toggleRow(
                    title: "Match exposure",
                    caption: "Even out the brightness",
                    isOn: $model.normalizationEnabled
                )
                toggleRow(
                    title: "Smooth motion",
                    caption: model.flowUnavailable
                        ? "motion analysis isn't available for this clip — nothing was smoothed"
                        : "Fill gaps between frames",
                    isOn: $model.interpolationEnabled,
                    isWarning: model.flowUnavailable
                )
                timelineSection
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text("Adjustments")
                    .font(.headline)
                    .foregroundStyle(.black)
                if !adjustmentsExpanded {
                    if model.flowUnavailable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    } else if !activeAdjustments.isEmpty {
                        Text(activeAdjustments.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private var activeAdjustments: [String] {
        var names: [String] = []
        if model.registrationEnabled { names.append("Align") }
        if model.normalizationEnabled { names.append("Exposure") }
        if model.interpolationEnabled { names.append("Motion") }
        return names
    }

    private func toggleRow(title: String, caption: String, isOn: Binding<Bool>,
                           isWarning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: isOn) { Text(title) }
                .disabled(model.isRegistering)
            Text(caption)
                .font(.caption)
                .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }

    private var modePicker: some View {
        VStack(spacing: 4) {
            Slider(value: $model.blendBias, in: -1...1) {
                Text("Blend")
            } minimumValueLabel: {
                Image(systemName: "moon.fill")
            } maximumValueLabel: {
                Image(systemName: "sun.max.fill")
            }
            HStack {
                Text("Darken")
                Spacer()
                Text("Average")
                Spacer()
                Text("Lighten")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var timelineSection: some View {
        VStack(spacing: 8) {
            TimelineStrip(
                thumbnails: model.thumbnails,
                selectionStart: $model.selectionStart,
                selectionEnd: $model.selectionEnd
            )
            HStack {
                Text("Frames \(min(model.selectionStart, model.selectionEnd) + 1)–\(max(model.selectionStart, model.selectionEnd) + 1)")
                Spacer()
                Text("\(max(model.selectionStart, model.selectionEnd) - min(model.selectionStart, model.selectionEnd) + 1) of \(model.frameCount)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
