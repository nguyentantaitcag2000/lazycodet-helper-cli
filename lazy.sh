#!/bin/bash

# URL dẫn tới file source code của bạn trên GitHub
REPO_URL="https://raw.githubusercontent.com/nguyentantaitcag2000/lazycodet-helper-cli/main/lazy.sh"
INSTALL_PATH="/usr/local/bin/lazy"

case "$1" in
    "branch.history")
        # Code liệt kê lịch sử branch của bạn
        git reflog show --date=format:'%Y-%m-%d %H:%M:%S' | \
        grep 'checkout: moving from' | \
        awk -F' ' '{date=$2" "$3; for(i=1;i<=NF;i++) if($i=="to") {print "["date"] - "$ (i+1); next}}' | \
        uniq | less
        ;;

    "update")
        echo "Đang kiểm tra và cập nhật lazy tool..."
        # Tự tải chính nó về và ghi đè vào vị trí hiện tại
        sudo curl -sSL $REPO_URL -o $INSTALL_PATH
        sudo chmod +x $INSTALL_PATH
        echo "Cập nhật thành công lên phiên bản mới nhất!"
        ;;

    *)
        echo "Sử dụng: lazy [branch.history | update]"
        ;;
esac
