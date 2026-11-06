import UIKit
import AVKit
import AVFoundation

/// 离线播放器。播的是下载到沙盒里的 `local.m3u8` 或 `media.mp4` —— 完全不走网络。
///
/// 用 AVPlayerViewController 而不是自绘，是为了白拿三件东西：
/// 系统级播放控制条、画中画、AirPlay 路由。这三样正是"套壳"和"App"的分界线。
final class OfflinePlayerController: AVPlayerViewController {

    private let localURL: URL

    init(localURL: URL, title: String) {
        self.localURL = localURL
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        activateAudioSession()

        let item = AVPlayerItem(asset: AVURLAsset(url: localURL))
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player

        allowsPictureInPicturePlayback = true
        showsPlaybackControls = true
        videoGravity = .resizeAspect
        if #available(iOS 14.2, *) {
            canStartPictureInPictureAutomaticallyFromInline = true
        }

        addCloseButton()
        player.play()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        player?.play()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        player?.pause()
    }

    // MARK: - 私有

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    /// AVPlayerViewController 直接 modal 出来没有关闭按钮，补一个。
    private func addCloseButton() {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.tintColor = UIColor(hex: 0xF4F2EE)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        button.layer.cornerRadius = 18
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        view.addSubview(button)

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            button.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    @objc private func handleClose() {
        player?.pause()
        dismiss(animated: true)
    }
}
