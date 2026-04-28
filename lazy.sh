#!/bin/bash

# URL dẫn tới file source code của bạn trên GitHub
REPO_URL="https://raw.githubusercontent.com/nguyentantaitcag2000/lazycodet-helper-cli/main/lazy.sh"
INSTALL_PATH="/usr/local/bin/lazy"

case "$1" in
    "branch.history")
        # 1. Kiểm tra xem có phải thư mục Git không
        if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
            echo "❌ Lỗi: Thư mục này không phải là một Git repository."
            exit 1
        fi

        # 2. Lấy dữ liệu và lưu vào một biến tạm để kiểm tra
        # Dùng GIT_PAGER=cat để tránh xung đột với cấu hình pager cá nhân
        data=$(GIT_PAGER=cat git reflog show --date=format:'%Y-%m-%d %H:%M:%S' | \
               grep 'checkout: moving from' | \
               awk -F' ' '{date=$2" "$3; for(i=1;i<=NF;i++) if($i=="to") {print "["date"] - "$ (i+1); next}}' | \
               uniq)

        # 3. Kiểm tra xem biến data có rỗng không
        if [ -z "$data" ]; then
            echo "ℹ️  Thông báo: Chưa có lịch sử chuyển nhánh (checkout) nào trong project này."
        else
            # Hiển thị dữ liệu qua less
            echo "$data" | less -FX
        fi
        ;;

    "update")
        echo "Đang kiểm tra và cập nhật lazy tool..."
        # Thêm biến thời gian để phá cache GitHub khi update
        sudo curl -sSL "${REPO_URL}?v=$(date +%s)" -o $INSTALL_PATH
        sudo chmod +x $INSTALL_PATH
        echo "✅ Cập nhật thành công lên phiên bản mới nhất!"
        ;;

    *)
        echo "Sử dụng: lazy [branch.history | update]"
        ;;
esac
