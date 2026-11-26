#!/usr/bin/env python3
"""Public synthetic fixtures. No recording, credentials or platform paths.

Uses our documented ZIP32 STORE dialect (not zipfile's platform defaults).
Expected attribution rows below are deliberately hand specified.
"""

import hashlib
import json
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "test/fixtures/m2"


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def sha(value):
    return hashlib.sha256(value).hexdigest()


def zip_store(files):
    output, central = bytearray(), bytearray()
    for name, data in sorted(files.items()):
        path, size, crc, offset = name.encode(), len(data), zlib.crc32(data), len(output)
        output += (
            struct.pack(
                "<I5H3I2H", 0x04034B50, 20, 0x800, 0, 0, 0x21, crc, size, size, len(path), 0
            )
            + path
            + data
        )
        central += (
            struct.pack(
                "<I6H3I5H2I",
                0x02014B50,
                20,
                20,
                0x800,
                0,
                0,
                0x21,
                crc,
                size,
                size,
                len(path),
                0,
                0,
                0,
                0,
                0,
                offset,
            )
            + path
        )
    offset = len(output)
    output += central
    output += struct.pack(
        "<I4H2IH", 0x06054B50, 0, 0, len(files), len(files), len(central), offset, 0
    )
    return output


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    rows = [
        ("seg_1", 0, 12000, "第一段。"),
        ("seg_2", 12000, 20000, "两人轮流。"),
        ("seg_3", 20000, 28000, "两人同时。"),
        ("seg_4", 30000, 46000, "部分归属。"),
        ("seg_5", 48000, 64000, "归属未知。"),
    ]
    sources = [dict(segmentId=i, startSample=a, endSample=b, text=t) for i, a, b, t in rows]
    fp = "sha256:" + sha(encode(sources))
    segments = [
        dict(
            segmentId=i,
            startSample=a,
            endSample=b,
            liveText=t,
            refinedText=None,
            text=t,
            textLayer="live",
        )
        for i, a, b, t in rows
    ]
    full_text = "\n\n".join(t for _, _, _, t in rows)
    canonical = dict(
        schemaVersion=1,
        format="org.hohu.momentai.canonical-text",
        status="live",
        defaultTextLayer="live",
        modelId="",
        composerVersion=0,
        sourceTimelineFingerprint=fp,
        sourceAudioSamples=64000,
        sampleRate=16000,
        createdAt="",
        fullText=full_text,
        segmentCount=5,
        refinedSegmentCount=0,
        fallbackSegmentCount=0,
        segments=segments,
    )
    empty = dict(names={}, mergedInto={})
    named = dict(names={"speaker_1": "林[主持]"}, mergedInto={})
    current = dict(names={"speaker_1": "林[主持]"}, mergedInto={"speaker_3": "speaker_1"})
    raw = [
        ("speaker_1", 0, 16000),
        ("speaker_2", 16000, 24000),
        ("speaker_4", 20000, 28000),
        ("speaker_3", 32000, 40000),
    ]
    document = dict(
        schemaVersion=1,
        algorithmVersion=3,
        status="ready",
        sessionId="session_public_m2",
        modelId="synthetic-public-fixture",
        sourceAudioSamples=64000,
        sampleRate=16000,
        sourceChunkFingerprint="sha256:" + "a" * 64,
        createdAt="2026-09-10T00:00:00Z",
        processingMs=1,
        realTimeFactor=0.001,
        peakRssBytes=1,
        windowCount=1,
        requestedSpeakerCount=None,
        speakerCount=3,
        segments=[dict(speakerId=i, startSample=a, endSample=b) for i, a, b in raw],
        labelEdits=dict(schemaVersion=1, revision=2, current=current, history=[empty, named]),
    )
    speaker_version = "sha256:" + sha(
        encode(
            [
                1,
                document["modelId"],
                3,
                document["createdAt"],
                2,
                raw,
                [["speaker_1", "林[主持]"]],
                [["speaker_3", "speaker_1"]],
            ]
        )
    )
    text_version = "sha256:" + sha(
        encode(
            [1, "live", "live", "", fp, full_text, [[i, a, b, t, "live"] for i, a, b, t in rows]]
        )
    )
    notice = (
        "说话人按整段音频估计，不是逐字对齐；多人、重叠或归属不确定的段落不能确定每句话由谁说。"
    )
    attribution = [
        (["speaker_1"], ["林[主持]"], "single", 12000, "林[主持]"),
        (
            ["speaker_1", "speaker_2"],
            ["林[主持]", "说话人 2"],
            "multiple",
            8000,
            "多人轮流：林[主持]、说话人 2",
        ),
        (
            ["speaker_4", "speaker_2"],
            ["说话人 4", "说话人 2"],
            "overlap",
            8000,
            "多人 · 有重叠：说话人 4、说话人 2",
        ),
        (["speaker_1"], ["林[主持]"], "uncertain", 8000, "归属不确定：林[主持]"),
        ([], [], "unattributed", 0, "说话人未确定"),
    ]
    projected = [
        dict(
            segmentId=i,
            startSample=a,
            endSample=b,
            text=t,
            textLayer="live",
            speakerIds=ids,
            displayNames=names,
            attribution=state,
            coveredSamples=coverage,
            label=label,
        )
        for (i, a, b, t), (ids, names, state, coverage, label) in zip(rows, attribution)
    ]
    expected = dict(
        schemaVersion=1,
        format="org.hohu.momentai.speaker-text",
        speakerVersion=speaker_version,
        textVersion=text_version,
        sourceTimelineFingerprint=fp,
        notice=notice,
        fullText=full_text,
        segments=projected,
    )
    fixture = dict(document=document, canonical=canonical, expected=expected)
    (ROOT / "speaker-text-v1.json").write_text(
        json.dumps(fixture, ensure_ascii=False, indent=2) + "\n"
    )
    pcm = bytes(128000)
    wav = (
        struct.pack(
            "<4sI4s4sIHHIIHH4sI",
            b"RIFF",
            len(pcm) + 36,
            b"WAVE",
            b"fmt ",
            16,
            1,
            1,
            16000,
            32000,
            2,
            16,
            b"data",
            len(pcm),
        )
        + pcm
    )
    timeline = [
        dict(
            kind="transcript",
            segmentId=i,
            sessionId=document["sessionId"],
            sampleOffset=a,
            startSample=a,
            endSample=b,
            startMs=a * 1000 // 16000,
            endMs=b * 1000 // 16000,
            isFinal=True,
            text=t,
            liveText=t,
            displayText=t,
            textLayer="live",
        )
        for i, a, b, t in rows
    ]
    session = dict(
        sessionId=document["sessionId"],
        title="公开合成契约样例",
        state="completed",
        startedAtWall="2026-09-10T00:00:00Z",
        stoppedAtWall="2026-09-10T00:00:04Z",
        lastCommittedSample=64000,
        sampleRate=16000,
        chunkCount=1,
        recoveryCount=0,
    )
    export = dict(
        schemaVersion=1,
        format="org.hohu.momentai.session-export",
        session=session,
        audio=dict(
            path="audio/session.wav",
            codec="pcm_s16le",
            sampleRate=16000,
            channels=1,
            bitsPerSample=16,
            sampleCount=64000,
            durationMs=4000,
            byteCount=len(wav),
            sha256=sha(wav),
        ),
        images=[],
        timeline=timeline,
    )
    base = {
        "audio/session.wav": wav,
        "session.md": full_text.encode(),
        "timeline.jsonl": b"\n".join(
            encode(dict(schemaVersion=1, sessionId=document["sessionId"], index=i, item=t))
            for i, t in enumerate(timeline)
        )
        + b"\n",
    }

    def archive(doc, extra=None):
        files = dict(base, **{"session.json": encode(doc)}, **(extra or {}))
        files["manifest.json"] = encode(
            dict(
                schemaVersion=1,
                format="org.hohu.momentai.archive",
                archiveFormat="zip-store",
                sessionId=document["sessionId"],
                files=[
                    dict(path=p, byteCount=len(d), sha256=sha(d)) for p, d in sorted(files.items())
                ],
            )
        )
        return zip_store(files)

    (ROOT / "legacy-v1.momentai").write_bytes(archive(export))
    export.update(
        canonicalText=canonical,
        capabilities=["canonicalTextV1", "timelineTextLayersV1", "speakerDiarizationV1"],
        extensions={
            "speakerDiarizationV1": dict(
                schemaVersion=1,
                sourceAudioSha256=sha(wav),
                document=document,
                textProjection=expected,
            )
        },
    )
    valid = archive(export)
    (ROOT / "speaker-v1.momentai").write_bytes(valid)
    compressed = bytearray(valid)
    compressed[8] = 8
    (ROOT / "invalid-compression.momentai").write_bytes(compressed)
    (ROOT / "invalid-extra-entry.momentai").write_bytes(archive(export, {"unexpected.json": b"{}"}))
    corrupt = json.loads(json.dumps(export))
    corrupt["extensions"]["speakerDiarizationV1"]["document"]["segments"][0]["endSample"] = 999999
    (ROOT / "invalid-speaker-extension.momentai").write_bytes(archive(corrupt))


if __name__ == "__main__":
    main()
