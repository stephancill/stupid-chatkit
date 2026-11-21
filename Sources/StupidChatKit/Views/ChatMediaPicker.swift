import Photos
import UIKit
import UniformTypeIdentifiers

/// The composer's attachment sheet: a strip of the user's recent photos to pick from in order, the camera and Files
/// below it, and the whole library from the top bar. The sheet opens as tall as what it shows; pulled up to full
/// height, the strip becomes a grid of the recent photos, keeping what's picked.
final class ChatMediaPicker: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
    UICollectionViewDataSourcePrefetching, PHPhotoLibraryChangeObserver, UISheetPresentationControllerDelegate
{
    private enum Section {
        /// Recent photos, scrolling sideways.
        case recents
        /// Asks for access to photos when there's none.
        case access
        case actions
    }

    private struct Action {
        let title: String
        let image: String
        let choice: Choice
    }

    enum Choice {
        case assets([PHAsset])
        case library
        case files
        case camera
    }

    private static let thumbnailSide: CGFloat = 112
    private static let rowHeight: CGFloat = 52

    private let limit: Int
    private let onChoose: (Choice) -> Void
    private var assets: PHFetchResult<PHAsset>?
    /// Picked assets' local identifiers, in the order they were picked.
    private var picked: [String] = []
    private let imageManager = PHCachingImageManager()
    private var collectionView: UICollectionView!
    private var actions: [Action] = []
    private var hasAccess = true
    private var sections: [Section] = [.actions]
    /// At full height the recents show as a grid, without the actions below them.
    private var expanded = false
    private lazy var libraryItem = UIBarButtonItem(title: "All Photos", primaryAction: UIAction { [weak self] _ in
        self?.choose(.library)
    })
    private lazy var addItem = UIBarButtonItem(title: "Add", primaryAction: UIAction { [weak self] _ in self?.add() })

    init(limit: Int, onChoose: @escaping (Choice) -> Void) {
        self.limit = max(1, limit)
        self.onChoose = onChoose
        super.init(nibName: nil, bundle: nil)
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            actions.append(Action(title: "Camera", image: "camera", choice: .camera))
        }
        actions.append(Action(title: "Add Files", image: "doc.badge.arrow.up", choice: .files))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    /// The picker in a navigation controller, as a sheet sized to its content.
    func wrapped() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.custom(identifier: Self.contentDetent) { [weak self] context in
                min(context.maximumDetentValue, self?.contentHeight ?? 360)
            }, .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.delegate = self
        }
        return navigation
    }

    private static let contentDetent = UISheetPresentationController.Detent.Identifier("content")

    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheet: UISheetPresentationController) {
        let expanded = sheet.selectedDetentIdentifier == .large
        guard expanded != self.expanded else { return }
        self.expanded = expanded
        reload()
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
    }

    /// The navigation bar, the strip (or the access row) and the action rows, with the insets between them.
    private var contentHeight: CGFloat {
        let top: CGFloat = hasAccess ? Self.thumbnailSide + 20 : Self.rowHeight + 36
        return 56 + top + CGFloat(actions.count) * Self.rowHeight + 36
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        if #available(iOS 26.0, *) {
            addItem.style = .prominent
        } else {
            addItem.style = .done
        }
        updateTitle()

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.alwaysBounceVertical = false
        collectionView.register(ChatMediaPickerCell.self, forCellWithReuseIdentifier: ChatMediaPickerCell.reuseIdentifier)
        collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "row")
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        loadLibrary()
    }

    // MARK: - Choosing

    private func choose(_ choice: Choice) {
        let onChoose = onChoose
        dismiss(animated: true) { onChoose(choice) }
    }

    private func add() {
        guard let assets else { return }
        let byId = Dictionary(uniqueKeysWithValues: (0 ..< assets.count).map { (assets[$0].localIdentifier, assets[$0]) })
        choose(.assets(picked.compactMap { byId[$0] }))
    }

    /// With nothing picked the top bar offers the whole library; once something is, it adds what's picked.
    private func updateTitle() {
        navigationItem.title = picked.isEmpty ? "Add Attachment" : "\(picked.count) Selected"
        let item = picked.isEmpty ? libraryItem : addItem
        if navigationItem.rightBarButtonItem !== item {
            navigationItem.setRightBarButton(item, animated: true)
        }
    }

    // MARK: - Library

    private func loadLibrary() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            fetchAssets()
            PHPhotoLibrary.shared().register(self)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                Task { @MainActor [weak self] in self?.loadLibrary() }
            }
        default:
            hasAccess = false
            reload()
        }
    }

    private func fetchAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 500
        assets = PHAsset.fetchAssets(with: .image, options: options)
        let ids = Set((0 ..< (assets?.count ?? 0)).compactMap { assets?[$0].localIdentifier })
        picked.removeAll { !ids.contains($0) }
        hasAccess = true
        updateTitle()
        reload()
    }

    private func reload() {
        let top: [Section] = hasAccess ? (assets?.count ?? 0) > 0 ? [.recents] : [] : [.access]
        sections = expanded && top == [.recents] ? top : top + [.actions]
        collectionView.reloadData()
        navigationController?.sheetPresentationController?.invalidateDetents()
    }

    nonisolated func photoLibraryDidChange(_: PHChange) {
        Task { @MainActor [weak self] in self?.fetchAssets() }
    }

    // MARK: - Layout

    private func layout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, sections.indices.contains(index) else { return nil }
            switch sections[index] {
            case .recents where expanded:
                let columns = environment.container.effectiveContentSize.width > 500 ? 5 : 3
                let fraction = 1 / CGFloat(columns)
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(fraction), heightDimension: .fractionalHeight(1)))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(fraction)),
                    repeatingSubitem: item,
                    count: columns,
                )
                group.interItemSpacing = .fixed(2)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 2
                return section
            case .recents:
                let side = Self.thumbnailSide
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .absolute(side)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: item.layoutSize, subitems: [item])
                let section = NSCollectionLayoutSection(group: group)
                section.orthogonalScrollingBehavior = .continuous
                section.interGroupSpacing = 6
                section.contentInsets = .init(top: 4, leading: 16, bottom: 16, trailing: 16)
                return section
            case .access, .actions:
                var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                list.backgroundColor = .clear
                let section = NSCollectionLayoutSection.list(using: list, layoutEnvironment: environment)
                section.contentInsets.top = 4
                return section
            }
        }
    }

    private var thumbnailSize: CGSize {
        let points = expanded ? view.bounds.width / 3 : Self.thumbnailSide
        let side = points * (view.window?.screen.scale ?? 3)
        return CGSize(width: side, height: side)
    }

    // MARK: - Data

    func numberOfSections(in _: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_: UICollectionView, numberOfItemsInSection index: Int) -> Int {
        switch sections[index] {
        case .recents: assets?.count ?? 0
        case .access: 1
        case .actions: actions.count
        }
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        switch sections[indexPath.section] {
        case .recents:
            return photoCell(collectionView, at: indexPath)
        case .access:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath) as! UICollectionViewListCell
            var content = cell.defaultContentConfiguration()
            content.image = UIImage(systemName: "photo.on.rectangle")
            content.text = "Allow Access to Photos"
            content.secondaryText = "See your recent photos here."
            content.imageProperties.tintColor = .label
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
            return cell
        case .actions:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath) as! UICollectionViewListCell
            let action = actions[indexPath.item]
            var content = cell.defaultContentConfiguration()
            content.image = UIImage(systemName: action.image)
            content.imageProperties.tintColor = .label
            content.text = action.title
            content.textProperties.font = .preferredFont(forTextStyle: .body)
            cell.contentConfiguration = content
            cell.accessories = []
            return cell
        }
    }

    private func photoCell(_ collectionView: UICollectionView, at indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ChatMediaPickerCell.reuseIdentifier, for: indexPath) as! ChatMediaPickerCell
        guard let asset = assets?[indexPath.item] else { return cell }
        cell.assetId = asset.localIdentifier
        cell.contentView.layer.cornerRadius = expanded ? 0 : 12
        cell.order = picked.firstIndex(of: asset.localIdentifier).map { $0 + 1 }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        imageManager.requestImage(for: asset, targetSize: thumbnailSize, contentMode: .aspectFill, options: options) { image, _ in
            if cell.assetId == asset.localIdentifier { cell.imageView.image = image }
        }
        return cell
    }

    func collectionView(_: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let assets, let recents = sections.firstIndex(of: .recents) else { return }
        let items = indexPaths.filter { $0.section == recents }.map { assets[$0.item] }
        imageManager.startCachingImages(for: items, targetSize: thumbnailSize, contentMode: .aspectFill, options: nil)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch sections[indexPath.section] {
        case .recents:
            toggle(indexPath)
            return false
        case .access:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .actions:
            choose(actions[indexPath.item].choice)
        }
        collectionView.deselectItem(at: indexPath, animated: true)
        return false
    }

    private func toggle(_ indexPath: IndexPath) {
        guard let id = assets?[indexPath.item].localIdentifier else { return }
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
        } else if picked.count < limit {
            picked.append(id)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        UISelectionFeedbackGenerator().selectionChanged()
        updateTitle()
        // Every picked cell's number can shift, so refresh the visible ones.
        for case let cell as ChatMediaPickerCell in collectionView.visibleCells {
            cell.order = cell.assetId.flatMap { picked.firstIndex(of: $0) }.map { $0 + 1 }
        }
    }

    // MARK: - Loading picked photos

    /// The picked photo as the composer stages it: GIFs as they are, so they stay animated; anything else as JPEG.
    @MainActor
    static func attachment(for asset: PHAsset) async -> ChatAttachment? {
        let baseName = PHAssetResource.assetResources(for: asset).first.map { ($0.originalFilename as NSString).deletingPathExtension } ?? "photo"
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.version = .current
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, type, _, _ in
                guard let data else { return continuation.resume(returning: nil) }
                if type == UTType.gif.identifier {
                    return continuation.resume(returning: .init(data: data, mimeType: "image/gif", filename: "\(baseName).gif", isImage: true))
                }
                let jpeg = UIImage(data: data).flatMap { ChatImageEncoding.jpeg(from: $0) }
                continuation.resume(returning: jpeg.map { .init(data: $0, mimeType: "image/jpeg", filename: "\(baseName).jpg", isImage: true) })
            }
        }
    }
}

