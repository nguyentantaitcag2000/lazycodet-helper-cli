#!/bin/bash

case "$1" in
    "branch.history")
        # Code lệnh cũ của bạn
        git reflog show --date=format:'%Y-%m-%d %H:%M:%S' | \
        grep 'checkout: moving from' | \
        awk -F' ' '{date=$2" "$3; for(i=1;i<=NF;i++) if($i=="to") {print "["date"] - "$ (i+1); next}}' | \
        uniq | less
        ;;
esac
