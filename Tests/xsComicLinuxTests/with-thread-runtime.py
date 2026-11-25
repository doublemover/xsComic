"""Run the TSan suite with libobjc2 instrumented by the same SDK as the suite."""

import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tarfile
import tempfile


def fetch(url, destination, expected_sha256):
    subprocess.run(
        ["curl", "--fail", "--silent", "--show-error", "--location", "--retry", "3",
         "--output", str(destination), url],
        check=True,
    )
    with destination.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != expected_sha256:
            raise ValueError(f"Checksum mismatch for {destination.name}")
    return destination


def release_sources(workdir, target):
    version = os.environ["OBJC3_SDK_VERSION"]
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[a-z0-9.]+)?", version):
        raise ValueError(f"Invalid SDK version {version!r}")
    url = f"https://github.com/doublemover/Slopjective-C/releases/download/{version}"
    sums = fetch(f"{url}/SHA256SUMS", workdir / "SHA256SUMS",
                 os.environ["OBJC3_SDK_SUMS_SHA256"])
    checksums = {}
    for line in sums.read_text().splitlines():
        entry = re.fullmatch(r"([0-9a-f]{64})  ([a-zA-Z0-9._-]+)", line)
        if not entry or entry[2] in checksums:
            raise ValueError("Invalid release checksum index")
        checksums[entry[2]] = entry[1]

    def source_archive(name):
        return fetch(f"{url}/{name}", workdir / name, checksums[name])

    project = source_archive(f"slopjective-c-{version}-source.tar.gz")
    with tarfile.open(project) as archive:
        root = archive.next().name
        profile_file = f"{root}/scripts/objc3c_toolchain_runtime/runtime-profile.json"
        with archive.extractfile(profile_file) as stream:
            profile = json.load(stream)["profiles"][target]
        patches = []
        for index, patch in enumerate(profile["source_patches"]):
            with archive.extractfile(f"{root}/{patch['file']}") as stream:
                contents = stream.read()
            if hashlib.sha256(contents).hexdigest() != patch["sha256"]:
                raise ValueError(f"Invalid runtime patch {patch['file']}")
            destination = workdir / f"runtime-{index}.patch"
            destination.write_bytes(contents)
            patches.append(destination)

    def unpack(component, revision):
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise ValueError(f"Invalid {component} revision {revision!r}")
        name = f"{component}-{revision}"
        with tarfile.open(source_archive(f"{name}-source.tar.gz")) as archive:
            archive.extractall(workdir, filter="data")
        return workdir / name

    runtime = unpack("libobjc2", profile["runtime_commit"])
    robin_map = unpack("robin-map", profile["robin_map_commit"])
    for patch in patches:
        subprocess.run(["git", "apply", str(patch)], cwd=runtime, check=True)
    return runtime, robin_map


def build_runtime(workdir, sdk):
    target = f"linux-{platform.machine()}"
    runtime, robin_map = release_sources(workdir, target)
    build, stage = workdir / "build", workdir / "stage"
    configure = [
        "cmake", "-S", str(runtime), "-B", str(build), "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=RelWithDebInfo", f"-DCMAKE_INSTALL_PREFIX={stage}",
        "-DCMAKE_INSTALL_LIBDIR=lib", f"-DFETCHCONTENT_SOURCE_DIR_ROBINMAP={robin_map}",
        "-DFETCHCONTENT_FULLY_DISCONNECTED=ON", "-DTESTS=OFF", "-DOLDABI_COMPAT=OFF",
        "-DLEGACY_COMPAT=OFF", "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld -fsanitize=thread",
    ]
    for language, compiler in (("C", "clang"), ("CXX", "clang++"),
                               ("OBJC", "clang"), ("OBJCXX", "clang++")):
        configure.extend((
            f"-DCMAKE_{language}_COMPILER={sdk / 'bin' / compiler}",
            f"-DCMAKE_{language}_FLAGS=--no-default-config -fsanitize=thread -fno-omit-frame-pointer",
        ))
    subprocess.run(configure, check=True)
    subprocess.run(["cmake", "--build", str(build)], check=True)
    subprocess.run(["cmake", "--install", str(build)], check=True)
    return stage / "lib/libobjc.so"


def run_tests(sdk, runtime, command):
    runtime = runtime.resolve(strict=True)
    symbolizer = (sdk / "bin/llvm-symbolizer").resolve(strict=True)
    symbols = subprocess.check_output(
        [sdk / "bin/llvm-readobj", "--dyn-symbols", runtime], text=True
    )
    if "Name: __tsan_init " not in symbols:
        raise ValueError(f"{runtime} lacks ThreadSanitizer instrumentation")

    # Load this exact library ahead of the installed runtime for the test process only.
    environment = dict(os.environ, LD_PRELOAD=str(runtime),
                       TSAN_OPTIONS=f"halt_on_error=1:external_symbolizer_path={symbolizer}")
    environment.pop("LD_TRACE_LOADED_OBJECTS", None)
    trace = subprocess.check_output(
        command[:1], env=dict(environment, LD_TRACE_LOADED_OBJECTS="1"), text=True
    )
    loaded = {line.strip().split(" (")[0].split(" => ")[-1] for line in trace.splitlines()}
    objc_runtimes = {path for path in loaded if Path(path).name.startswith("libobjc.so")}
    if objc_runtimes != {str(runtime)}:
        raise ValueError(f"The test did not load the instrumented runtime\n{trace}")
    return subprocess.run(command, env=environment).returncode


if __name__ == "__main__":
    try:
        sdk = Path(os.environ["OBJC3C_SDK_ROOT"]).resolve(strict=True)
        if runtime := os.environ.get("XSCOMIC_TEST_THREAD_RUNTIME"):
            sys.exit(run_tests(sdk, Path(runtime), sys.argv[1:]))
        with tempfile.TemporaryDirectory(prefix="xscomic-thread-runtime-") as workdir:
            sys.exit(run_tests(sdk, build_runtime(Path(workdir), sdk), sys.argv[1:]))
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"Cannot run xsComic with an instrumented Objective-C runtime: {error}")
