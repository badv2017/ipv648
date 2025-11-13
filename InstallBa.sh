#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Tạo mật khẩu ngẫu nhiên mạnh hơn (16 ký tự)
random() {
    openssl rand -base64 24 | tr -dc A-Za-z0-9 | head -c16
    echo
}

# Tạo địa chỉ IPv6 trong subnet
gen_ipv6() {
    printf "$1:%x:%x:%x:%x\n" \
    $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))
}

# Cài đặt 3proxy
install_3proxy() {
    echo "Đang cài đặt 3proxy..."
    URL="https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.4.tar.gz"
    wget -qO- $URL | tar -xz
    cd 3proxy-0.9.4
    make -f Makefile.Linux
    if [ $? -ne 0 ]; then
        echo "Lỗi: Không thể compile 3proxy"
        exit 1
    fi
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd ..
    echo "Cài đặt 3proxy thành công!"
}

# Tạo file cấu hình 3proxy
gen_3proxy_cfg() {
    cat <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
auth strong
users $(awk -F "/" '{print $1 ":CL:" $2}' $WORKDIR/data.txt | paste -sd " ")
$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p"$4" -i"$3" -e"$5"\nflush\n"}' $WORKDIR/data.txt)
EOF
}

# Tạo file proxy.txt với format IP:PORT:USER:PASS
gen_proxy_txt() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' $WORKDIR/data.txt > $WORKDIR/proxy.txt
}

# Tạo dữ liệu proxy
gen_data() {
    local current_port=$START_PORT
    local count=0
    while [ $count -lt $PROXY_COUNT ]; do
        echo "proxy_user_$current_port/$(random)/$IP4/$current_port/$(gen_ipv6 $IP6)"
        current_port=$((current_port + 1))
        count=$((count + 1))
    done
}

# Tạo script cấu hình mạng
gen_network_scripts() {
    # Script thêm IPv6 addresses
    cat <<'IFCONFIG_SCRIPT' > $WORKDIR/boot_ifconfig.sh
#!/bin/bash
# Xóa các địa chỉ IPv6 cũ (nếu có)
ip -6 addr show dev eth0 | grep -oP '(?<=inet6 )[0-9a-f:]+/64' | while read addr; do
    ip -6 addr del $addr dev eth0 2>/dev/null || true
done
# Thêm địa chỉ IPv6 mới
IFCONFIG_SCRIPT
    
    awk -F "/" '{print "ip -6 addr add "$5"/64 dev eth0"}' $WORKDIR/data.txt >> $WORKDIR/boot_ifconfig.sh
    
    # Script cấu hình iptables
    cat <<'IPTABLES_SCRIPT' > $WORKDIR/boot_iptables.sh
#!/bin/bash
# Xóa rules cũ
iptables -D INPUT -p tcp --dport START_PORT:END_PORT -j ACCEPT 2>/dev/null || true
# Thêm rule mới
iptables -I INPUT -p tcp --dport START_PORT:END_PORT -j ACCEPT
IPTABLES_SCRIPT
    
    # Thay thế START_PORT và END_PORT
    sed -i "s/START_PORT/$START_PORT/g" $WORKDIR/boot_iptables.sh
    sed -i "s/END_PORT/$END_PORT/g" $WORKDIR/boot_iptables.sh
    
    chmod +x $WORKDIR/boot_*.sh
}

# Cleanup cấu hình cũ
cleanup_old_config() {
    echo "Dọn dẹp cấu hình cũ..."
    systemctl stop 3proxy 2>/dev/null || true
    systemctl disable 3proxy 2>/dev/null || true
    
    # Xóa các IPv6 addresses cũ
    ip -6 addr show dev eth0 | grep -oP '(?<=inet6 )[0-9a-f:]+/64' | while read addr; do
        ip -6 addr del $addr dev eth0 2>/dev/null || true
    done
    
    # Xóa iptables rules cũ
    iptables -D INPUT -p tcp --dport 21000:29999 -j ACCEPT 2>/dev/null || true
}

# Tạo systemd service
setup_systemd_service() {
    cat <<EOF > /etc/systemd/system/3proxy.service
[Unit]
Description=3proxy Proxy Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNOFILE=100000
ExecStartPre=/bin/sleep 5
ExecStartPre=/bin/bash $WORKDIR/boot_ifconfig.sh
ExecStartPre=/bin/bash $WORKDIR/boot_iptables.sh
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable 3proxy
    systemctl start 3proxy
}

