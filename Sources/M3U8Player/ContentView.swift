import SwiftUI
import AVFoundation
import Observation

// MARK: - Player Controller (@Observable, macOS 26)

@Observable @MainActor
final class PlayerController {

    // MARK: - State (auto-tracked by @Observable)

    var selectedChannelIndex = 0
    var showBanner           = true
    var currentTime: Date    = .now
    var playerVolume: Float  = 1.0
    var showVolumeHUD        = false
    var numberInput          = ""
    var showNumberInput      = false
    var videoResolution: CGSize = .zero

    // MARK: - Derived (resolution)

    /// 실제 스트림 해상도 기반 레이블 (아직 수신 전이면 "—")
    var resolutionLabel: String {
        let h = Int(videoResolution.height)
        let w = Int(videoResolution.width)
        guard h > 0 else { return "—" }
        switch h {
        case 2160...: return "4K"
        case 1080...: return "FHD"
        case 720...:  return "HD"
        default:      return "\(w)×\(h)"
        }
    }

    // MARK: - Immutable

    let player   = AVPlayer()
    let channels = Channel.loadFromBundle()

    // MARK: - Derived

    var selectedChannel: Channel { channels[selectedChannelIndex] }
    var prevChannel: Channel     { channels[(selectedChannelIndex - 1 + channels.count) % channels.count] }
    var nextChannel: Channel     { channels[(selectedChannelIndex + 1) % channels.count] }

    // MARK: - Cancellation tokens

    private var bannerToken      = UUID()
    private var volumeToken      = UUID()
    private var inputToken       = UUID()
    private var resolutionObserver: NSKeyValueObservation?

    // MARK: - Lifecycle

    func start() { load(selectedChannel); scheduleBannerDismiss() }
    func tick() { currentTime = .now }

    // MARK: - Channel Navigation

    func channelUp()   { navigate(by: -1) }
    func channelDown() { navigate(by:  1) }

    private func navigate(by offset: Int) {
        let n = channels.count
        selectedChannelIndex = ((selectedChannelIndex + offset) % n + n) % n
        load(selectedChannel)
        revealBanner()
    }

    func switchToChannel(_ number: Int) {
        guard let idx = channels.firstIndex(where: { $0.number == number }) else { return }
        selectedChannelIndex = idx
        load(selectedChannel)
        revealBanner()
    }

    // MARK: - Volume

    func adjustVolume(by delta: Float) {
        let raw = min(1.0, max(0.0, playerVolume + delta))
        playerVolume = (raw * 20).rounded() / 20
        player.volume = playerVolume
        showVolumeHUD = true
        let t = UUID(); volumeToken = t
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard self.volumeToken == t else { return }
            self.showVolumeHUD = false
        }
    }

    // MARK: - Remote Digit Input

    func handleDigit(_ digit: String) {
        if numberInput.count >= 3 { numberInput = "" }
        numberInput += digit
        showNumberInput = true
        revealBanner()
        let t = UUID(); inputToken = t
        Task {
            try? await Task.sleep(for: .milliseconds(1800))
            guard self.inputToken == t else { return }
            if let num = Int(self.numberInput) { self.switchToChannel(num) }
            self.numberInput    = ""
            self.showNumberInput = false
        }
    }

    // MARK: - Banner

    func toggleBanner() {
        if showBanner { bannerToken = UUID(); showBanner = false }
        else { revealBanner() }
    }

    // MARK: - Private

    private func revealBanner() { showBanner = true; scheduleBannerDismiss() }

    private func scheduleBannerDismiss() {
        let t = UUID(); bannerToken = t
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard self.bannerToken == t else { return }
            self.showBanner = false
        }
    }

    private func load(_ channel: Channel) {
        videoResolution = .zero       // 채널 전환 시 초기화
        let item = AVPlayerItem(url: channel.url)
        player.replaceCurrentItem(with: item)
        player.play()
        // presentationSize 가 .zero → 실제 값으로 바뀐는 순간 한 번만 관찰
        resolutionObserver = item.observe(\.presentationSize, options: [.new]) { [weak self] observedItem, _ in
            let size = observedItem.presentationSize
            guard size != .zero else { return }
            Task { @MainActor [weak self] in
                self?.videoResolution = size
            }
        }
    }
}

// MARK: - AVPlayerLayer wrapper (no HUD)

final class _PlayerNSView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError() }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

struct VideoLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> _PlayerNSView {
        let v = _PlayerNSView()
        v.playerLayer.player = player
        return v
    }
    func updateNSView(_ view: _PlayerNSView, context: Context) { }
}

// MARK: - Root View

struct ContentView: View {
    @State private var ctrl = PlayerController()

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            VideoLayerView(player: ctrl.player)
                .ignoresSafeArea()

            // Tap anywhere to toggle info bar
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { ctrl.toggleBanner() }

