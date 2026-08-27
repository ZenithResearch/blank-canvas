import SwiftUI

struct HUDView: View {
    @ObservedObject var model: RuntimeModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statusCard

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let installed = model.installedPack {
                        installedControls(installed)
                    }

                    if let packs = model.catalog?.packs, !packs.isEmpty {
                        catalogSection(packs)
                    } else if model.installedPack == nil {
                        emptyState
                    }
                }
            }
            .frame(maxHeight: 460)

            HStack {
                Button("Browse online", action: model.openGallery)
                    .buttonStyle(.link)
                Spacer()
                Button("Refresh", action: model.refreshCatalog)
                    .buttonStyle(.borderless)
                    .disabled(model.isBusy)
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .padding(18)
        .frame(width: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .padding(10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .foregroundStyle(.indigo)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 1) {
                Text("blank-canvas")
                    .font(.system(size: 16, weight: .bold))
                HStack(spacing: 6) {
                    Text("Wallpaper runtime · 2.0.0")
                    if model.configuration.channel == .staging {
                        Text("STAGING")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.13), in: Capsule())
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if model.isBusy { ProgressView().controlSize(.small) }
                Circle()
                    .fill(model.errorMessage == nil ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(model.status)
                    .font(.system(size: 11, weight: .semibold))
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.configuration.channel == .staging {
                Text(model.configuration.catalogURL.absoluteString)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.8))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private func catalogSection(_ packs: [CatalogPack]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("WALLPAPER CATALOGUE")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.secondary)

            ForEach(packs) { pack in
                catalogRow(pack)
            }
        }
    }

    private func catalogRow(_ pack: CatalogPack) -> some View {
        let active = model.isActive(pack)
        let downloaded = model.isDownloaded(pack)

        return HStack(spacing: 10) {
            AsyncImage(url: model.configuration.browserAssetURL(pack.previewURL)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.indigo.opacity(0.14))
                }
            }
            .frame(width: 72, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(pack.title)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    if pack.featured {
                        Text("FEATURED")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(.indigo)
                    }
                }
                Text(pack.summary)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("v\(pack.currentVersion)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            Button {
                model.install(pack)
            } label: {
                if active {
                    Image(systemName: "checkmark.circle.fill")
                } else {
                    Text(downloaded ? "Use" : "Get")
                }
            }
            .buttonStyle(.bordered)
            .disabled(active || model.isBusy)
            .accessibilityLabel(active ? "\(pack.title) is active" : "\(downloaded ? "Use" : "Download") \(pack.title)")
        }
        .padding(9)
        .background(active ? Color.indigo.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    private func installedControls(_ installed: InstalledPack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(installed.manifest.id.replacingOccurrences(of: "-", with: " ").capitalized)
                        .font(.system(size: 15, weight: .bold))
                    Text("Downloaded · available offline · v\(installed.manifest.version)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(installed.manifest.actions) { action in
                    Button {
                        model.runAction(action.id)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: action.symbol)
                            Text(action.title).font(.system(size: 10.5, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(11)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This canvas is intentionally empty.")
                .font(.system(size: 14, weight: .bold))
            Text("No wallpaper ships inside the app. Connect to the Zenith catalog to download a signed world.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
    }
}
