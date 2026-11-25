"""Verify the Linux CLI and actual OpenGL output with ordinary comic pages."""

import argparse
import io
import os
from pathlib import Path
import signal
import subprocess
from tempfile import TemporaryDirectory
import time
from zipfile import ZIP_DEFLATED, ZipFile

from PIL import Image


def image_bytes(image, format_name, **options):
    data = io.BytesIO()
    image.save(data, format=format_name, **options)
    return data.getvalue()


def make_comic(path, pages):
    with ZipFile(path, "w", ZIP_DEFLATED) as archive:
        for name, contents in pages:
            archive.writestr(name, contents)
    return path


def test_rendering(app, directory, env):
    settings = ("--single", "--size=800x600")

    def run(*arguments):
        return subprocess.run([app, *arguments], env=env, capture_output=True, text=True, timeout=30)

    def capture(name, book=None, *options):
        output = directory / f"{name}.png"
        args = [*settings, *options, "--screenshot", output]
        if book is not None:
            args.append(book)
        result = run(*args)
        assert result.returncode == 0, result.stderr
        with Image.open(output) as screenshot:
            assert screenshot.size == (800, 600), screenshot.size
            return screenshot.convert("RGB")

    def assert_failure(name, book, *options):
        output = directory / f"{name}.png"
        result = run(*settings, *options, "--screenshot", output, book)
        assert result.returncode != 0 and result.stderr and not output.exists(), (
            name, result.returncode, result.stderr
        )
        return result.stderr

    def compare_samples(left, right, tolerance=0):
        # Samples well inside the page exclude chrome, the title, and interpolation at edges.
        for y in (210, 320, 430):
            for x in (290, 400, 510):
                a, b = left.getpixel((x, y)), right.getpixel((x, y))
                assert all(abs(q - r) <= tolerance for q, r in zip(a, b)), (x, y, a, b)

    capture("empty-ready")
    image = Image.new("RGB", (128, 96), "red")
    image.paste("blue", (64, 0, 128, 48))
    image.paste("green", (0, 48, 64, 96))
    image.paste("yellow", (64, 48, 128, 96))
    transforms = (
        None,
        Image.Transpose.FLIP_LEFT_RIGHT,
        Image.Transpose.ROTATE_180,
        Image.Transpose.FLIP_TOP_BOTTOM,
        Image.Transpose.TRANSPOSE,
        Image.Transpose.ROTATE_270,
        Image.Transpose.TRANSVERSE,
        Image.Transpose.ROTATE_90,
    )
    for orientation, transform in enumerate(transforms, start=1):
        tiff = image_bytes(image, "TIFF", tiffinfo={274: orientation})
        expected = image if transform is None else image.transpose(transform)
        png = image_bytes(expected, "PNG")
        tiff_book = make_comic(directory / f"tiff-{orientation}.cbz", [("01.tiff", tiff)])
        png_book = make_comic(directory / f"png-{orientation}.cbz", [("01.png", png)])
        compare_samples(
            capture(f"tiff-{orientation}-actual", tiff_book),
            capture(f"tiff-{orientation}-expected", png_book),
            tolerance=3,
        )

    translucent = Image.new("RGBA", (128, 96), (230, 20, 40, 128))
    alpha_tiff = make_comic(directory / "alpha-tiff.cbz", [("01.tiff", image_bytes(translucent, "TIFF"))])
    alpha_png = make_comic(directory / "alpha-png.cbz", [("01.png", image_bytes(translucent, "PNG"))])
    compare_samples(capture("alpha-tiff", alpha_tiff), capture("alpha-png", alpha_png), tolerance=2)

    sparse = Image.new("RGBA", (128, 128), (180, 180, 180, 255))
    sparse.paste((245, 5, 5, 255), (53, 53, 55, 55))
    sparse.paste((180, 180, 180, 0), (61, 61, 63, 63))
    sparse_book = make_comic(directory / "sparse.cbz", [("01.png", image_bytes(sparse, "PNG"))])
    middle = capture("sparse", sparse_book, "--zoom=1").crop((340, 265, 460, 375))
    colors = [color for _, color in middle.getcolors(maxcolors=middle.width * middle.height)]
    assert any(r > 200 and g < 30 and b < 30 for r, g, b in colors), "red detail lost"
    assert (20, 21, 24) in colors, "transparent detail lost"

    red = image_bytes(Image.new("RGB", (128, 96), "red"), "PNG")
    blue = image_bytes(Image.new("RGB", (128, 96), "blue"), "PNG")
    book = make_comic(directory / "two pages.cbz", [("01.png", red), ("02.png", blue)])
    assert capture("second-page", book, "--page", "2").getpixel((400, 320)) == (0, 0, 255)
    assert "outside the book" in assert_failure("invalid-page", book, "--page=3")
    assert_failure("missing-book", directory / "missing.cbz")
    empty = make_comic(directory / "empty.cbz", [("01.png", b"")])
    assert "could not be decoded" in assert_failure("empty-page", empty)
    bad_output = directory / "output-is-a-directory.png"
    bad_output.mkdir()
    result = run(*settings, "--screenshot", bad_output, book)
    assert result.returncode == 1 and bad_output.is_dir(), result
    assert not list(directory.glob(".xscomic-screenshot-*")), "partial screenshot left behind"

    for arguments in [
        ["--screenshot"], ["--screenshot="], ["--zoom=nan"], ["--size=invalid"],
        ["--page=invalid"], ["--page=2"], ["--unknown"], [book, book],
    ]:
        assert run(*arguments).returncode == 2, arguments
    assert run("--help").returncode == 0
    print("Linux CLI and pixel checks passed", flush=True)
    return book


