"""Adversarial transitions beyond the normal successful workflow."""
from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
import wave
from unittest.mock import patch

import test_contracts as fixtures
from companions import Paths
import config
import illustrate_agent
import llm
import joblock
import ocr
import pipeline
import publish
import report
import review
import run
import speakers_fill
from state import StageState, write_json, media_identity, stage_key


class DeepAudit(unittest.TestCase):
    setUp = fixtures.Contracts.setUp
    invoke = fixtures.Contracts.invoke

    def test_force_keeps_existing_redaction(self):
        write_json(self.p.spec, [{"id": 1, "redaction": "on"}])
        write_json(self.p.frames_json, {"complete": True, "frames": [{"ts": "00:00", "kind": "REG"}]})
        with patch.object(llm, "available", return_value=(True, "")), patch.object(illustrate_agent, "video_path", return_value=self.root / "video.mp4"), patch.object(illustrate_agent, "select", return_value={"picks": [{"ts": "00:00", "caption": "Test"}]}), patch.object(illustrate_agent, "extract", return_value={}), patch.object(illustrate_agent, "boxes", side_effect=RuntimeError("stop before rendering")) as boxes:
            with self.assertRaises(RuntimeError):
                self.invoke(illustrate_agent, [str(self.p.base), "--force"])
            self.assertTrue(boxes.call_args.args[-1])

    def test_upload_ignores_unreferenced_old_crops(self):
        self.p.illustrations.mkdir()
        old = self.p.illustrations / "ill_old_unredacted.png"
        current = self.p.illustrations / "ill_current.png"
        old.write_bytes(b"old")
        current.write_bytes(b"current")
        write_json(self.p.manifest, {"illustrations": [{"path": current.name}]})
        self.p.report.write_text(f"![Current](<./{self.p.illustrations.name}/{current.name}>)", encoding="utf-8")
        self.assertNotIn(old.resolve(), [p.resolve() for p in publish.attachments(self.p)])
        self.assertIn(current.resolve(), [p.resolve() for p in publish.attachments(self.p)])

    def test_missing_frame_does_not_silently_reduce_coverage(self):
        one, two = self.root / "one.png", self.root / "two.png"
        one.write_bytes(b"one")
        two.write_bytes(b"two")
        frames = [{"ts": "00:00", "kind": "REG", "path": str(one)}, {"ts": "01:00", "kind": "CUT", "path": str(two)}]
        reply = llm.Reply('{"frames":[{"ts":"00:00"}]}', "mock")
        two.unlink()
        with patch.object(llm, "load_config", return_value=llm.Config("azure", models={"vision": "mock"})), patch.object(llm, "ask", return_value=reply):
            with self.assertRaises(RuntimeError):
                report.frame_pass(self.p, {"frames": frames}, 48, None, False)

    def test_stage_state_with_wrong_json_shape_is_not_current(self):
        state = StageState(self.p.base)
        for value in ({"stages": []}, {"stages": {"report": None}}, {"stages": {"report": "complete"}}):
            write_json(state.path, value)
            self.assertFalse(state.current("report", "key"))

    def test_plan_rejects_invalid_numeric_options(self):
        media = self.root / "video.mp4"
        media.write_bytes(b"fixture")
        for flags in (["--fps", "nan"], ["--ocr-min-score", "1.5"], ["--scene-max-frames", "-2"], ["--cpu-budget", "garbage"]):
            with self.subTest(flags=flags):
                with self.assertRaises(SystemExit) as err:
                    self.invoke(pipeline, [str(media), "--plan", *flags])
                self.assertEqual(err.exception.code, 2)

    def test_relative_source_can_resume_from_another_directory(self):
        media = self.root / "relative.wav"
        with wave.open(str(media), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
            w.writeframes(b"\0\0" * 1600)
        cmd = [sys.executable, "-X", "utf8", "-B", str(fixtures.ROOT / "transcribe.py"), "run"]
        first = subprocess.run([*cmd, media.name, "--analysis", "none", "--no-whisper", "--no-diarize", "--no-ocr", "--json"], cwd=self.root, capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(first.returncode, 0, first.stderr)
        result = json.loads(first.stdout)
        second = subprocess.run([*cmd, result["transcript"], "--analysis", "none", "--json"], cwd=self.root.parent, capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertNotIn("-- run.py", second.stderr)

    def test_url_companion_resumes_original_url_not_temporary_download(self):
        url = "https://example.invalid/recording"
        options = vars(run.build_parser().parse_args([url]))
        options = {k: v for k, v in options.items() if k not in ("result_json", "fresh", "background")}
        self.p.protocol.write_text("# Protocol\n", encoding="utf-8")
        write_json(self.p.base.with_suffix(".run.json"), {"source": url, "source_identity": {"path": str(self.root / "old-download.mp4")},
                   "options": options, "local_config": pipeline.local_config(), "glossary": pipeline.glossary_hash(None)})
        with patch.object(pipeline, "emit_result") as emit:
            self.assertEqual(self.invoke(pipeline, [str(self.p.transcript), "--analysis", "none", "--plan"]), 0)
        self.assertEqual(emit.call_args.args[0]["source"], url)
        self.assertEqual(emit.call_args.args[0]["stages"][0]["status"], "current")

    @contextlib.contextmanager
    def media_fixture(self):
        media = self.root / "recording.wav"
        media.write_bytes(b"synthetic audio, media access is mocked")
        with patch.object(run, "download", return_value={"video_path": media}), patch.object(run, "get_metadata", return_value={"duration_seconds": 10, "has_video": False}), patch.object(run, "extract_audio", return_value=media), patch.object(run, "select_backend", return_value=None), patch.object(run, "select_backends", side_effect=AssertionError("unexpected STT fallback")), patch.object(run, "pick_diarize_backend", return_value="assemblyai"):
            yield [str(media), "--out-dir", str(self.root / "work"), "--no-repair", "--no-ocr", "--diarize", "assemblyai", "--language", "de"]

    def test_assemblyai_cache_precedes_cloud_and_survives_empty_range(self):
        segments = [{"start": 0, "end": 1, "text": "Cached statement", "speaker": "SPEAKER_00"}]
        with self.media_fixture() as args, patch.object(run, "diarize_assemblyai", return_value=segments) as cloud:
            self.assertEqual(self.invoke(run, args), 0)
            self.assertEqual(cloud.call_args.kwargs["language"], "de")
            self.assertEqual(self.invoke(run, args), 0)
            self.assertEqual(self.invoke(run, [*args, "--start", "5", "--end", "6"]), 0)
            self.assertEqual(cloud.call_count, 1)
            self.assertIn("No transcript lines fell inside", self.p.transcript.read_text(encoding="utf-8"))

    def test_explicit_assemblyai_failure_does_not_fall_back(self):
        with self.media_fixture() as args, patch.object(run, "diarize_assemblyai", side_effect=SystemExit("synthetic refusal")):
            with self.assertRaisesRegex(RuntimeError, "Requested AssemblyAI backend failed"):
                self.invoke(run, args)

    def test_stt_cache_rejects_changed_provider_settings_and_wrong_shape(self):
        segments = [{"start": 0, "end": 1, "text": "Statement"}]
        with self.media_fixture() as args, patch.object(run, "diarize_assemblyai", return_value=segments) as cloud:
            self.assertEqual(self.invoke(run, args), 0)
            with patch.dict(os.environ, {"ASSEMBLYAI_REGION": "eu"}):
                self.assertEqual(self.invoke(run, args), 0)
                write_json(self.p.base.with_suffix(".segments.json"), {"segments": {"malformed": True}})
                self.assertEqual(self.invoke(run, args), 0)
            self.assertEqual(cloud.call_count, 3)

    def test_disabled_ocr_clears_old_evidence(self):
        write_json(self.p.ocr, {"frames": [{"text": "old source"}]})
        self.p.links.write_text("old source URL", encoding="utf-8")
        with self.media_fixture() as args, patch.object(run, "diarize_assemblyai", return_value=[]):
            self.assertEqual(self.invoke(run, [*args, "--no-whisper"]), 0)
        self.assertEqual(json.loads(self.p.ocr.read_text())["frames"], [])
        self.assertNotIn("old source", self.p.links.read_text())

    def test_ocr_cache_tracks_scope_budget_settings_and_image_content(self):
        media, image = self.root / "source.mp4", self.root / "one.png"
        media.write_bytes(b"video")
        image.write_bytes(b"frame")
        frames = [{"timestamp_seconds": 0, "path": str(image)}]
        key = ocr.cache_key(media, frames, 60, 0.5)
        self.assertEqual(key, ocr.cache_key(media, frames, 60, 0.5))
        for changed_frames, limit, settle in (([], 60, 0.5), (frames, 1, 0.5), (frames, 60, 1)):
            self.assertNotEqual(key, ocr.cache_key(media, changed_frames, limit, settle))
        with patch.dict(os.environ, {"TRANSCRIBE_OCR_ACCEL": "cpu"}):
            self.assertNotEqual(key, ocr.cache_key(media, frames, 60, 0.5))
        image.write_bytes(b"new frame")
        self.assertNotEqual(key, ocr.cache_key(media, frames, 60, 0.5))

    def test_waiting_pipeline_rechecks_completed_media(self):
        media = self.root / "recording.wav"
        media.write_bytes(b"source")
        flags = [str(media), "--analysis", "none", "--no-whisper", "--no-diarize", "--no-ocr"]
        options = vars(run.build_parser().parse_args([str(media), *flags[3:]]))
        options = {k: v for k, v in options.items() if k not in ("result_json", "fresh", "background")}

        @contextlib.contextmanager
        def completed_while_waiting(base, background=False):
            if not os.environ.get("TRANSCRIBE_WORKFLOW_LOCK"):
                self.p.protocol.write_text("# Protocol\n", encoding="utf-8")
                write_json(self.p.base.with_suffix(".run.json"), {"source": str(media), "source_identity": media_identity(media),
                           "options": options, "local_config": pipeline.local_config(), "glossary": pipeline.glossary_hash(media)})
            with patch.dict(os.environ, {"TRANSCRIBE_WORKFLOW_LOCK": str(base.resolve())}):
                yield True

        with patch.object(joblock, "workflow_lock", completed_while_waiting), patch.object(pipeline, "call", side_effect=AssertionError("stale decision repeated media")):
            self.assertEqual(self.invoke(pipeline, flags), 0)

    def test_background_entrypoints_share_workflow_lock(self):
        media = self.root / "recording.wav"
        media.write_bytes(b"source")
        lock = joblock.JobLock(self.p.base.with_name(self.p.base.name + ".workflow.lock"))
        with lock:
            for script, flags in ((fixtures.ROOT / "transcribe.py", ["run", "--analysis", "none", "--json"]), (fixtures.ROOT / "scripts/run.py", [])):
                result = subprocess.run([sys.executable, "-X", "utf8", "-B", str(script), *flags, str(media), "--background"], capture_output=True, text=True, encoding="utf-8", timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                if flags:
                    self.assertEqual(json.loads(result.stdout)["status"], "busy")
        self.assertFalse(self.p.protocol.exists())

    def test_review_hashes_referenced_images_without_generated_spec(self):
        image = self.root / "manual.png"
        image.write_bytes(b"before")
        self.p.report.write_text("![Manual](manual.png)", encoding="utf-8")
        before = {key: digest for key, _, digest, _ in review.items(self.p, None)}
        image.write_bytes(b"after")
        after = {key: digest for key, _, digest, _ in review.items(self.p, None)}
        self.assertNotEqual(before["illustrations"], after["illustrations"])

    def test_report_cache_tracks_original_frame_bytes(self):
        image = self.root / "frame.png"
        image.write_bytes(b"before")
        self.p.protocol.write_text(f"- `{image}` (t=00:00)[REG]\n", encoding="utf-8")
        before = stage_key(self.p, "report")
        image.write_bytes(b"after")
        self.assertNotEqual(before, stage_key(self.p, "report"))

    def test_audio_overlap_must_match_chunk_plan(self):
        with patch.dict(os.environ, {"AZURE_TRANSCRIBE_CHUNK_SECONDS": "100", "AZURE_TRANSCRIBE_OVERLAP_SECONDS": "75"}):
            with self.assertRaisesRegex(ValueError, "must not exceed half"):
                config.snapshot()

    def test_stage_state_requires_all_recorded_outputs(self):
        state = StageState(self.p.base)
        state.record("report", "key", [self.p.transcript, self.p.protocol])
        self.assertFalse(state.current("report", "key", [self.p.transcript]))

    def test_incomplete_redaction_reply_preserves_previous_spec(self):
        spec = [{"id": 1, "timestamp": 0, "redaction": "off", "bbox": [0, 0, 1, 1]}]
        write_json(self.p.spec, spec)
        before = self.p.spec.read_bytes()
        with patch.object(illustrate_agent, "extract", return_value={0: self.root / "frame.png"}), patch.object(llm, "ask_json", return_value={"frames": []}):
            with self.assertRaisesRegex(RuntimeError, "Incomplete redaction reply"):
                illustrate_agent.set_redaction(spec, self.root / "video.mp4", self.p, True)
        self.assertEqual(self.p.spec.read_bytes(), before)

    def test_named_speakers_recheck_new_evidence_and_language(self):
        self.p.speakers.write_text("## Labels\n\n| Label | Talk time | Turns | Active | Name | Confidence | Evidence |\n|---|---|---|---|---|---|---|\n| SPEAKER_00 | 1s | 1 | 00:00 | Alice | high | Human |\n\n## Open attributions\n", encoding="utf-8")
        with patch.object(llm, "available", return_value=(True, "")), patch.object(llm, "ask_json", return_value={"labels": {}, "open": []}) as ask, patch.object(speakers_fill, "finish"):
            args = [str(self.p.base)]
            self.assertEqual(self.invoke(speakers_fill, args), 0)
            self.assertEqual(self.invoke(speakers_fill, args), 0)
            self.assertEqual(ask.call_count, 1)
            self.assertEqual(self.invoke(speakers_fill, [*args, "--language", "en"]), 0)
            self.p.transcript.write_text("[00:00] [SPEAKER_00] New evidence\n", encoding="utf-8")
            self.assertEqual(self.invoke(speakers_fill, [*args, "--language", "en"]), 0)
            self.assertEqual(ask.call_count, 3)
            self.assertIn("Alice", self.p.speakers.read_text(encoding="utf-8"))

    def test_speaker_dry_run_does_not_apply_or_record(self):
        before = self.p.speakers.read_bytes()
        for available in (True, False):
            with patch.object(llm, "available", return_value=(available, "synthetic")), patch.object(llm, "ask_json", return_value={}), patch.object(speakers_fill, "finish", side_effect=AssertionError("dry run mutated files")):
                self.assertEqual(self.invoke(speakers_fill, [str(self.p.base), "--dry-run", "--apply"]), 0 if available else 3)
        self.assertEqual(before, self.p.speakers.read_bytes())
        self.assertFalse(StageState(self.p.base).path.exists())

    def test_video_run_signs_ocr_with_string_media_path(self):
        """A real video through frames and the OCR signature. download() hands the
        media path over as a plain string; the OCR cache key must accept it."""
        ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
        if not ffmpeg or not ffprobe:
            self.skipTest("ffmpeg not installed")
        media = self.root / "clip.mp4"
        subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "testsrc=size=320x240:rate=5:duration=3",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                        "-c:v", "mpeg4", "-c:a", "aac", "-pix_fmt", "yuv420p", "-shortest", str(media)],
                       check=True, capture_output=True, timeout=120)
        write_json(media.with_suffix(".segments.json"), {"backend": "fixture", "segments": [
            {"start": 0, "end": 1, "text": "Synthetic sentence."}]})
        p = Paths(self.root / "clip")
        args = [str(media), "--out-dir", str(self.root / "work"), "--no-diarize", "--no-repair", "--no-scene",
                "--max-frames", "4", "--language", "de"]
        with patch.object(run.ocr_stage, "run", return_value={"frames": []}) as ocr_run:
            self.assertEqual(self.invoke(run, args), 0)
            self.assertEqual(self.invoke(run, args), 0)
        self.assertEqual(ocr_run.call_count, 1, "second run must resume OCR from its cache")
        self.assertIsInstance(ocr_run.call_args.args[0], str)
        self.assertTrue(json.loads(p.ocr.read_text(encoding="utf-8"))["input"])
        protocol = p.protocol.read_text(encoding="utf-8")
        self.assertIn("- **Frames:**", protocol)
        self.assertNotIn("- **Frames:** none", protocol)
        self.assertIn("Synthetic sentence.", p.transcript.read_text(encoding="utf-8"))

    def test_run_without_source_is_a_usage_error(self):
        import command
        self.assertEqual(self.invoke(command, ["run"]), 2)


if __name__ == "__main__":
    unittest.main()
