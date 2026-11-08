#!/usr/bin/env python3
"""BOJI 三联动音效合成（标准库，无第三方依赖）。

按《design-previews/2plus3-三联动设计表.md》§1/§2 规格合成 6 个短促点缀音：
48kHz / 16bit / 单声道，正弦基频 + 2~3 个泛音 + 指数衰减包络，峰值 -6 dBFS。
输出 BojiClub/Sounds/boji_*.caf（主格式，iOS 原生）与同名 .wav（保底）。

CAF 封装为最小合法线性 PCM 容器（caff + desc + data）。desc 按 Apple
《Core Audio File Format》为 40 字节定长、字段全 32 位；lpcm flags 取
kCAFLinearPCMFormatFlagIsLittleEndian (1<<1)，即小端 16bit 有符号整数，
与 afconvert LEI16@48000 输出同型。自校验会读回并断言这些字段。

用法：python scripts/make_interaction_sounds.py [--wav-only]
"""

from __future__ import annotations

import json
import math
import struct
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "BojiClub" / "Sounds"

SAMPLE_RATE = 48_000
PEAK = 10 ** (-6 / 20)  # -6 dBFS

# §2 六个音色的合成参数：
# partials: [(频率倍数, 相对幅度, 衰减时间常数 tau 秒), ...]
# notes: [(起始秒, 基频 Hz), ...] 依次叠入
SOUNDS = {
    "boji_tap": {  # S1 轻触点：木头轻叩
        "duration": 0.07,
        "notes": [(0.0, 1150.0)],
        "partials": [(1.0, 1.0, 0.010), (2.0, 0.45, 0.007), (3.0, 0.22, 0.005)],
        "body": 0.55,  # 木质感：低频敲击层幅度
        "body_hz": 320.0,
        "body_tau": 0.006,
    },
    "boji_set_done": {  # S2 一组完成：金属「咔」+ 木尾
        "duration": 0.15,
        "notes": [(0.0, 980.0)],
        "partials": [(1.0, 1.0, 0.022), (3.0, 0.5, 0.038), (4.0, 0.32, 0.045)],
        "body": 0.35,
        "body_hz": 300.0,
        "body_tau": 0.010,
    },
    "boji_milestone": {  # S3 里程碑：两音上行，带共鸣
        "duration": 0.28,
        "notes": [(0.0, 880.0), (0.06, 1320.0)],
        "partials": [(1.0, 1.0, 0.055), (2.0, 0.30, 0.040), (3.0, 0.14, 0.030)],
        "body": 0.22,
        "body_hz": 440.0,
        "body_tau": 0.020,
    },
    "boji_workout_done": {  # S4 训练完成：三音上行小和弦 + 尾巴
        "duration": 0.55,
        "notes": [(0.0, 660.0), (0.09, 880.0), (0.18, 1320.0)],
        "partials": [(1.0, 1.0, 0.120), (2.0, 0.34, 0.100), (3.0, 0.16, 0.080)],
        "body": 0.18,
        "body_hz": 330.0,
        "body_tau": 0.070,
        "tail": {"tau": 0.110, "gain": 0.30},  # 末尾混响感：整体延长衰减层
    },
    "boji_rest_tick": {  # S5 组间计时：极轻木鱼，短促无尾
        "duration": 0.05,
        "notes": [(0.0, 1500.0)],
        "partials": [(1.0, 1.0, 0.007), (2.0, 0.35, 0.005)],
        "body": 0.30,
        "body_hz": 480.0,
        "body_tau": 0.004,
    },
    "boji_error": {  # S6 错误：低沉双音下行，闷、短、无金属
        "duration": 0.22,
        "notes": [(0.0, 320.0), (0.08, 240.0)],
        "partials": [(1.0, 1.0, 0.075), (2.0, 0.18, 0.050)],
        "body": 0.10,
        "body_hz": 140.0,
        "body_tau": 0.040,
    },
}


def attack_envelope(i: int, attack: int) -> float:
    """起音窗：前 attack 个样本线性抬升，防爆音。"""
    return min(1.0, (i + 1) / max(1, attack)) if attack else 1.0


def synthesize(spec: dict) -> list[float]:
    """按规格合成一轨浮点样本。"""
    n = int(SAMPLE_RATE * spec["duration"])
    out = [0.0] * n
    attack = int(SAMPLE_RATE * 0.002)  # 2ms 起音
    for start, hz in spec["notes"]:
        offset = int(SAMPLE_RATE * start)
        for ratio, gain, tau in spec["partials"]:
            for i in range(offset, n):
                t = (i - offset) / SAMPLE_RATE
                env = attack_envelope(i - offset, attack) * math.exp(-t / tau)
                out[i] += gain * env * math.sin(2 * math.pi * hz * ratio * t)
        if spec.get("body"):
            for i in range(offset, n):
                t = (i - offset) / SAMPLE_RATE
                env = attack_envelope(i - offset, attack) * math.exp(-t / spec["body_tau"])
                out[i] += spec["body"] * env * math.sin(2 * math.pi * spec["body_hz"] * t)
    if tail := spec.get("tail"):
        # 末尾混响感：对已合成信号做单次指数衰减叠加（廉价卷积尾）
        start = int(SAMPLE_RATE * 0.5 * spec["duration"])
        for i in range(start, n):
            t = (i - start) / SAMPLE_RATE
            src = out[max(0, i - int(SAMPLE_RATE * 0.012))]
            out[i] += tail["gain"] * src * math.exp(-t / tail["tau"])
    peak = max(abs(v) for v in out) or 1.0
    scale = PEAK / peak
    return [v * scale for v in out]


