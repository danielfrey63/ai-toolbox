import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch

root = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(root / 'tests'))
import test_contracts as fixtures
import command
import config
import llm
import report
import run
import setup
from state import StageState, write_json, stage_key


@contextlib.contextmanager
def case():
    c = fixtures.Contracts('test_numeric_validation')
    c.setUp()
    try:
        yield c
    finally:
        c.doCleanups()


with case() as c:
    subprocess.run([sys.executable, '-m', 'venv', '--without-pip', str(setup.VENV_DIR)], check=True, capture_output=True)
    version = f'{sys.version_info.major}.{sys.version_info.minor}'
    gpu = setup._gpu_available()
    write_json(setup.VENV_MARKER, {'python': version, 'signature': setup._venv_signature(gpu, version)})
    status = setup.venv_status()
    imported = subprocess.run([str(setup.venv_python()), '-c', 'import faster_whisper'], capture_output=True)
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        installed = command.install('local', True)
    print(json.dumps({'case':'empty_runtime','doctor_ready':status['ready'],'import_exit':imported.returncode,'install_exit':installed}))

with case() as c:
    reply = llm.Reply('## Übersicht\nInitial\n## Summary\nInitial\n## Analysis\nInitial\n', 'mock')
    with patch.object(llm,'available',return_value=(True,'')), patch.object(llm,'ask',return_value=reply) as ask:
        write_json(c.p.ocr, {'frames':[{'t':0,'lines':[{'text':'Original name','score':1}]}]})
        c.invoke(report,[str(c.p.base),'--no-frames'])
        key = stage_key(c.p,'report',{'no_frames':True,'language':None,'max_frames':48})
        write_json(c.p.ocr, {'frames':[{'t':0,'lines':[{'text':'Corrected name','score':1}]}]})
        same = key == stage_key(c.p,'report',{'no_frames':True,'language':None,'max_frames':48})
        c.invoke(report,[str(c.p.base),'--no-frames'])
        print(json.dumps({'case':'ocr_report_dependency','key_unchanged':same,'model_calls':ask.call_count,'corrected_ocr_in_input':'Corrected name' in report.build_input(c.p,{},[],None)}))

with case() as c:
    source = c.root/'recording.wav'
    source.write_bytes(b'original recording')
    c.p.speakers.write_text('## Labels\n\n| Label | Talk time | Turns | Active | Name | Confidence | Evidence |\n|---|---|---|---|---|---|---|\n| SPEAKER_00 | 1s | 1 | 00:00 | Alice | high | human |\n',encoding='utf-8')
    backend = SimpleNamespace(name='whisper-local')
    segments = [{'start':0,'end':1,'text':'A different person is speaking'}]
    turns = [{'start':0,'end':1,'speaker':'SPEAKER_00'}]
    with patch.object(run,'download',return_value={'video_path':source}), patch.object(run,'get_metadata',return_value={'duration_seconds':10,'has_video':False}), patch.object(run,'extract_audio',return_value=source), patch.object(run,'select_backend',return_value=backend), patch.object(run,'select_backends',return_value=[backend]), patch.object(run,'transcribe_video',return_value=(segments,'whisper-local',{})), patch.object(run,'pick_diarize_backend',return_value='pyannote-local'), patch.object(run,'diarize_pyannote_local',return_value=turns):
        args=[str(source),'--out-dir',str(c.root/'work'),'--no-repair','--no-ocr','--whisper','whisper-local','--diarize','pyannote-local']
        c.invoke(run,args)
        source.write_bytes(b'replacement recording with different participants')
        c.invoke(run,args)
    print(json.dumps({'case':'replaced_source_names','transcript':c.p.transcript.read_text(encoding='utf-8')}))

with case() as c:
    missing = c.root/'absent'
    p=subprocess.run([sys.executable,'-X','utf8','-B',str(root/'transcribe.py'),'status',str(missing),'--json'],capture_output=True,text=True,encoding='utf-8')
    print(json.dumps({'case':'missing_status','exit':p.returncode,'result':json.loads(p.stdout)}))
