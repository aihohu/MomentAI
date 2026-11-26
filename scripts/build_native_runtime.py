"""Build the pinned Android/iOS speech runtime without TTS or global cache edits."""

import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".tools/native"
LOCK = ROOT / "native/runtime-lock.json"
FORBIDDEN = re.compile(r"(?<![a-z])(?:lib)?espeak(?:[-_./]|$)|piper[-_]phonemize", re.IGNORECASE)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def run(command, **kwargs):
    print("+ " + " ".join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def acquire(record, offline=False):
    destination = WORK / "downloads" / record["file"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and digest(destination) == record["sha256"]:
        return destination
    if offline:
        raise ValueError(f"Missing verified input: {record['file']}")
    partial = destination.with_suffix(destination.suffix + ".part")
    urls = list(record["urls"])
    if "releaseAssetId" in record:
        urls.insert(
            0,
            "https://api.github.com/repos/csukuangfj/onnxruntime-libs/"
            f"releases/assets/{record['releaseAssetId']}",
        )
    try:
        for url in urls:
            headers = (
                ["--header", "Accept: application/octet-stream"]
                if url.startswith("https://api.github.com/")
                else []
            )
            try:
                run(
                    [
                        "curl",
                        "--fail",
                        "--location",
                        "--proto",
                        "=https",
                        "--proto-redir",
                        "=https",
                        *headers,
                        *(["--continue-at", "-"] if "releaseAssetId" in record else []),
                        "--silent",
                        "--show-error",
                        "--retry",
                        "2",
                        "--connect-timeout",
                        "15",
                        "--max-time",
                        "1800",
                        "--speed-limit",
                        "1024",
                        "--speed-time",
                        "60",
                        url,
                        "--output",
                        partial,
                    ]
                )
                if digest(partial) != record["sha256"]:
                    partial.unlink(missing_ok=True)
                    raise ValueError(f"Checksum mismatch: {record['file']}")
                partial.replace(destination)
                return destination
            except subprocess.CalledProcessError as failure:
                if failure.returncode == 33:
                    partial.unlink(missing_ok=True)
                continue
        raise ValueError(f"Could not acquire {record['file']}")
    finally:
        # Large release assets can resume after a network failure. They are never
        # extracted until the complete archive matches the pinned hash.
        if "releaseAssetId" not in record:
            partial.unlink(missing_ok=True)


def extract(archive, record):
    """Extract only regular content, rejecting escaping paths and archive links."""
    destination = WORK / "sources" / record["directory"]
    marker = destination / ".momentai-archive-sha256"
    if marker.exists() and marker.read_text().strip() == record["sha256"]:
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        staging = Path(temporary)
        if zipfile.is_zipfile(archive):
            with zipfile.ZipFile(archive) as bundle:
                for item in bundle.infolist():
                    target = (staging / item.filename).resolve()
                    if not target.is_relative_to(staging.resolve()):
                        raise ValueError("Archive path escapes staging directory")
                    if (item.external_attr >> 16) & 0o170000 == 0o120000:
                        raise ValueError("ZIP symlinks are not accepted")
                bundle.extractall(staging)
        else:
            with tarfile.open(archive) as bundle:
                # Upstream has unrelated Go example symlinks. Mobile sources do not use them.
                bundle.extractall(
                    staging, members=(m for m in bundle if m.isfile() or m.isdir()), filter="data"
                )
        children = list(staging.iterdir())
        content = (
            children[0]
            if len(children) == 1
            and children[0].is_dir()
            and not children[0].name.endswith(".xcframework")
            else staging
        )
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(content, destination)
    marker.write_text(record["sha256"] + "\n")
    return destination


def cmake_executable(sdk):
    configured = os.environ.get("MOMENTAI_CMAKE") or shutil.which("cmake")
    if configured:
        return Path(configured)
    candidate = sdk / "cmake/3.22.1/bin/cmake"
    if candidate.is_file():
        return candidate
    raise ValueError("Install CMake 3.22.1+ or set MOMENTAI_CMAKE")


def verify_build(build):
    cache = (build / "CMakeCache.txt").read_text()
    if not re.search(r"^SHERPA_ONNX_ENABLE_TTS:BOOL=OFF$", cache, re.MULTILINE):
        raise ValueError("TTS was not disabled")
    commands = json.loads((build / "compile_commands.json").read_text())
    for entry in commands:
        if FORBIDDEN.search(entry["file"]):
            raise ValueError(f"Forbidden TTS compilation unit: {entry['file']}")
    link_files = sorted(build.glob("**/link.txt"))
    for path in link_files:
        if FORBIDDEN.search(path.read_text()):
            raise ValueError(f"Forbidden TTS link input: {path}")
    if not link_files:
        raise ValueError("No native link records were generated")
    link_map = build / "runtime.map"
    if not link_map.is_file() or FORBIDDEN.search(link_map.read_text()):
        raise ValueError("Missing or forbidden native link map")
    return {
        "linkMapSha256": digest(link_map),
        "compilationUnits": len(commands),
        "linkRecords": len(link_files),
        "compileCommandsSha256": digest(build / "compile_commands.json"),
    }


def verify_binary(path):
    strings = subprocess.check_output(["strings", str(path)], text=True)
    if any(term in strings.lower() for term in ("espeak-ng-data", "piper-phonemize-lexicon")):
        raise ValueError(f"Forbidden runtime marker: {path}")
    return {"bytes": path.stat().st_size, "sha256": digest(path)}


def framework(binary, directory, source, simulator, minimum):
    destination = directory / "SherpaOnnxC.framework"
    if destination.exists():
        shutil.rmtree(destination)
    headers = destination / "Headers/sherpa-onnx/c-api"
    headers.mkdir(parents=True)
    shutil.copy2(source / "sherpa-onnx/c-api/c-api.h", headers)
    target = destination / "SherpaOnnxC"
    shutil.copy2(binary, target)
    run(["install_name_tool", "-id", "@rpath/SherpaOnnxC.framework/SherpaOnnxC", target])
    (destination / "Modules").mkdir()
    (destination / "Modules/module.modulemap").write_text(
        'framework module SherpaOnnxC {\n  header "sherpa-onnx/c-api/c-api.h"\n  export *\n}\n'
    )
    metadata = {
        "CFBundleIdentifier": "org.hohu.momentai.speech",
        "CFBundleName": "SherpaOnnxC",
        "CFBundlePackageType": "FMWK",
        "CFBundleExecutable": "SherpaOnnxC",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.13.5",
        "MinimumOSVersion": minimum,
        "CFBundleSupportedPlatforms": ["iPhoneSimulator" if simulator else "iPhoneOS"],
    }
    (destination / "Info.plist").write_bytes(plistlib.dumps(metadata))
    return destination


def build_runtime(args):
    lock = json.loads(LOCK.read_text())
    sources = {item["name"]: extract(acquire(item, args.offline), item) for item in lock["sources"]}
    # Top-level recipes override older recipes inside transitive dependencies.
    for item in lock["sources"]:
        recipe = sources["sherpa-onnx"] / "cmake" / (item["name"] + ".cmake")
        if recipe.is_file() and item["sha256"] not in recipe.read_text():
            raise ValueError(f"Pinned source disagrees with upstream recipe: {item['name']}")
    runtime = lock["onnxruntime"][args.platform]
    ort = extract(acquire(runtime, args.offline), runtime)
    if args.prepare_only:
        return
    sdk = Path(os.environ.get("ANDROID_SDK_ROOT", os.environ.get("ANDROID_HOME", "")))
    cmake = cmake_executable(sdk)
    source = sources["sherpa-onnx"]
    common = [f"-D{key}={value}" for key, value in lock["cmake"].items()]
    common += [
        f"-DFETCHCONTENT_SOURCE_DIR_{item['fetchContent'].upper()}={sources[item['name']]}"
        for item in lock["sources"]
        if "fetchContent" in item
    ]
    common += ["-DCMAKE_CXX_FLAGS=-DEIGEN_MPL2_ONLY", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"]
    variants = (
        {"android-arm64": None} if args.platform == "android" else lock["ios"]["architectures"]
    )
    evidence = {
        "schemaVersion": 1,
        "lockSha256": digest(LOCK),
        "platform": args.platform,
        "sherpaCommit": lock["sources"][0]["commit"],
        "tts": False,
        "cmakeVersion": subprocess.check_output([str(cmake), "--version"], text=True).splitlines()[
            0
        ],
        "variants": {},
    }
    built = {}
    for name, target in variants.items():
        build = WORK / "build" / name
        env = os.environ.copy()
        options = list(common)
        if args.platform == "android":
            ndk = Path(
                os.environ.get("ANDROID_NDK_HOME", str(sdk / "ndk" / lock["android"]["ndk"]))
            )
            if (
                not (ndk / "source.properties").is_file()
                or lock["android"]["ndk"] not in (ndk / "source.properties").read_text()
            ):
                raise ValueError("The pinned Android NDK is required")
            env["SHERPA_ONNXRUNTIME_LIB_DIR"] = str(ort / "jni/arm64-v8a")
            env["SHERPA_ONNXRUNTIME_INCLUDE_DIR"] = str(ort / "headers")
            options += [
                f"-DCMAKE_TOOLCHAIN_FILE={ndk}/build/cmake/android.toolchain.cmake",
                "-DANDROID_ABI=arm64-v8a",
                "-DANDROID_PLATFORM=android-24",
                f"-DCMAKE_SHARED_LINKER_FLAGS_RELEASE=-Wl,-Map,{build}/runtime.map",
            ]
        else:
            if platform.system() != "Darwin":
                raise ValueError("iOS runtime builds require macOS and Xcode")
            slice_name = "ios-arm64" if target == "OS64" else "ios-arm64_x86_64-simulator"
            ort_slice = ort / "onnxruntime.xcframework" / slice_name
            env["SHERPA_ONNXRUNTIME_LIB_DIR"] = str(ort_slice)
            env["SHERPA_ONNXRUNTIME_INCLUDE_DIR"] = str(ort_slice / "onnxruntime.framework/Headers")
            options += [
                f"-DCMAKE_TOOLCHAIN_FILE={source}/toolchains/ios.toolchain.cmake",
                f"-DPLATFORM={target}",
                "-DENABLE_BITCODE=0",
                "-DENABLE_ARC=1",
                "-DENABLE_VISIBILITY=1",
                f"-DDEPLOYMENT_TARGET={lock['ios']['minimum']}",
                f"-DCMAKE_SHARED_LINKER_FLAGS_RELEASE=-Wl,-map,{build}/runtime.map",
            ]
        run([cmake, "-S", source, "-B", build, "-G", "Unix Makefiles", *options], env=env)
        run(
            [cmake, "--build", build, "--parallel", args.jobs, "--target", "sherpa-onnx-c-api"],
            env=env,
        )
        binary = (
            build
            / "lib"
            / (
                "libsherpa-onnx-c-api.so"
                if args.platform == "android"
                else "libsherpa-onnx-c-api.dylib"
            )
        )
        evidence["variants"][name] = {**verify_build(build), **verify_binary(binary)}
        built[name] = binary
    outputs = {}
    if args.platform == "android":
        destination = ROOT / "packages/sherpa_onnx_android_arm64/android/src/main/jniLibs/arm64-v8a"
        destination.mkdir(parents=True, exist_ok=True)
        for path in [built["android-arm64"], ort / "jni/arm64-v8a/libonnxruntime.so"]:
            target = destination / path.name
            shutil.copy2(path, target)
            outputs[target.relative_to(ROOT).as_posix()] = verify_binary(target)
    else:
        staging = WORK / "frameworks"
        staging.mkdir(exist_ok=True)
        simulator = staging / "simulator.dylib"
        run(
            [
                "lipo",
                "-create",
                built["ios-arm64-simulator"],
                built["ios-x86_64-simulator"],
                "-output",
                simulator,
            ]
        )
        device = framework(
            built["ios-arm64"], staging / "device", source, False, lock["ios"]["minimum"]
        )
        sim = framework(simulator, staging / "simulator", source, True, lock["ios"]["minimum"])
        destination = ROOT / "packages/sherpa_onnx_ios/ios/sherpa_onnx_ios/SherpaOnnxC.xcframework"
        if destination.exists():
            shutil.rmtree(destination)
        run(
            [
                "xcodebuild",
                "-create-xcframework",
                "-framework",
                device,
                "-framework",
                sim,
                "-output",
                destination,
            ]
        )
        for path in destination.glob("*/SherpaOnnxC.framework/SherpaOnnxC"):
            outputs[path.relative_to(ROOT).as_posix()] = verify_binary(path)
    evidence["outputs"] = outputs
    destination = ROOT / ".local/validation/native" / f"{args.platform}-build.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Verified no-TTS runtime: {destination.relative_to(ROOT)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["android", "ios"], required=True)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    build_runtime(args)


if __name__ == "__main__":
    main()
