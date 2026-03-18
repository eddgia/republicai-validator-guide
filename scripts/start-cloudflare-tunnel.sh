#!/usr/bin/env bash

# Dừng tunnel cũ nếu đang chạy
pkill -f "cloudflared tunnel" || true

# Xóa log cũ
> ~/cf-tunnel.log

# Khởi chạy Quick Tunnel ngầm
nohup ~/cloudflared tunnel --url http://localhost:8080 > ~/cf-tunnel.log 2>&1 &

echo "Đang khởi tạo kết nối Cloudflare..."
sleep 5

# Trích xuất đường link
URL=$(grep -o 'https://[^ ]*\.trycloudflare\.com' ~/cf-tunnel.log | head -1)

if [ -n "$URL" ]; then
    echo "Thành công! Đường link công khai (Public URL) là:"
    echo "$URL"
    
    # Cập nhật đường link vào các file tính toán của bạn
    sed -i "s|SERVER_BASE=.*|SERVER_BASE=\"$URL\"|g" ~/run-compute-job.sh
    sed -i "s|SERVER_BASE=.*|SERVER_BASE=\"$URL\"|g" ~/cron-compute.sh
    sed -i "s|SERVER_BASE=.*|SERVER_BASE=\"$URL\"|g" ~/auto-compute.sh
    
    echo "Đã tự động cập nhật đường link mới vào các file tính toán!"
else
    echo "Lỗi: Không lấy được đường link từ Cloudflare. Xem chi tiết tại ~/cf-tunnel.log"
fi
