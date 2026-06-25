//
//  TimelineStrip.swift
//  long-exposures
//
//  Phase 3: a strip of frame thumbnails with two range handles. Dragging a
//  handle changes which frames blend. The selection band dims the excluded
//  frames so the included range reads clearly.
//

import SwiftUI

struct TimelineStrip: View {

    let thumbnails: [UIImage]
    @Binding var selectionStart: Int
    @Binding var selectionEnd: Int

    private let thumbHeight: CGFloat = 56
    private let handleWidth: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let count = max(thumbnails.count, 1)
            let slotWidth = geo.size.width / CGFloat(count)
            let lower = CGFloat(min(selectionStart, selectionEnd))
            let upper = CGFloat(max(selectionStart, selectionEnd))

            ZStack(alignment: .leading) {
                thumbnailRow(slotWidth: slotWidth)
                dimming(lower: lower, upper: upper, slotWidth: slotWidth, height: geo.size.height)
                selectionBorder(lower: lower, upper: upper, slotWidth: slotWidth, height: geo.size.height)

                handle(forStart: true, slotWidth: slotWidth, count: count, height: geo.size.height)
                handle(forStart: false, slotWidth: slotWidth, count: count, height: geo.size.height)
            }
        }
        .frame(height: thumbHeight)
    }

    private func thumbnailRow(slotWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: slotWidth, height: thumbHeight)
                    .clipped()
            }
        }
    }

    private func dimming(lower: CGFloat, upper: CGFloat, slotWidth: CGFloat, height: CGFloat) -> some View {
        // Two scrims over the excluded leading and trailing regions.
        HStack(spacing: 0) {
            Color.black.opacity(0.55)
                .frame(width: lower * slotWidth)
            Color.clear
                .frame(width: (upper - lower + 1) * slotWidth)
            Color.black.opacity(0.55)
        }
        .allowsHitTesting(false)
    }

    private func selectionBorder(lower: CGFloat, upper: CGFloat, slotWidth: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(Color.accentColor, lineWidth: 2.5)
            .frame(width: (upper - lower + 1) * slotWidth, height: height)
            .offset(x: lower * slotWidth)
            .allowsHitTesting(false)
    }

    private func handle(forStart isStart: Bool, slotWidth: CGFloat, count: Int, height: CGFloat) -> some View {
        let index = isStart ? min(selectionStart, selectionEnd) : max(selectionStart, selectionEnd)
        // Start handle sits at the leading edge of its slot; end handle at the trailing edge.
        let centerX = isStart
            ? CGFloat(index) * slotWidth
            : CGFloat(index + 1) * slotWidth

        return RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: height + 8)
            .overlay(
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2, height: height * 0.4)
            )
            .position(x: centerX, y: height / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let raw = Int((value.location.x / slotWidth).rounded(.down))
                        let clamped = min(max(raw, 0), count - 1)
                        if isStart {
                            selectionStart = min(clamped, max(selectionStart, selectionEnd))
                        } else {
                            selectionEnd = max(clamped, min(selectionStart, selectionEnd))
                        }
                    }
            )
    }
}