def write_wav(path: Path, samples: list[float]) -> None:
    """标准 WAV（可被 wave 模块读回校验）。"""
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        frames = bytearray()
        for v in samples:
            frames += struct.pack("<h", max(-32767, min(32767, int(v * 32767))))
        w.writeframes(bytes(frames))


def write_caf(path: Path, samples: list[float]) -> None:
    """最小合法 CAF：caff 头 + desc + data（均为大端 chunk 封装）。

    desc 是 CAF 的 AudioDescription：40 字节定长，字段宽全为 32 位
    （sample_rate f64 + format_id 4s + 7 个 uint32）。lpcm flags 按
    Apple《Core Audio File Format》规范：bit0=Float、bit1=LittleEndian，
    2 = 小端有符号整数，与 afconvert LEI16@48000 输出同型。
    """
    pcm = bytearray()
    for v in samples:
        pcm += struct.pack("<h", max(-32767, min(32767, int(v * 32767))))
    desc = struct.pack(
        ">d4sIIIIIII",
        float(SAMPLE_RATE),  # mSampleRate
        b"lpcm",  # mFormatID
        1 << 1,  # mFormatFlags: kCAFLinearPCMFormatFlagIsLittleEndian
        2,  # mBytesPerPacket
        1,  # mFramesPerPacket
        2,  # mBytesPerFrame
        1,  # mChannelsPerFrame
        16,  # mBitsPerChannel
        0,  # 保留位
    )
    assert len(desc) == 40, "CAF desc 必须是 40 字节定长"
    with path.open("wb") as f:
        f.write(b"caff")
        f.write(struct.pack(">HH", 1, 0))
        f.write(b"desc")
        f.write(struct.pack(">Q", len(desc)))
        f.write(desc)
        f.write(b"data")
        f.write(struct.pack(">Q", len(pcm)))
        f.write(pcm)


def verify(path: Path) -> dict:
    """读回 CAF 自校验：magic、desc 定长与字段、data 长度；返回指标。"""
    raw = path.read_bytes()
    assert raw[:4] == b"caff", "CAF magic 不对"
    version, _ = struct.unpack(">HH", raw[4:8])
    assert version == 1, "CAF 版本不对"
    assert raw[8:12] == b"desc", "desc chunk 缺失"
    (dsize,) = struct.unpack(">Q", raw[12:20])
    assert dsize == 40, f"desc 长度应为 40，实为 {dsize}"
    rate, fmt, flags, bpp, fpp, bpf, ch, bits, _ = struct.unpack(">d4sIIIIIII", raw[20:60])
    assert fmt == b"lpcm" and flags == (1 << 1), f"lpcm/小端标志不符：{fmt} {flags}"
    assert (bpp, fpp, bpf, ch, bits) == (2, 1, 2, 1, 16), "desc 音频参数与规格不符"
    assert raw[60:64] == b"data", "data chunk 缺失"
    (psize,) = struct.unpack(">Q", raw[64:72])
    assert psize == len(raw) - 72, "data 长度与文件不一致"
    samples = struct.unpack(f"<{psize // 2}h", raw[72 : 72 + psize])
    peak = max(abs(s) for s in samples) / 32767
    rms = math.sqrt(sum(s * s for s in samples) / len(samples)) / 32767
    return {
        "file": path.name,
        "sample_rate": int(rate),
        "format": fmt.decode(),
        "flags": flags,
        "channels": ch,
        "bits": bits,
        "seconds": round(len(samples) / rate, 3),
        "peak_dbfs": round(20 * math.log10(peak), 2),
        "rms_dbfs": round(20 * math.log10(rms), 2),
        "bytes": path.stat().st_size,
    }


def main() -> int:
    wav_only = "--wav-only" in sys.argv
    OUT.mkdir(parents=True, exist_ok=True)
    report = []
    for name, spec in SOUNDS.items():
        samples = synthesize(spec)
        wav_path = OUT / f"{name}.wav"
        write_wav(wav_path, samples)
        # 用 wave 模块读回核对时长与声道
        with wave.open(str(wav_path), "rb") as w:
            assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (SAMPLE_RATE, 1, 2)
            assert abs(w.getnframes() / SAMPLE_RATE - spec["duration"]) < 1 / SAMPLE_RATE
        if not wav_only:
            caf_path = OUT / f"{name}.caf"
            write_caf(caf_path, samples)
            report.append(verify(caf_path))
        else:
            report.append({"file": wav_path.name, "seconds": spec["duration"]})
    (OUT / "sounds-manifest.json").write_text(
        json.dumps(
            {"sample_rate": SAMPLE_RATE, "peak_dbfs": -6, "sounds": report},
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
