import AVFoundation
import Foundation

// MARK: - 三联动音效管理类（批次 2 · 2plus3 三联动设计表 + 文案定稿第十七节）
//
// 规格落点：
// - 6 个 .caf 素材（BojiClub/Sounds/，48kHz/16bit/单声道，峰值 -6dBFS）启动预加载 prepareToPlay；
// - AVAudioSession .ambient：硬件静音开关天然优先（静音时无声，触感与文案不受影响）；
// - 设置页「互动音效」开关，默认开（DEC-6）；关闭只停音效，触感/动效照常；
// - 一屏最多一个音效：0.05s 去抖，快速连发只响最后一次；
// - 时序：触感先、音效随（≤40ms），set_done 贴 latch 第二脉冲（+55ms）——play(id, delay:) 支持。

enum BojiSoundID: String, CaseIterable {
    /// S1 轻触点（木头轻叩 0.07s）：tab 切换、日历选日、步进器、展开
    case tap = "boji_tap"
    /// S2 一组完成（金属咔+木尾 0.15s）：完成一组打勾、AI 分析完成
    case setDone = "boji_set_done"
    /// S3 里程碑（两音上行 0.28s）：全组完成、破 PR、徽章解锁
    case milestone = "boji_milestone"
    /// S4 训练完成（三音和弦 0.55s）：整堂训练保存收官
    case workoutDone = "boji_workout_done"
    /// S5 组间计时（极轻木鱼 0.05s）：休息开始/结束最后 3 秒
    case restTick = "boji_rest_tick"
    /// S6 错误（低沉下行 0.22s）：保存失败/断网；永不配拟人腔文案
    case error = "boji_error"
}

@MainActor
enum BojiSound {
    /// 设置页开关存储键；默认开（DEC-6：三联动是卖点不是彩蛋）。
    static let enabledDefaultsKey = "boji.soundEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledDefaultsKey) }
    }

    private static var players: [BojiSoundID: AVAudioPlayer] = [:]
    private static var lastPlay: (id: BojiSoundID, at: TimeInterval)?
    private static var sessionReady = false

    /// App 启动调用：预加载 6 个 player；.ambient 跟随静音开关、不打断他人音频。
    static func preload() {
        guard !sessionReady else { return }
        sessionReady = true
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        for id in BojiSoundID.allCases {
            guard players[id] == nil,
                  let url = Bundle.main.url(forResource: id.rawValue, withExtension: "caf", subdirectory: "Sounds"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            players[id] = player
        }
    }

    /// 触发点统一入口：与 BojiHaptics 在同一 action 闭包里顺序调用（同一拍）。
    /// - delay: 贴触感第二脉冲用（如 latch 后 +0.055s 响 set_done）；默认 0 即同刻。
    static func play(_ id: BojiSoundID, delay: TimeInterval = 0) {
        guard isEnabled, let player = players[id] else { return }
        let now = Date().timeIntervalSinceReferenceDate
        if let last = lastPlay, last.id == id, now - last.at < 0.05 { return }
        lastPlay = (id, now)
        if delay > 0 {
            player.currentTime = 0
            // play(atTime:) 用音频时间线：session 当前时间 + delay 秒
            player.play(atTime: AVAudioSession.sharedInstance().currentTime + delay)
        } else {
            player.currentTime = 0
            player.play()
        }
    }

    /// 供测试与调试：释放缓存（正常生命周期不调用）。
    static func resetForTesting() {
        players.removeAll(); lastPlay = nil; sessionReady = false
    }
}
