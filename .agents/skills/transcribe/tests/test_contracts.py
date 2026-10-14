"""Offline regression tests for the public contracts. No keys or media leave the machine."""
from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import wave
import shutil
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import agent
import command
import config
import diarize
import illustrate_agent
import joblock
import kompakt
import llm
import pipeline
import report
import review
import publish
import setup
import speakers
import stt
from companions import Paths, Block, fmt_ts, resolve_base
from state import StageState, write_json, stage_key
HOST_PATH = os.environ.get("PATH", "")
OS_ENV = {name: os.environ[name] for name in ("PATH", "SystemRoot", "WINDIR", "ComSpec", "TEMP", "TMP", "SystemDrive") if name in os.environ}


class Contracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="audit-transcribe-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = patch.dict(os.environ, {**OS_ENV, "TRANSCRIBE_CONFIG_DIR": str(self.root / "config"),
                                           "TRANSCRIBE_BIN_DIR": str(self.root / "bin"),
                                           "TRANSCRIBE_LLM_PROVIDER": "none"}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        for key, value in {"CONFIG_DIR": config.user_dir(), "CONFIG_FILE": config.user_dir() / ".env",
                           "VENV_DIR": config.user_dir() / "venv", "VENV_MARKER": config.user_dir() / "venv/.provisioned.json",
                           "TRANSCRIBE_BIN_DIR": config.bin_dir()}.items():
            p = patch.object(setup, key, value)
            p.start()
            self.addCleanup(p.stop)
        self.p = Paths(self.root / "recording")
        self.p.transcript.write_text("[00:00] [SPEAKER_00] First\n[01:00] [SPEAKER_01] Final decision\n", encoding="utf-8")
        self.p.speakers.write_text("| Label | Name |\n|---|---|\n| SPEAKER_00 | |\n", encoding="utf-8")

    def invoke(self, module, args):
        with patch.object(sys, "argv", [module.__name__, *args]), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return module.main()

    def test_config_precedence_and_reader_parity(self):
        config.user_dir().mkdir()
        (config.user_dir() / ".env").write_text("GROQ_API_KEY=user-test\n", encoding="utf-8")
        explicit = self.root / "explicit.env"
        explicit.write_text("GROQ_API_KEY=\n", encoding="utf-8")
        os.environ["TRANSCRIBE_CONFIG"] = str(explicit)
        for reader in (setup._read_env_key, stt._get_config, diarize._load_env_value):
            self.assertEqual(reader("GROQ_API_KEY"), "user-test")
        os.environ["GROQ_API_KEY"] = "environment-test"
        self.assertEqual(config.resolve("GROQ_API_KEY"), ("environment-test", "environment"))
        self.assertNotIn("environment-test", json.dumps(config.snapshot()))

    def test_numeric_validation(self):
        for value in ("nan", "inf", "0", "-2"):
            with self.subTest(value=value), patch.dict(os.environ, {"AZURE_LLM_TIMEOUT": value}):
                with self.assertRaises(ValueError):
                    config.get("AZURE_LLM_TIMEOUT")

    def test_worker_receives_file_parameters(self):
        config.user_dir().mkdir()
        (config.user_dir() / ".env").write_text("TRANSCRIBE_WHISPER_MODEL=medium\nTRANSCRIBE_GPU_DUTY=0.5\n", encoding="utf-8")
        with patch.object(setup, "ensure_venv", return_value=Path(sys.executable)), patch.object(setup.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="[]")) as run:
            setup.run_venv_worker("whisper_local_worker.py", ["synthetic.wav"])
        self.assertEqual(run.call_args.kwargs["env"]["TRANSCRIBE_WHISPER_MODEL"], "medium")
        self.assertEqual(run.call_args.kwargs["env"]["TRANSCRIBE_GPU_DUTY"], "0.5")

    def test_secrets_hidden_in_repr_and_errors(self):
        os.environ["AZURE_LLM_KEY"] = "synthetic-secret"
        self.assertNotIn("synthetic-secret", repr(llm.Config("azure", key="synthetic-secret")))
        self.assertNotIn("synthetic-secret", config.redact("HTTP error: synthetic-secret"))
        with patch.object(setup.getpass, "getpass", return_value="synthetic-secret") as hidden, contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(setup._prompt_for_key("TEST_KEY", "test", "example"), "synthetic-secret")
        hidden.assert_called_once()
        self.assertNotIn("synthetic-secret", out.getvalue())

    def test_speaker_correction_merge_split_and_override_removal(self):
        speakers.apply_to_files(self.p.base, {"SPEAKER_00": "Urs", "SPEAKER_01": "Urs"}, {"00:00": "Other"})
        speakers.apply_to_files(self.p.base, {"SPEAKER_00": "Andrea", "SPEAKER_01": "Beat"})
        text = self.p.transcript.read_text(encoding="utf-8")
        self.assertIn("[Andrea] First", text)
        self.assertIn("[Beat] Final decision", text)
        self.assertNotIn("Other", text)
        speakers.apply_to_files(self.p.base, {})
        self.assertIn("[SPEAKER_00]", self.p.transcript.read_text(encoding="utf-8"))

    def test_vtt_correction_merge_split(self):
        vtt = self.p.base.with_suffix(".vtt")
        vtt.write_text("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n<v SPEAKER_00>First\n\n00:01:00.000 --> 00:01:01.000\n<v SPEAKER_01>Last\n", encoding="utf-8")
        speakers.apply_to_files(self.p.base, {"SPEAKER_00": "Urs", "SPEAKER_01": "Urs"})
        speakers.apply_to_files(self.p.base, {"SPEAKER_00": "Andrea", "SPEAKER_01": "Beat"})
        self.assertIn("<v Andrea>", vtt.read_text())
        self.assertIn("<v Beat>", vtt.read_text())

    def test_last_block_and_chapter_coverage(self):
        blocks = [Block("00:00", "A", "First"), Block("01:00", "A", "Final decision")]
        chapters = kompakt.normalize_chapters([{"start": "00:00", "end": "01:00", "title": "Topic"}], blocks)
        self.assertEqual(chapters[-1]["end"], "01:01")
        with patch.object(kompakt.llm, "ask_json", return_value={"statements": []}) as ask:
            kompakt.condense(chapters[0], blocks, [], [], [], "de")
        self.assertIn("Final decision", ask.call_args.args[0])

    def test_review_detects_actual_upload_changes(self):
        self.p.report.write_text("## Übersicht\nText\n", encoding="utf-8")
        self.p.illustrations.mkdir()
        image = self.p.illustrations / "ill_01.png"
        image.write_bytes(b"before")
        write_json(self.p.spec, [{"id": 1}])
        write_json(self.p.manifest, {"illustrations": [{"id": 1, "path": image.name}]})
        hashes = lambda: {k: h for k, _, h, _ in review.items(self.p, "synthetic target")}
        before = hashes()
        image.write_bytes(b"after")
        self.assertNotEqual(before["illustrations"], hashes()["illustrations"])
        self.p.transcript.write_text("changed", encoding="utf-8")
        self.assertNotEqual(before["transcript"], hashes()["transcript"])
        self.assertNotEqual(before["release"], hashes()["release"])

    def test_agent_propagates_failure(self):
        with patch.object(agent, "step", return_value=7), patch.object(agent.llm, "load_config", return_value=llm.Config("none")):
            self.assertEqual(self.invoke(agent, [str(self.p.base), "--no-frames"]), 7)

    def test_probe_failure_exit(self):
        with patch.object(llm, "load_config", return_value=llm.Config("azure", models={"text": "mock"})), patch.object(llm, "chat", side_effect=RuntimeError("failed")), contextlib.redirect_stdout(io.StringIO()):
            self.assertNotEqual(llm._probe(None), 0)

    def test_incomplete_report_preserves_existing(self):
        self.p.report.write_text("old report", encoding="utf-8")
        with patch.object(llm, "available", return_value=(True, "")), patch.object(llm, "load_config", return_value=llm.Config("azure", models={"text": "mock"})), patch.object(llm, "ask", return_value=llm.Reply("## Übersicht\nPartial", "mock", raw={"choices": [{"finish_reason": "length"}]})):
            with self.assertRaises(RuntimeError):
                self.invoke(report, [str(self.p.base), "--no-frames"])
        self.assertEqual(self.p.report.read_text(), "old report")

    def test_frame_coverage_and_partial_resume(self):
        image = self.root / "synthetic.png"
        image.write_bytes(b"synthetic image")
        frames = [{"path": str(image), "ts": fmt_ts(i * 60), "kind": "CUT"} for i in range(100)]
        calls = []
        def ask(prompt, **kwargs):
            import re
            calls.append(prompt)
            if len(calls) == 1:
                raise RuntimeError("one failed batch")
            ts = re.findall(r"ts=([^ ]+) \(", prompt)
            return llm.Reply(json.dumps({"frames": [{"ts": t, "content": "frame"} for t in ts]}), "mock")
        with patch.object(llm, "load_config", return_value=llm.Config("azure", models={"vision": "mock"})), patch.object(llm, "ask", side_effect=ask), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(RuntimeError):
                report.frame_pass(self.p, {"frames": frames}, 48, "de", False)
            first = len(calls)
            result = report.frame_pass(self.p, {"frames": frames}, 48, "de", False)
        self.assertEqual(len(calls) - first, 1)
        self.assertEqual(len(result), 48)
        self.assertIn("1:39:00", [f["ts"] for f in result])

    def test_os_lock_excludes_second_owner(self):
        one = joblock.JobLock(self.root / "job.lock")
        two = joblock.JobLock(self.root / "job.lock", background=True)
        try:
            self.assertEqual(one.acquire(), "acquired")
            self.assertEqual(two.acquire(), "busy")
        finally:
            one.release()
            two.release()
        self.assertEqual(two.acquire(), "acquired")
        two.release()

    def test_dependency_changes_invalidate_report(self):
        state = StageState(self.p.base)
        self.p.report.write_text("report", encoding="utf-8")
        key = stage_key(self.p, "report", {"language": "de"})
        state.record("report", key, [self.p.report])
        self.assertTrue(state.current("report", key, [self.p.report]))
        self.p.links.write_text("a new link", encoding="utf-8")
        self.assertFalse(state.current("report", stage_key(self.p, "report", {"language": "de"}), [self.p.report]))

    def test_pipeline_rejects_typos_and_cloud_conflict_before_skip(self):
        for args in (["--whispr", "local"], ["--local", "--whisper", "openai"]):
            with self.subTest(args=args), self.assertRaises(SystemExit) as exc:
                self.invoke(pipeline, [str(self.p.base), *args])
            self.assertEqual(exc.exception.code, 2)

    def test_pipeline_custom_output_uses_structured_result(self):
        media = self.root / "input.mp4"
        media.write_bytes(b"synthetic")
        target = self.root / "custom.md"
        calls = []
        def call(script, *args, **kwargs):
            calls.append((script, args))
            if script == "run.py":
                write_json(Path(args[args.index("--result-json") + 1]), {"base": str(target.with_suffix("")), "protocol": "custom.protocol.md"})
            return SimpleNamespace(returncode=0)
        with patch.object(pipeline, "call", side_effect=call), patch.object(setup, "find_tool", return_value="synthetic"):
            self.assertEqual(self.invoke(pipeline, [str(media), "--save-md", str(target)]), 0)
        self.assertEqual(calls[-1][1][0], str(target.with_suffix("")))

    def test_all_companion_paths(self):
        for suffix in (".review.md", ".agent.json", ".publish.json", ".state.json", ".MP4", ".flac"):
            self.assertEqual(resolve_base("x" + suffix), Path("x"))

    def test_real_cli_media_resume_and_parameter_change(self):
        if not shutil.which("ffprobe", path=HOST_PATH):
            self.skipTest("ffprobe not installed")
        os.environ["PATH"] = HOST_PATH
        # The fake speech cache avoids a model download; probing and the full CLI
        # process boundary still operate on a real WAV file.
        media = self.root / "sample.wav"
        with wave.open(str(media), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
            w.writeframes(b"\0\0" * 16000)
        write_json(media.with_suffix(".segments.json"), {"backend": "fixture", "segments": [
            {"start": 0, "end": 0.4, "text": "First sentence."},
            {"start": 0.5, "end": 0.9, "text": "Final sentence."}]})
        args = [sys.executable, "-X", "utf8", "-B", str(ROOT / "transcribe.py"), "run", str(media),
                "--no-diarize", "--no-repair", "--no-ocr", "--analysis", "none", "--json"]
        first = subprocess.run(args, capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(first.returncode, 0, first.stderr)
        result = json.loads(first.stdout)
        self.assertEqual(result["status"], "complete")
        transcript = Path(result["transcript"])
        self.assertIn("Final sentence.", transcript.read_text(encoding="utf-8"))
        resumed = subprocess.run([sys.executable, "-X", "utf8", "-B", str(ROOT / "transcribe.py"), "run",
                                  str(transcript), "--analysis", "none", "--json"],
                                 capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertNotIn("-- run.py", resumed.stderr)
        refresh = subprocess.run([*args, "--fresh", "--plan"], capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(refresh.returncode, 0, refresh.stderr)
        self.assertEqual(json.loads(refresh.stdout)["stages"][0]["status"], "pending")
        old = transcript.stat().st_mtime_ns
        second = subprocess.run(args, capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(transcript.stat().st_mtime_ns, old)
        self.assertNotIn("-- run.py", second.stderr)
        plan = subprocess.run([*args, "--plan", "--start", "0.5"], capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(plan.returncode, 0, plan.stderr)
        self.assertEqual(json.loads(plan.stdout)["stages"][0]["status"], "pending")
        changed = subprocess.run([*args, "--start", "0.5"], capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertNotIn("First sentence.", transcript.read_text(encoding="utf-8"))
        self.assertIn("Final sentence.", transcript.read_text(encoding="utf-8"))

    def test_install_verify_cleanup_loop(self):
        ready = {"value": False}
        def status():
            return {"ready": ready["value"], "gpu": False}
        def provision(*args, **kwargs):
            ready["value"] = True
            return 0
        with patch.object(setup, "find_tool", return_value="synthetic-tool"), patch.object(setup, "venv_status", side_effect=status), patch.object(setup, "cmd_provision_venv", side_effect=provision) as install, patch.object(command, "secret_file_status", return_value={"ready": True}), contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(command.doctor("local")["ready"])
            self.assertEqual(command.install("local", True), 0)
            self.assertTrue(command.doctor("local")["ready"])
            launcher = next(iter(command.launchers()))
            old = launcher.stat().st_mtime_ns
            self.assertEqual(command.install("local", True), 0)
            self.assertEqual(launcher.stat().st_mtime_ns, old)
            self.assertEqual(install.call_count, 1)
            self.assertEqual(command.main(["cleanup"]), 0)
            self.assertFalse(launcher.exists())
            self.assertEqual(command.main(["cleanup"]), 0)
            self.assertTrue(command.doctor("local")["ready"])
            self.assertEqual(command.install("local", True), 0)
            self.assertTrue(launcher.exists())

    def test_failed_install_does_not_mark_complete(self):
        with patch.object(setup, "_check_binaries", return_value=[]), patch.object(setup, "find_tool", return_value="test"), patch.object(setup, "_have_api_key", return_value=(False, None)), patch.object(setup, "_auto_provision_local_venv"), patch.object(setup, "venv_status", return_value={"ready": False}), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertNotEqual(setup.cmd_install(non_interactive=True), 0)
        self.assertNotEqual(config.get("SETUP_COMPLETE"), "true")

    def test_generated_parameter_documents(self):
        self.assertEqual((ROOT / ".env.example").read_text(encoding="utf-8"), config.template())
        self.assertEqual((ROOT / "references/parameters.md").read_text(encoding="utf-8"), command.parameter_reference())
        self.assertEqual((ROOT / "references/options.md").read_text(encoding="utf-8"), command.option_reference())

    def test_frame_cache_is_stable_and_content_sensitive(self):
        frame = self.root / "frame.png"
        frame.write_bytes(b"first")
        proto = {"frames": [{"path": str(frame), "ts": "00:00", "kind": "REG"}]}
        reply = llm.Reply('{"frames": [{"ts":"00:00", "content":"frame"}]}', "mock")
        with patch.object(llm, "load_config", return_value=llm.Config("azure", models={"vision": "mock"})), patch.object(llm, "ask", return_value=reply) as ask, contextlib.redirect_stderr(io.StringIO()):
            report.frame_pass(self.p, proto, 48, "de", False)
            before = self.p.frames_json.read_bytes(), self.p.frames_json.stat().st_mtime_ns
            report.frame_pass(self.p, proto, 48, "de", False)
            self.assertEqual(before, (self.p.frames_json.read_bytes(), self.p.frames_json.stat().st_mtime_ns))
            self.assertEqual(ask.call_count, 1)
            frame.write_bytes(b"changed")
            report.frame_pass(self.p, proto, 48, "de", False)
            self.assertEqual(ask.call_count, 2)

    def test_completed_report_reuses_model_until_language_changes(self):
        reply = llm.Reply("## Übersicht\nOverview\n## Summary\nSummary\n## Analysis\nAnalysis", "mock")
        with patch.object(llm, "available", return_value=(True, "")), patch.object(llm, "load_config", return_value=llm.Config("azure", models={"text": "mock"})), patch.object(llm, "ask", return_value=reply) as ask:
            args = [str(self.p.base), "--no-frames"]
            self.assertEqual(self.invoke(report, args), 0)
            old = self.p.report.stat().st_mtime_ns
            self.assertEqual(self.invoke(report, args), 0)
            self.assertEqual(ask.call_count, 1)
            self.assertEqual(self.p.report.stat().st_mtime_ns, old)
            self.assertEqual(self.invoke(report, [*args, "--language", "en"]), 0)
            self.assertEqual(ask.call_count, 2)

    def test_chapter_failure_preserves_other_completed_work(self):
        self.p.transcript.write_text("[00:00] [A] First topic\n[01:00] [B] Last topic\n", encoding="utf-8")
        chapters = [{"start": "00:00", "title": "First"}, {"start": "01:00", "title": "Last"}]
        failed = {"once": True}
        calls = []
        def condense(ch, *args):
            calls.append(ch["title"])
            if ch["title"] == "First" and failed["once"]:
                failed["once"] = False
                raise RuntimeError("synthetic interruption")
            return [{"time": ch["start"], "speaker": "A", "text": ch["title"]}]
        with patch.object(llm, "available", return_value=(True, "")), patch.object(llm, "load_config", return_value=llm.Config("azure", models={"text": "mock"})), patch.object(kompakt, "chapters_from_llm", return_value=chapters), patch.object(kompakt, "condense", side_effect=condense):
            with self.assertRaises(RuntimeError):
                self.invoke(kompakt, [str(self.p.base)])
            self.assertFalse(self.p.kompakt.exists())
            self.assertEqual(self.invoke(kompakt, [str(self.p.base)]), 0)
            self.assertEqual(calls.count("First"), 2)
            self.assertEqual(calls.count("Last"), 1)

    def test_attachment_remote_edit_invalidates_cached_hash(self):
        remote = {"id": "123", "version": {"number": 2}, "_links": {"download": "/attachment"}}
        client = SimpleNamespace(download=lambda _: b"changed on server")
        previous = {"id": "123", "version": 1, "sha": publish.sha(b"local")}
        current = publish.attachment_state(client, remote, previous)
        self.assertEqual(current["sha"], publish.sha(b"changed on server"))
        client.download = lambda _: self.fail("unchanged remote must reuse its hash")
        self.assertEqual(publish.attachment_state(client, remote, current), current)

    def test_secret_file_permissions_are_verified_after_atomic_write(self):
        from state import write
        path = config.user_dir() / ".env"
        write(path, "GROQ_API_KEY=synthetic-only\n", secret=True)
        self.assertTrue(command.secret_file_status()["ready"])
        old = path.stat().st_mtime_ns
        write(path, "GROQ_API_KEY=synthetic-only\n", secret=True)
        self.assertEqual(path.stat().st_mtime_ns, old)

    def test_missing_crop_is_rendered_again_without_reselecting(self):
        from state import file_hash
        self.p.illustrations.mkdir()
        crop = self.p.illustrations / "ill_01.png"
        crop.write_bytes(b"crop")
        write_json(self.p.spec, [{"id": 1, "timestamp": 0, "bbox": [0, 0, 1, 1], "redaction": "off"}])
        manifest = [{"id": 1, "path": crop.name}]
        write_json(self.p.manifest, {"illustrations": manifest})
        key = stage_key(self.p, "illustrate", {"language": None, "max": 12, "rounds": 2})
        StageState(self.p.base).record("illustrate", key, [self.p.spec, self.p.manifest, crop], detail=file_hash(self.p.spec))
        crop.unlink()
        def render(*args):
            crop.write_bytes(b"restored")
            return manifest
        with patch.object(illustrate_agent, "video_path", return_value=self.root / "synthetic.mp4"), patch.object(illustrate_agent, "render", side_effect=render) as rendered:
            self.assertEqual(self.invoke(illustrate_agent, [str(self.p.base)]), 0)
            rendered.assert_called_once()
            self.assertEqual(crop.read_bytes(), b"restored")

    def test_legacy_regular_frames_are_not_lost(self):
        from companions import read_protocol
        self.p.protocol.write_text("- `frame.png` (t=00:12)\n", encoding="utf-8")
        self.assertEqual(read_protocol(self.p.protocol)["frames"][0]["kind"], "REG")

    def test_bundle_is_reproducible_and_carries_installation(self):
        import zipfile
        import build_skill
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            for name in ("SKILL.md", "INSTALL.md", "transcribe.py", "scripts/command.py", "scripts/config.py"):
                archive.writestr(name, "fixture")
            archive.writestr(".claude-plugin/plugin.json", '{"version":"1.2.3"}')
            archive.writestr("hooks/hook.sh", "ignored")
        first = build_skill.bundle(data.getvalue())
        self.assertEqual(first, build_skill.bundle(data.getvalue()))
        with zipfile.ZipFile(io.BytesIO(first)) as bundle:
            self.assertIn("transcribe/INSTALL.md", bundle.namelist())
            self.assertEqual(bundle.read("transcribe/.build-version"), b"1.2.3\n")
            self.assertNotIn("transcribe/hooks/hook.sh", bundle.namelist())


if __name__ == "__main__":
    unittest.main()
