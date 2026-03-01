//
//  PublicLinkQRView.swift
//  OpenPhotos
//
//  View for displaying QR code and sharing options for a public link.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

/// View for displaying and sharing a public link QR code
struct PublicLinkQRView: View {
    let link: PublicLink
    let onDismiss: () -> Void

    @State private var qrImage: UIImage?
    @State private var showCopyConfirmation = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Link info
                VStack(spacing: 8) {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)

                    Text(link.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    if let url = link.url {
                        Text(url)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding(.top)

                // QR Code
                if let qrImage = qrImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 250, height: 250)
                        .padding()
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 4)
                } else {
                    ProgressView()
                        .frame(width: 250, height: 250)
                }

                // Action buttons
                VStack(spacing: 12) {
                    Button {
                        copyLinkToClipboard()
                    } label: {
                        Label("Copy Link", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        shareLinkViaSheet()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        openLinkInSafari()
                    } label: {
                        Label("Open in Safari", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Public Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDismiss()
                    }
                }
            }
            .task {
                generateQRCode()
            }
            .alert("Link Copied", isPresented: $showCopyConfirmation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The link has been copied to your clipboard")
            }
        }
    }

    // MARK: - QR Code Generation

    private func generateQRCode() {
        guard let url = link.url else { return }

        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"

        if let outputImage = filter.outputImage {
            // Scale up the QR code for better quality
            let transform = CGAffineTransform(scaleX: 10, y: 10)
            let scaledImage = outputImage.transformed(by: transform)

            if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                qrImage = UIImage(cgImage: cgImage)
            }
        }
    }

    // MARK: - Actions

    private func copyLinkToClipboard() {
        guard let url = link.url else { return }
        UIPasteboard.general.string = url
        showCopyConfirmation = true
    }

    private func shareLinkViaSheet() {
        guard let url = link.url, let linkURL = URL(string: url) else { return }

        let activityVC = UIActivityViewController(
            activityItems: [linkURL],
            applicationActivities: nil
        )

        // Get the root view controller
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            // Find the topmost presented view controller
            var topController = rootViewController
            while let presented = topController.presentedViewController {
                topController = presented
            }
            topController.present(activityVC, animated: true)
        }
    }

    private func openLinkInSafari() {
        guard let url = link.url, let linkURL = URL(string: url) else { return }
        UIApplication.shared.open(linkURL)
    }
}

// MARK: - Navigation-compatible QR View

/// Navigation-compatible version of PublicLinkQRView (no NavigationStack wrapper)
struct PublicLinkQRNavigationView: View {
    let link: PublicLink
    let onDismiss: () -> Void

    @State private var qrImage: UIImage?
    @State private var showCopyConfirmation = false

    var body: some View {
        VStack(spacing: 24) {
            // Link info
            VStack(spacing: 8) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)

                Text(link.name)
                    .font(.title2)
                    .fontWeight(.bold)

                if let url = link.url {
                    Text(url)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(.top)

            // QR Code
            if let qrImage = qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 250, height: 250)
                    .padding()
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 4)
            } else {
                ProgressView()
                    .frame(width: 250, height: 250)
            }

            // Action buttons
            VStack(spacing: 12) {
                Button {
                    copyLinkToClipboard()
                } label: {
                    Label("Copy Link", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    shareLinkViaSheet()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    openLinkInSafari()
                } label: {
                    Label("Open in Safari", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Spacer()
        }
        .navigationTitle("Public Link")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Back") {
                    onDismiss()
                }
            }
        }
        .task {
            generateQRCode()
        }
        .alert("Link Copied", isPresented: $showCopyConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The link has been copied to your clipboard")
        }
    }

    private func generateQRCode() {
        guard let url = link.url else { return }

        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"

        if let outputImage = filter.outputImage {
            let transform = CGAffineTransform(scaleX: 10, y: 10)
            let scaledImage = outputImage.transformed(by: transform)

            if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
                qrImage = UIImage(cgImage: cgImage)
            }
        }
    }

    private func copyLinkToClipboard() {
        guard let url = link.url else { return }
        UIPasteboard.general.string = url
        showCopyConfirmation = true
    }

    private func shareLinkViaSheet() {
        guard let url = link.url, let linkURL = URL(string: url) else { return }

        let activityVC = UIActivityViewController(
            activityItems: [linkURL],
            applicationActivities: nil
        )

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            var topController = rootViewController
            while let presented = topController.presentedViewController {
                topController = presented
            }
            topController.present(activityVC, animated: true)
        }
    }

    private func openLinkInSafari() {
        guard let url = link.url, let linkURL = URL(string: url) else { return }
        UIApplication.shared.open(linkURL)
    }
}

#Preview("Sheet Version") {
    PublicLinkQRView(
        link: PublicLink(
            id: "link1",
            ownerOrgId: 1,
            ownerUserId: "user123",
            name: "Summer Photos",
            scopeKind: "album",
            scopeAlbumId: 42,
            uploadsAlbumId: nil,
            url: "https://example.com/public?k=abc123#vk=xyz789",
            permissions: SharePermissions.viewer.rawValue,
            expiresAt: nil,
            status: "active",
            coverAssetId: "asset123",
            moderationEnabled: false,
            pendingCount: nil,
            hasPin: false,
            key: "abc123",
            createdAt: Date(),
            updatedAt: Date()
        ),
        onDismiss: {}
    )
}
