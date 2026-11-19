"""Small deterministic picture and sound sources for the reference cut."""

from array import array
import math
from pathlib import Path
import random
import struct
import wave
import zlib

from mix_export import ff


WIDTH, HEIGHT, FPS = 320, 180, 24
RATE = 48_000
# Label the SD-size fixtures with a common matrix so AVFoundation and ffmpeg do not guess from their codecs.
COLOR = ["-color_primaries", "smpte170m", "-color_trc", "bt709", "-colorspace", "smpte170m"]


def write_png(path, colors):
    """Write equal-width strips of solid RGBA, including the invisible and partial-alpha samples."""
    def chunk(kind, content):
        return struct.pack(">I", len(content)) + kind + content + struct.pack(">I", zlib.crc32(kind + content))

    row = bytes(channel for x in range(WIDTH) for channel in colors[x * len(colors) // WIDTH])
    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 6, 0, 0, 0)
    filtered = zlib.compress((b"\0" + row) * HEIGHT)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", filtered) + chunk(b"IEND", b""))


def make_shot(work, ffmpeg, name, color, frequency, gain, *, stray=False):
    filters = ["-vf", "drawbox=color=0x29C33E:t=fill:enable='gte(t,2.4166)'"] if stray else []
    audio = f"{gain}*sin(2*PI*{frequency}*t)"
    ff(ffmpeg, "-v", "error", "-f", "lavfi", "-i", f"color=c={color}:size={WIDTH}x{HEIGHT}:rate={FPS}",
       "-f", "lavfi", "-i", f"aevalsrc={audio}|{audio}:s={RATE}", *filters,
       "-t", 4, "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", *COLOR, "-c:a", "aac",
       "-b:a", "192k", work / name)


def write_music(path):
    """A steady bed with a dozen kicks and one deliberately stronger attack at 1.5 s."""
    noise = random.Random(43)
    samples = array("h")
    for index in range(6 * RATE):
        time = index / RATE
        kick = math.floor(time * 2)
        age = time - kick / 2
        sample = 0.02 * math.sin(2 * math.pi * 120 * time)
        if kick > 0 and age < 0.18:
            gain = 0.73 if kick == 3 else 0.28
            sample += gain * math.sin(2 * math.pi * (55 + 65 * math.exp(-age * 30)) * age) * math.exp(-age * 14)
            if age < 0.03:
                sample += gain * 0.25 * noise.uniform(-1, 1) * math.exp(-age * 90)
        samples.append(round(sample * 32767))
    with wave.open(str(path), "wb") as output:
        output.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        output.writeframes(samples.tobytes())


def make_reference_media(work, ffmpeg):
    make_shot(work, ffmpeg, "amber.mp4", "0xC34232", 240, 0.04, stray=True)
    make_shot(work, ffmpeg, "blue.mp4", "0x264A92", 360, 0.25)
    make_shot(work, ffmpeg, "slate.mp4", "0x294057", 540, 0.012)
    # Untagged ProRes alpha is interpreted as premultiplied. The middle strip's RGB has already been multiplied by alpha.
    alpha = work / "alpha-input.png"
    write_png(alpha, [(0, 0, 0, 0), (15, 102, 24, 128), (30, 204, 48, 255)])
    ff(ffmpeg, "-v", "error", "-loop", 1, "-framerate", FPS, "-i", alpha, "-t", 1,
       "-c:v", "prores_ks", "-profile:v", 4, "-pix_fmt", "yuva444p10le", *COLOR, work / "alpha.mov")
    alpha.unlink()
    write_png(work / "still.png", [(0, 0, 0, 0), (238, 186, 50, 255)])
    voice = r"0.15*sin(2*PI*100*t)+0.22*sin(2*PI*960*t)+0.10*sin(2*PI*4000*t)"
    ff(ffmpeg, "-v", "error", "-f", "lavfi", "-i", f"aevalsrc={voice}|{voice}:s={RATE}:d=1",
       "-c:a", "pcm_f32le", work / "narrator.wav")
    write_music(work / "accents.wav")
    (work / "caption.srt").write_text("1\n00:00:04,250 --> 00:00:04,750\nFIELD CAPTION\n", encoding="utf-8")



PAGE = Path(__file__).with_name("ink-plate.html").read_text(encoding="utf-8")