def wait_until(condition, explanation):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        result = condition()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError(explanation)


def test_picker(app, directory, env, book):
    stub_dir = directory / "stub-bin"
    stub_dir.mkdir()
    picker = stub_dir / "zenity"
    picker.write_text(
        '#!/bin/sh\n'
        'if [ -e "$XSC_TEST_DIR/picked" ]; then\n'
        '    printf "%s\\n" "$$" > "$XSC_TEST_DIR/picker-open"\n'
        '    exec sleep 60\n'
        'fi\n'
        'touch "$XSC_TEST_DIR/picked"\n'
        'printf "%s\\n" "$XSC_TEST_BOOK"\n'
    )
    picker.chmod(0o755)
    env = {
        **env, "SDL_VIDEODRIVER": "x11", "PATH": f"{stub_dir}:{env['PATH']}",
        "XSC_TEST_DIR": str(directory), "XSC_TEST_BOOK": str(book),
    }

    def xdotool(*arguments):
        return subprocess.run(
            ["xdotool", *arguments], env=env, capture_output=True, text=True, timeout=5
        )

    log_path = directory / "reader.log"
    with log_path.open("wb") as log:
        with subprocess.Popen([app], env=env, stdout=log, stderr=log, start_new_session=True) as reader:
            try:
                window = wait_until(
                    lambda: xdotool("search", "--onlyvisible", "--pid", str(reader.pid)).stdout.strip(),
                    "xsComic X11 window did not appear",
                ).splitlines()[0]
                xdotool("windowfocus", "--sync", window).check_returncode()
                xdotool("key", "ctrl+o").check_returncode()
                wait_until(
                    lambda: book.name in xdotool("getwindowname", window).stdout,
                    "file picker did not open the selected comic",
                )
                xdotool("key", "ctrl+o").check_returncode()
                pid_file = directory / "picker-open"
                wait_until(lambda: pid_file.exists() and pid_file.stat().st_size > 0, "second picker did not start")
                picker_pid = int(pid_file.read_text())
                xdotool("key", "ctrl+q").check_returncode()
                assert reader.wait(timeout=5) == 0
                assert not Path(f"/proc/{picker_pid}").exists(), "reader left the picker running"
            finally:
                # The test owns this process group, including its picker stand-in.
                try:
                    os.killpg(reader.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                reader.wait(timeout=5)
                if log_path.stat().st_size:
                    print(log_path.read_text(), end="")
    print("Linux X11 file picker checks passed", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=lambda value: Path(value).resolve())
    parser.add_argument("--x11", action="store_true", help="exercise the X11 file picker too")
    args = parser.parse_args()
    with TemporaryDirectory(prefix="xscomic-smoke-") as temporary:
        directory = Path(temporary)
        env = {**os.environ, "XDG_CONFIG_HOME": str(directory / "config"), "LIBGL_ALWAYS_SOFTWARE": "1"}
        book = test_rendering(args.app, directory, env)
        if args.x11:
            test_picker(args.app, directory, env, book)


if __name__ == "__main__":
    main()
