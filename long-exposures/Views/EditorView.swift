//
//  EditorView.swift
//  long-exposures
//
//  Phase 3: the interactive editor. Preview canvas on top, mode picker, and a
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
            timelineSection
        }
        .padding()
    }

    private var previewCanvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black)
            if let image = model.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                ProgressView()
                    .tint(.white)
            }
            if model.isBlending {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
    }

    private var modePicker: some View {
        Picker("Blend mode", selection: $model.mode) {
            Text("Average").tag(BlendMode.average)
            Text("Lighten").tag(BlendMode.lighten)
            Text("Darken").tag(BlendMode.darken)
        }
        .pickerStyle(.segmented)
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
