//
//  EditorView.swift
//  long-exposures
//
//  The interactive editor. Preview canvas on top, mode picker, and a
//  timeline strip with range handles below. Dragging the handles re-blends the
//  selected frames live (at preview resolution).
//

import SwiftUI

struct EditorView: View {

    @Bindable var model: EditorViewModel

    var body: some View {
        VStack(spacing: 20) {
            previewCanvas
            modePicker
            adjustments
            timelineSection
            exportSection
        }
        .padding()
    }

    private var exportSection: some View {
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
            .disabled(model.isExporting)

            if model.isExporting {
                ProgressView()
            }
            if let message = model.exportMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        // Press and hold to compare the blend against a single sharp frame.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !model.isComparing { model.isComparing = true } }
                .onEnded { _ in model.isComparing = false }
        )
    }

    private var adjustments: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggleRow(
                title: "Align frames",
                caption: "basically tryna sharpen background",
                isOn: $model.registrationEnabled
            )
            toggleRow(
                title: "Match exposure",
                caption: "even out brightness",
                isOn: $model.normalizationEnabled
            )
            toggleRow(
                title: "Smooth motion",
                caption: model.flowUnavailable
                    ? "motion analysis isn't available for this clip — nothing was smoothed"
                    : "fill gaps between frames so fast motion streaks instead of ghosting",
                isOn: $model.interpolationEnabled,
                isWarning: model.flowUnavailable
            )
        }
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