/// A recent photo in the picker's strip, with a circle in its corner that shows its place in the order once picked.
private final class ChatMediaPickerCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatMediaPickerCell"

    let imageView = UIImageView()
    var assetId: String?
    var order: Int? {
        didSet { updateBadge() }
    }

    private let badge = UILabel()
    private let dim = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemFill
        contentView.layer.cornerRadius = 12
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        dim.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        dim.frame = contentView.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.isHidden = true
        contentView.addSubview(dim)

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.textAlignment = .center
        badge.font = .systemFont(ofSize: 14, weight: .semibold)
        badge.textColor = .white
        badge.layer.cornerRadius = 13
        badge.layer.borderWidth = 1.5
        badge.layer.borderColor = UIColor.white.cgColor
        badge.layer.masksToBounds = true
        badge.layer.shadowOpacity = 0
        contentView.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
            badge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        updateBadge()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        assetId = nil
        order = nil
    }

    private func updateBadge() {
        badge.text = order.map(String.init)
        badge.backgroundColor = order == nil ? UIColor.black.withAlphaComponent(0.15) : tintColor
        dim.isHidden = order == nil
        accessibilityLabel = "Photo"
        accessibilityValue = order.map { "Selected, \($0)" }
        accessibilityTraits = order == nil ? .button : [.button, .selected]
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateBadge()
    }
}
