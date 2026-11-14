import os
import sys

from PIL import Image, ImageSequence

# Two 500x500 masters are needed, and they are not in this repository: only the
# finished clips ship. Pass them on the command line so this script carries no
# path of anybody's machine.
# The first three lines stay ASCII on purpose: a Chinese console code page mangles
# the line below them (it did on the machine this was written), and the usage has
# to survive that.
USAGE = """usage: python build-media.py <smack.gif> <wave.gif>

needs two 500x500 GIF masters: tap (10 frames) and wave (66 frames).
they are not in this repo - only the finished clips ship. output goes to media/.
需要两张 500x500 的 GIF 母版：拍击 10 帧、打招呼 66 帧（母版不在本仓库，只有成品随包）。
两个参数依次是拍击与打招呼的母版；成品写到脚本同目录的 media/ 下。
"""

SIZE = 320
COLORS = 96
DURATION = 30
WAVE_SLICE = (22, 33)
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'media')


def master_paths(argv):
    """The two masters from the command line, or None when they cannot be used."""
    if len(argv) < 3:
        return None
    smack, wave = argv[1], argv[2]
    missing = [path for path in (smack, wave) if os.path.isfile(path) is False]
    if missing:
        for path in missing:
            print('master not found: ' + path, file=sys.stderr)
        return None
    return smack, wave


def frames_of(path, bounds=None):
    images = [f.convert('RGBA') for f in ImageSequence.Iterator(Image.open(path))]
    return images[bounds[0]:bounds[1]] if bounds else images


def stage(frames):
    """Keep the artist's framing: the whole 500 px canvas scaled to SIZE, with the
    alpha hardened to 1 bit because GIF has no partial transparency anyway."""
    staged = []
    for frame in frames:
        canvas = frame.resize((SIZE, SIZE), Image.LANCZOS)
        alpha = canvas.getchannel('A').point(lambda a: 255 if a >= 128 else 0)
        canvas.putalpha(alpha)
        staged.append(canvas)
    return staged


def encode(frames, target):
    """Palette slot 0 is reserved as the transparent key, so the picture is
    quantised into slots 1..COLORS-1 and every index is shifted up by one.
    Quantising straight to P (or trusting the adaptive palette) hands slot 0 to a
    real colour, and marking that slot transparent then punches holes through the
    character instead of clearing the background.

    The shift must be i -> i+1: `trimmed` hands out indices 0..COLORS-2, while the
    palette written below puts its first real colour at slot 1. An off-by-one here
    (5.2.0 shipped `[0] + range(0, COLORS-1)`, i.e. i -> i-1) silently recolours
    every pixel to its neighbouring palette entry - red speckles over the hair,
    the red button turning navy, blush turning blue."""
    base = Image.composite(frames[0].convert('RGB'), Image.new('RGB', frames[0].size, (0, 0, 0)), frames[0].getchannel('A'))
    trimmed = base.quantize(colors=COLORS - 1, method=Image.MEDIANCUT)
    palette = [0, 0, 0] + trimmed.getpalette()[: 3 * (COLORS - 1)]
    palette += [0, 0, 0] * (256 - COLORS)
    shift = [0] * 256
    for index in range(COLORS - 1):
        shift[index] = index + 1
    for index in range(COLORS - 1, 256):
        shift[index] = COLORS - 1
    paletted = []
    for frame in frames:
        rgb = Image.composite(frame.convert('RGB'), Image.new('RGB', frame.size, (0, 0, 0)), frame.getchannel('A'))
        indices = rgb.quantize(palette=trimmed, dither=Image.NONE).point(shift)
        clear = frame.getchannel('A').point(lambda a: 255 if a == 0 else 0)
        indices.paste(0, mask=clear)
        indices.putpalette(palette)
        paletted.append(indices)
    paletted[0].save(target, 'GIF', save_all=True, append_images=paletted[1:], duration=DURATION,
                     loop=0, optimize=True, disposal=2, transparency=0)
    print(os.path.basename(target), os.path.getsize(target), 'bytes,', len(paletted), 'frames')


def main(argv):
    paths = master_paths(argv)
    if paths is None:
        print(USAGE, file=sys.stderr)
        return 2
    smack, wave = paths
    os.makedirs(OUT, exist_ok=True)
    encode(stage(frames_of(smack)), os.path.join(OUT, 'smack.gif'))
    encode(stage(frames_of(wave, WAVE_SLICE)), os.path.join(OUT, 'wave.gif'))
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
