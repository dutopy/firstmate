#!/usr/bin/env bash
# Live driver: real hook transport, real disposable processes/files.
CHECK=${CHECK:?}
T=$(mktemp -d /tmp/fmguard-drive.XXXX); WT=$T/copy6; FOREIGN=$T/foreign
mkdir -p $WT $FOREIGN/keep; echo data > $FOREIGN/keep/data; echo data > $WT/mine
git -C $WT init -q 2>/dev/null
( cd $FOREIGN && exec -a foreign-bench sleep 600 ) & FP=$!
( cd $WT && exec sleep 601 ) & OWN=$!
sleep 0.5
fails=0
run() { # name expect(allow|deny) command
  local name=$1 exp=$2 cmd=$3 payload rc
  payload=$(CMD="$cmd" CWD="$WT" node -e 'console.log(JSON.stringify({tool_name:"Bash",tool_input:{command:process.env.CMD},cwd:process.env.CWD}))')
  out=$(cd "$WT" && printf '%s' "$payload" | "$CHECK" --root "$WT" --owner-pid $$ 2>&1 >/dev/null); rc=$?
  if { [ $exp = deny ] && [ $rc = 2 ]; } || { [ $exp = allow ] && [ $rc = 0 ]; }; then echo "PASS [$exp rc=$rc] $name :: $cmd"; else echo "FAIL [want $exp rc=$rc] $name :: $cmd :: $out"; fails=$((fails+1)); fi
}
echo "== deny cases (nothing is executed; foreign process + sentinel must survive)"
run pkill-f deny "pkill -f chrome-headless-shell"
run pkill-daemon deny "pkill -f daemon.py"
run killall deny "killall chrome"
run split-pkill deny 'P=pk; ${P}ill -f chrome'
run split-pkill2 deny 'a=pk; b=ill; $a$b -f x'
run cmdsub-pkill deny '$(echo pkill) -f chrome'
run bash-c deny "bash -c 'pkill -f explore.py'"
run bash-o-c deny 'bash -o pipefail -c "rm -rf /tmp/zz"'
run xargs-kill deny "pgrep -f dbg.py | xargs kill"
run killsub deny 'kill $(pgrep -f chrome)'
run foreign-pid deny "kill $FP"
run foreign-pid9 deny "kill -9 $FP"
run owner-chain deny "kill $$"
run py-oskill deny "python3 -c 'import os; os.kill($FP, 9)'"
run py-subproc deny "python3 -c 'import subprocess; subprocess.run([\"pkill\",\"-f\",\"x\"])'"
run py-concat deny "python3 -c 'import subprocess; subprocess.run([\"pk\" \"ill\",\"-f\",\"x\"])'"
run node-concat deny "node -e 'require(\"child_process\").execSync(\"pk\"+\"ill -f sleep\")'"
run node-mixed deny "node -e 'require(\"child_process\").execSync(\"pk\"+'\"'\"'ill -f sleep'\"'\"')'"
run alias-oskill deny "python3 -c 'import os; k=os.kill; k($FP,9)'"
run trap deny 'trap "pkill -f x" EXIT'
run rm-foreign deny "rm -rf $FOREIGN/keep"
run rm-root deny "rm -rf /tmp/zz"
run rm-tilde-user deny "rm -rf ~root"
run rm-rec-prefix deny "rm --rec /tmp/zz"
run rm-brace deny "rm -rf {/tmp/zz,a}"
run rm-symlink deny "ln -s $FOREIGN zl; rm -rf zl/"
run flock deny "flock /tmp/l rm -rf /tmp/zz"
run su-c deny "su -c 'rm -rf /tmp/zz'"
run echo-pipe deny "echo rm -rf /tmp/zz | sh"
run echo-script deny "echo rm -rf /tmp/zz > s.sh; sh s.sh"
run printf-fmt deny 'printf "%s" "rm -rf /tmp/zz" | sh'
run printf-hex deny 'printf "pk\x69ll -f x" | sh'
run echo-e deny 'echo -e "pk\x69ll -f x" | sh'
run awk deny "awk 'BEGIN{system(\"rm -rf /tmp/zz\")}'"
run git-clean deny "git --git-dir=/tmp/x clean -fdx"
run reader-shadow deny 'mkdir b; printf "#!/bin/sh\n" > b/pwd; PATH=$PWD/b:$PATH python3 -c "print(\"$(pwd)\")"'
echo "== allow cases"
run own-job allow 'sleep 1 & kill $!'
run signal0 allow "kill -0 $FP"
run own-pid allow "kill $OWN"
run rm-own allow "rm -rf $WT/mine"
run rm-tmp-fm allow "rm -rf /tmp/fm-task1/x"
run benign allow "ls -la && echo hello"
run benign-py allow "python3 -c 'print(1+1)'"
run string-use allow "python3 -c 'print(\"pk\" \"x\")'"
echo "== survivors"
kill -0 $FP 2>/dev/null && echo "PASS foreign process alive" || { echo "FAIL foreign process dead"; fails=$((fails+1)); }
[ -f $FOREIGN/keep/data ] && echo "PASS foreign sentinel intact" || { echo "FAIL foreign sentinel gone"; fails=$((fails+1)); }
kill $FP $OWN 2>/dev/null; wait 2>/dev/null
rm -rf "${T:?}"
echo "fails=$fails"; exit $fails
