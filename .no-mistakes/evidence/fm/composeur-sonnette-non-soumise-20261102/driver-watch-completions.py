import json,time
from pathlib import Path
root=Path.cwd();lab=Path((root/'.phase-test/live-lab').read_text().strip());state=lab/'state'
ev=Path('/Users/pierre/.no-mistakes/evidence/01M6FP5GMCE6ECBH8RXVJGNS7T/codex-completions.json')
seen=[];last=None
for i in range(1200):
 file=state/'codex.turn-ended'
 try:
  stamp=file.stat().st_mtime_ns
  if stamp!=last:
   last=stamp
   seen.append({'turn_ended_mtime_ns':stamp,'attributed_thread':json.loads((state/'codex.native-inbox.binding.json').read_text())['session'],'handled_records':sorted(p.name for p in (state/'codex.inbox/handled').glob('*.msg'))})
   ev.write_text(json.dumps(seen,indent=2)+'\n')
 except (FileNotFoundError,KeyError):pass
 if len(seen)>=5:break
 time.sleep(.2)
