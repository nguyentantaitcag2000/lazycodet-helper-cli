#!/bin/bash
echo "Đang cài đặt lazy tool..."
# Tải file source code từ GitHub về và lưu thẳng vào bin
sudo curl -sSL https://raw.githubusercontent.com/user/repo/main/lazy.sh -o /usr/local/bin/lazy
sudo chmod +x /usr/local/bin/lazy
echo "Xong! Thử gõ: lazy branch.history"
