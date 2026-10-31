import pathlib, subprocess, os, json
root=pathlib.Path.cwd(); lab=root/'.test-lab'; ev=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M69W5BQMS7DGVNE9SPTB6270')
old=subprocess.check_output(['git','show','23a288e:bin/fm-task-inbox-lib.sh'],text=True)
old=old.replace('_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"','_FM_TASK_INBOX_LIB_DIR='+repr(str(root/'bin')))
file=lab/'previous-inbox-lib.sh';file.write_text(old)
state=lab/'regression-state';state.mkdir(exist_ok=True)
env=os.environ.copy();env.update(FM_STATE_OVERRIDE=str(state),FM_HOME=str(lab/'home'),FM_ROOT_OVERRIDE=str(lab/'home'),FM_TASK_INBOX_GRACE_SECS='1')
setup='''. bin/fm-task-inbox-lib.sh
first=$(fm_task_inbox_write "$FM_STATE_OVERRIDE" t1 previous)
fm_task_inbox_record_ring "$FM_STATE_OVERRIDE" t1 "$first"
next=$(fm_task_inbox_write "$FM_STATE_OVERRIDE" t1 current)
mv "$first" "${first%/*}/handled/"
touch -t 202001010000 "$next"
fm_task_inbox_record_escalated "$FM_STATE_OVERRIDE" t1 "$next"
fm_task_inbox_record_urgent_escalated "$FM_STATE_OVERRIDE" t1 "$next"
'''
subprocess.run(['/bin/bash','-ec',setup],env=env,check=True)
old_result=subprocess.check_output(['/bin/bash','-c','. '+str(file)+'; fm_task_inbox_due_action "$FM_STATE_OVERRIDE" t1'],env=env,text=True)
subprocess.run(['/bin/bash','-ec','. bin/fm-task-inbox-lib.sh; fm_task_inbox_record_escalated "$FM_STATE_OVERRIDE" t1 "$FM_STATE_OVERRIDE/t1.inbox/002.msg"'],env=env,check=True)
new_result=subprocess.check_output(['/bin/bash','-c','. bin/fm-task-inbox-lib.sh; fm_task_inbox_due_action "$FM_STATE_OVERRIDE" t1'],env=env,text=True)
assert old_result.startswith('ring ') and new_result=='quiet'
(ev/'stale-ladder-regression.json').write_text(json.dumps({'previous_commit':'23a288e','previous_due_action':old_result,'target_due_action':new_result,'contract':'A marker for the current oldest instruction survives a previous instruction’s attempt state.'},indent=2))
print(json.dumps({'previous':old_result,'target':new_result}))
