import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve()
work = Path(tempfile.mkdtemp(prefix='transcribe-mirror-probe-'))
repo = work/'toolbox'
bare = work/'mirror.git'
repo.mkdir()


def git(*args, cwd=repo):
    p = subprocess.run(['git', *args], cwd=cwd, capture_output=True, text=True, encoding='utf-8')
    if p.returncode:
        raise RuntimeError(p.stderr)
    return p.stdout.strip()


git('init', '-b', 'main')
git('config', 'user.name', 'Local evaluation')
git('config', 'user.email', 'evaluation@example.invalid')
git('config', 'core.hooksPath', str(work/'no-hooks'))
git('init', '--bare', str(bare))
tool = repo/'tools/mirror-skill/mirror-skill.sh'
tool.parent.mkdir(parents=True)
shutil.copyfile(source/'tools/mirror-skill/mirror-skill.sh', tool)
skill = repo/'.agents/skills/transcribe'
(skill/'.claude-plugin').mkdir(parents=True)
(skill/'.claude-plugin/plugin.json').write_text(json.dumps({'version':'1.0.0'}), encoding='utf-8')
(skill/'SKILL.md').write_text('Synthetic evaluation skill', encoding='utf-8')
(repo/'tools/catalog.json').write_text(json.dumps({'tools':[{'name':'transcribe','path':'.agents/skills/transcribe','mirror':{'remote':'test-mirror','url':bare.as_posix(),'branch':'master'}}]}), encoding='utf-8')
git('add', '.')
git('commit', '-m', 'Synthetic fixture')
split = git('subtree', 'split', '--prefix=.agents/skills/transcribe', 'main')
git('push', str(bare), f'{split}:refs/heads/master')
wrong = git('rev-parse', 'HEAD')
git('push', str(bare), f'{wrong}:refs/tags/v1.0.0')
bash = Path('C:/Program Files/Git/bin/bash.exe')
p = subprocess.run([str(bash), str(tool), 'transcribe', '--dry-run'], cwd=repo, capture_output=True, text=True, encoding='utf-8', timeout=60)
print(json.dumps({'case':'mirror_wrong_tag', 'exit':p.returncode,'split':split,'tag':wrong,'output':p.stdout,'error':p.stderr}))

# A pre-existing additional push mapping must not publish toolbox history.
git('config', '--unset-all', 'remote.test-mirror.push')
git('config', '--add', 'remote.test-mirror.push', 'refs/heads/main:refs/heads/toolbox-leak')
git('config', '--add', 'remote.test-mirror.push', 'refs/heads/test-mirror:refs/heads/master')
(skill/'.claude-plugin/plugin.json').write_text(json.dumps({'version':'1.0.1'}),encoding='utf-8')
git('add', '.')
git('commit','-m','Synthetic next release')
p=subprocess.run([str(bash),str(tool),'transcribe'],cwd=repo,capture_output=True,text=True,encoding='utf-8',timeout=60)
refs=git('ls-remote',str(bare))
print(json.dumps({'case':'mirror_additional_push_mapping','exit':p.returncode,'unexpected_branch_published':'refs/heads/toolbox-leak' in refs,'output':p.stdout,'error':p.stderr}))
