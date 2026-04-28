#!/bin/bash
echo "Đang cài đặt lazy tool..."

# Tạo một biến thời gian để phá cache
TIME_STAMP=$(date +%s)
URL="https://raw.githubusercontent.com/nguyentantaitcag2000/lazycodet-helper-cli/main/lazy.sh?v=$TIME_STAMP"

# Tải file
sudo curl -f -sSL "$URL" -o /usr/local/bin/lazy

if [ $? -eq 0 ]; then
    sudo chmod +x /usr/local/bin/lazy
    echo "------------------------------------------"
    echo "Cài đặt thành công! Thử gõ: lazy branch.history"
else
    echo "------------------------------------------"
    echo "Lỗi: Không thể tải file. Vui lòng kiểm tra lại URL hoặc kết nối mạng."
fi
