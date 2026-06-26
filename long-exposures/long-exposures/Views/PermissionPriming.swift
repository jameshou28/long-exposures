//
//  PermissionPriming.swift
//  long-exposures
//
//  A friendly explainer shown *before* the cold system permission prompt,
//  so the user understands why access is needed and taps "Continue" intentionally
//  rather than reflexively declining an unexplained prompt.
//

import SwiftUI

struct PermissionPriming: View {

    enum Kind: String, Identifiable {
        case photos
        case camera
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .photos: return "photo.on.rectangle.angled"
            case .camera: return "camera"
            }
        }
        var title: String {
            switch self {
            case .photos: return "Access your photos"
            case .camera: return "Use the camera"
            }
        }
        var message: String {
            switch self {
            case .photos:
                return "Long Exposures needs access to your photo library to import the Live Photo or video you want to blend. Everything is processed on your device — nothing is uploaded."
            case .camera:
                return "Long Exposures needs the camera to record a new clip with locked exposure, so the frames blend cleanly. Recording stays on your device — nothing is uploaded."
            }
        }
    }

    let kind: Kind
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: kind.icon)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(kind.title)
                .font(.title2.weight(.semibold))
            Text(kind.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            Button("Not now", action: onCancel)
                .font(.subheadline)
        }
        .padding(24)
        .padding(.bottom, 8)
        .presentationDetents([.medium, .large])
    }
}
