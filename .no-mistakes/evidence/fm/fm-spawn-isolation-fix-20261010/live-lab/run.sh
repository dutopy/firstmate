#!/bin/bash
# usage: run.sh <id> [env assignments...]
L=/tmp/fm-lab-iExYx1; id=$1; shift
export TMUX_TMPDIR=$L/tmx
export TMUX="$(tmux display-message -p '#{socket_path},#{pid},0')"
env "$@" FM_ROOT_OVERRIDE='' FM_HOME=$L/home FM_STATE_OVERRIDE=$L/home/state FM_DATA_OVERRIDE=$L/home/data FM_PROJECTS_OVERRIDE=$L/home/projects FM_CONFIG_OVERRIDE=$L/home/config FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \
  /bin/bash /Users/pierre/.no-mistakes/worktrees/152fa2a6a341/01M4KCWNWT093SX79H4A52FQ6P/bin/fm-spawn.sh $id $L/repo --mode no-mistakes --yolo off 2>&1
echo "exit=$?"
