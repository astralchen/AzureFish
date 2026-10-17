import AzureFishAPI
import AzureFishChat
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

final class LiveMessageCell: QuickLayoutCollectionViewCell {
    private let bubble = LiveTextBubble(), sender = UILabel(), status = UILabel()
    private var text: UILabel { bubble.label }
    private var outgoing = false
    private let mediaPreview = UIImageView()
    private let mediaProgress = UIActivityIndicatorView(style: .medium)
    private var hasMedia = false
    private var mediaHeight: CGFloat = 44
    private var mediaIdentity: String?
    private var mediaTask: Task<Void, Never>?
    override init(frame: CGRect) {
        super.init(frame: frame)
        mediaPreview.contentMode = .scaleAspectFit
        mediaPreview.clipsToBounds = true
        mediaPreview.layer.cornerRadius = 12
        quickLayoutHorizontalFlexibility = .fixedSize
        quickLayoutVerticalFlexibility = .fullyFlexible
        for label in [text, sender, status] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        text.font = .preferredFont(forTextStyle: .body)
        sender.font = .preferredFont(forTextStyle: .caption1)
        status.font = .preferredFont(forTextStyle: .caption2)
        sender.textColor = .secondaryLabel
        status.textColor = .secondaryLabel
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        HStack(spacing: 0) {
            if outgoing { Spacer() }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 4) {
                if sender.text?.isEmpty == false { sender.resizable(axis: .horizontal) }
                if hasMedia {
                    ZStack { mediaPreview.resizable(); mediaProgress }.frame(height: mediaHeight).frame(maxWidth: .infinity)
                }
                bubble.resizable(axis: .horizontal)
                if status.text?.isEmpty == false { status.resizable(axis: .horizontal) }
            }.frame(maxWidth: min(420, max(160, contentView.bounds.width * 0.78)))
            if !outgoing { Spacer() }
        }.padding(.horizontal, 12).padding(.vertical, 4)
    }
    func configure(_ row: LiveMessageRow) {
        outgoing = row.outgoing
        text.text = row.text
        sender.text = row.sender
        status.text = row.status
        text.textColor = outgoing ? .white : .label
        bubble.backgroundColor = outgoing ? .systemBlue : .secondarySystemBackground
        bubble.setNeedsQuickLayout()
        setNeedsQuickLayout()
    }
    func configureMedia(_ message: ChatMessage?, runtime: ChatRuntime) {
        let asset = message?.assets.first
        let resource = asset?.resources.first { ["thumbnail", "cover", "preview"].contains($0.role) }
        let identity = message.map { $0.id + ":" + (resource?.id ?? "") }
        guard identity != mediaIdentity else { return }
        mediaTask?.cancel(); mediaIdentity = identity
        hasMedia = asset != nil
        mediaHeight = resource == nil ? 44 : 160
        mediaPreview.image = UIImage(systemName: asset?.kind == "audio" ? "waveform" : asset?.kind == "video" ? "play.rectangle.fill" : "doc.fill")
        mediaProgress.stopAnimating(); setNeedsQuickLayout()
        guard let message, let resource, let queue = runtime.transfers, let media = runtime.media else { return }
        mediaProgress.startAnimating()
        mediaTask = Task { [weak self] in
            do {
                let id = try await queue.download(resource, message: message.id)
                try Task.checkCancellation()
                let url = try await media.lease(id)
                let image = UIImage(contentsOfFile: url.path)
                try await media.release(url)
                guard !Task.isCancelled, self?.mediaIdentity == identity else { return }
                self?.mediaPreview.image = image
                self?.mediaProgress.stopAnimating()
            } catch {
                if self?.mediaIdentity == identity { self?.mediaProgress.stopAnimating() }
            }
        }
    }
    override func prepareForReuse() {
        super.prepareForReuse(); mediaTask?.cancel(); mediaIdentity = nil
        hasMedia = false; mediaPreview.image = nil; mediaProgress.stopAnimating()
    }
    deinit { mediaTask?.cancel() }

}

#if DEBUG
@available(iOS 17.0, *)
    #Preview("聊天气泡") {
        let cell = LiveMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        cell.configure(
            .init(
                id: "preview", text: "周末去海边走走吗？", sender: "林沐", status: "", outgoing: false,
                sequence: 1))
        return cell
    }
#endif