            // Top-right channel badge (channel change & digit input)
            if ctrl.showBanner || ctrl.showNumberInput {
                ChannelBadgeView(ctrl: ctrl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)),
                        removal:   .opacity
                    ))
                    .allowsHitTesting(false)
            }

            // Volume HUD — 우측 세로 게이지
            if ctrl.showVolumeHUD {
                VolumeBar(volume: ctrl.playerVolume)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 48)
                    .padding(.bottom, ctrl.showBanner ? 120 : 0)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            // Bottom info bar
            if ctrl.showBanner {
                ChannelInfoBar(ctrl: ctrl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: ctrl.showBanner)
        .animation(.easeInOut(duration: 0.20), value: ctrl.showVolumeHUD)
        .animation(.easeInOut(duration: 0.18), value: ctrl.showNumberInput)
        .focusable()
        .onKeyPress(.upArrow)    { ctrl.channelUp();              return .handled }
        .onKeyPress(.downArrow)  { ctrl.channelDown();            return .handled }
        .onKeyPress(.leftArrow)  { ctrl.adjustVolume(by: -0.05); return .handled }
        .onKeyPress(.rightArrow) { ctrl.adjustVolume(by:  0.05); return .handled }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            ctrl.handleDigit(press.characters); return .handled
        }
        .onAppear { ctrl.start() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                ctrl.tick()
            }
        }
    }
}

// MARK: - Top-Right Channel Badge
// Shows when channel changes (number + name) or while typing digits (input only)

struct ChannelBadgeView: View {
    let ctrl: PlayerController

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            if ctrl.showNumberInput {
                // Digit entry in progress
                Text(ctrl.numberInput.isEmpty ? "—" : ctrl.numberInput)
                    .font(.system(size: 108, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("CH")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            } else {
                // Confirmed channel — 번호 아래로 중앙정렬
                Text("\(ctrl.selectedChannel.number)")
                    .font(.system(size: 108, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(ctrl.selectedChannel.name)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
                // 실제 해상도 배지
                Text(ctrl.resolutionLabel)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.white, lineWidth: 1.5)
                    }
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 3)
        .padding(.top, 40)
        .padding(.trailing, 48)
    }
}

// MARK: - Bottom Channel Info Bar

struct ChannelInfoBar: View {
    let ctrl: PlayerController

    var body: some View {
        VStack(spacing: 0) {

            // ── Row 1: channel identifier + program title ──────────────
            HStack(alignment: .center, spacing: 0) {
                // Channel number · name · 실제 해상도 배지
                HStack(alignment: .center, spacing: 10) {
                    Text(String(format: "%03d %@",
                                ctrl.selectedChannel.number,
                                ctrl.selectedChannel.name))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                    Text(ctrl.resolutionLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(.white.opacity(0.85), lineWidth: 1)
                        }
                }
                .frame(minWidth: 200, alignment: .leading)

                Spacer()

                // Program title (center)
                Text("라이브 방송 중")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                // Placeholder right (keeps title centered)
                Spacer().frame(minWidth: 200)
            }
            .padding(.horizontal, 36)
            .padding(.top, 20)
            .padding(.bottom, 14)

            // ── Thin white separator ──────────────────────────────────
            Rectangle()
                .fill(.white.opacity(0.75))
                .frame(height: 1)

            // ── Row 2: navigation hint + time ───────────────────────
            HStack {
                // ↕ 채널 탐색 · ↔ 볼륨 조절 (1줄)
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 13, weight: .medium))
                        Text("채널 탐색")
                            .font(.system(size: 15))
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 13, weight: .medium))
                        Text("볼륨 조절")
                            .font(.system(size: 15))
                    }
                }
                .foregroundStyle(.white.opacity(0.60))

                Spacer()

                // Current time
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 13))
                    Text("현재시간  \(ctrl.currentTime.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 15, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(.white.opacity(0.60))

                Spacer()

                // Audio
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 13))
                    Text("STEREO")
                        .font(.system(size: 15))
                }
                .foregroundStyle(.white.opacity(0.60))
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 13)
        }
        .background(.black.opacity(0.70))
    }
}

// MARK: - Volume Bar (세로 대시 게이지, 우측 배치)

struct VolumeBar: View {
    let volume: Float

    private let totalSegments = 20

    private var filledSegments: Int {
        Int((volume * Float(totalSegments)).rounded())
    }

    private var iconName: String {
        switch volume {
        case 0:         "speaker.slash.fill"
        case ..<0.35:   "speaker.wave.1.fill"
        case ..<0.70:   "speaker.wave.2.fill"
        default:        "speaker.wave.3.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 볼륨 숫자
            Text("\(Int(volume * 100))")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.bottom, 10)

            // 세로 대시 게이지 — 위가 높은 벼륨
            VStack(spacing: 5) {
                ForEach((0..<totalSegments).reversed(), id: \.self) { i in
                    Capsule()
                        .fill(i < filledSegments
                              ? Color.white
                              : Color.white.opacity(0.18))
                        .frame(width: 32, height: 3)
                        .animation(.easeOut(duration: 0.08), value: filledSegments)
                }
            }

            // 스피커 아이콘
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background(.black.opacity(0.70))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
