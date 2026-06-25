//
//  OnboardingView.swift
//  long-exposures
//
//  Phase 8: a short first-launch intro explaining the concept — pick a clip, drag
//  to choose which frames blend, and the blend modes. Shown once (gated on
//  AppSettings.hasSeenOnboarding); re-openable from Settings.
//

import SwiftUI

struct OnboardingView: View {

    /// Called when the user finishes or skips the intro.
    let onFinish: () -> Void

    @State private var page = 0

    private let pages: [Page] = [
        Page(icon: "camera.aperture",
             title: "Make a long exposure",
             body: "Blend the frames of a Live Photo or video into one image — smooth water, light trails, motion blur. All on your device."),
        Page(icon: "slider.horizontal.below.rectangle",
             title: "You pick the frames",
             body: "Drag the timeline handles to choose exactly which frames blend together. The preview updates as you go."),
        Page(icon: "square.stack.3d.up",
             title: "Choose how they blend",
             body: "Average for motion blur, Lighten for light trails, Darken for the opposite. Then save or share your result.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { onFinish() }
                    .font(.subheadline)
                    .padding()
            }

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    card(pages[index]).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(page < pages.count - 1 ? "Next" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }

    private func card(_ page: Page) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: page.icon)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(page.title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text(page.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private struct Page {
        let icon: String
        let title: String
        let body: String
    }
}