# Validate IPv6 subnet
validate_ipv6() {
    if ! [[ $1 =~ ^[0-9a-fA-F:]+$ ]]; then
        echo "❌ Lỗi: IPv6 subnet không hợp lệ"
        exit 1
    fi
}

# Validate số lượng proxy
validate_proxy_count() {
    if ! [[ $1 =~ ^[0-9]+$ ]] || [ $1 -lt 1 ] || [ $1 -gt 10000 ]; then
        echo "❌ Lỗi: Số lượng proxy phải từ 1 đến 10000"
        exit 1
    fi
}

### MAIN ###
echo "======================================"
echo "  Script tạo IPv6 Proxy Server"
echo "======================================"
echo ""

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then 
    echo "❌ Vui lòng chạy script với quyền root (sudo)"
    exit 1
fi

# Cài đặt các gói cần thiết
echo "📦 Đang cài đặt các gói cần thiết..."
dnf install -y gcc make wget net-tools curl bsdtar zip iptables-nft openssl > /dev/null 2>&1

# Thiết lập thư mục làm việc
WORKDIR="/home/anhhungproxy"
mkdir -p $WORKDIR
cd $WORKDIR

# Lấy IPv4
IP4=$(curl -4 -s ifconfig.co)
if [ -z "$IP4" ]; then
    echo "❌ Không thể lấy địa chỉ IPv4"
    exit 1
fi

# Nhập thông tin từ người dùng
echo "📍 IPv4 của server: $IP4"
echo ""
read -p "🔢 Nhập số lượng proxy cần tạo (1-10000): " PROXY_COUNT
validate_proxy_count $PROXY_COUNT

read -p "🌐 Nhập subnet IPv6 (ví dụ: 2602:fa81:b): " IP6
validate_ipv6 $IP6

read -p "🔌 Nhập port bắt đầu (mặc định 21000): " START_PORT
START_PORT=${START_PORT:-21000}

END_PORT=$((START_PORT + PROXY_COUNT - 1))

echo ""
echo "======================================"
echo "  Thông tin cấu hình"
echo "======================================"
echo "IPv4: $IP4"
echo "IPv6 Subnet: $IP6"
echo "Số lượng proxy: $PROXY_COUNT"
echo "Port range: $START_PORT - $END_PORT"
echo "======================================"
echo ""
read -p "⚠️  Xác nhận tạo proxy? (y/n): " confirm
if [ "$confirm" != "y" ]; then
    echo "Đã hủy!"
    exit 0
fi

# Cleanup cấu hình cũ
cleanup_old_config

# Tạo dữ liệu
echo ""
echo "🔄 Đang tạo dữ liệu proxy..."
gen_data > data.txt

# Cài đặt 3proxy nếu chưa có
if [ ! -f "/usr/local/etc/3proxy/bin/3proxy" ]; then
    install_3proxy
else
    echo "✅ 3proxy đã được cài đặt"
fi

# Tạo cấu hình
echo "⚙️  Đang tạo file cấu hình..."
gen_3proxy_cfg > /usr/local/etc/3proxy/3proxy.cfg
gen_proxy_txt
gen_network_scripts

# Thiết lập systemd service
echo "🚀 Đang khởi động dịch vụ..."
setup_systemd_service

# Chờ service khởi động
sleep 3

# Kiểm tra trạng thái
if systemctl is-active --quiet 3proxy; then
    echo ""
    echo "======================================"
    echo "  ✅ TẠO PROXY THÀNH CÔNG!"
    echo "======================================"
    echo "📁 File proxy: $WORKDIR/proxy.txt"
    echo "📊 Tổng số proxy: $PROXY_COUNT"
    echo "🔌 Port range: $START_PORT - $END_PORT"
    echo ""
    echo "📋 Hiển thị 5 proxy đầu tiên:"
    head -5 $WORKDIR/proxy.txt
    echo "..."
    echo ""
    echo "💡 Lệnh hữu ích:"
    echo "   - Xem toàn bộ proxy: cat $WORKDIR/proxy.txt"
    echo "   - Kiểm tra service: systemctl status 3proxy"
    echo "   - Xem log: journalctl -u 3proxy -f"
    echo "   - Khởi động lại: systemctl restart 3proxy"
    echo "======================================"
else
    echo ""
    echo "❌ LỖI: Không thể khởi động 3proxy"
    echo "Xem log: journalctl -u 3proxy -n 50"
    exit 1
fi
