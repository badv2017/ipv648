#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Tạo mật khẩu ngẫu nhiên mạnh hơn
random() {
    tr </dev/urandom -dc 'A-Za-z0-9!@#$%^&*' | head -c12
    echo
}

# Tạo IPv6 ngẫu nhiên trong dải /48 với prefix rotation
gen48() {
    # Thêm tính ngẫu nhiên cao hơn cho các segment
    printf "$1:%04x:%04x:%04x:%04x:%04x\n" \
        $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) \
        $((RANDOM%65536)) $((RANDOM%65536))
}

# Cài đặt 3proxy
install_3proxy() {
    echo "Installing 3proxy..."
    URL="https://github.com/z3APA3A/3proxy/archive/3proxy-0.8.6.tar.gz"
    wget -qO- $URL | tar -xz
    cd 3proxy-3proxy-0.8.6
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd ..
}

# Tạo file cấu hình 3proxy với các tối ưu chống phát hiện
gen_3proxy_cfg() {
    cat <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.8.8
nserver 9.9.9.9
nscache 65536
# Tăng timeout để giảm reconnect frequency
timeouts 1 5 30 60 240 3600 15 60
setgid 65535
setuid 65535

# Logging để monitor
log /usr/local/etc/3proxy/logs/3proxy.log D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
rotate 30

# Authentication
auth strong
users $(awk -F "/" '{print $1 ":CL:" $2}' $WORKDIR/data.txt | paste -sd " ")

# Giới hạn bandwidth và connection để tránh abuse detection
# Max bandwidth: 200 Mbps = 25 MB/s = 26214400 bytes/s
maxbandwidth 26214400
$(awk -F "/" '{print "auth strong\nallow " $1 "\n# Proxy " $4 "\nproxy -6 -n -a -p"$4" -i"$3" -e"$5"\nmaxbandwidth 2621440\nflush\n"}' $WORKDIR/data.txt)
EOF
}

# Tạo file proxy.txt
gen_proxy_txt() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' $WORKDIR/data.txt > $WORKDIR/proxy.txt
}

# Sinh dữ liệu proxy với user ngẫu nhiên
gen_data() {
    seq $START_PORT $END_PORT | while read port; do
        # Tạo username ngẫu nhiên thay vì theo pattern
        username="u$(tr </dev/urandom -dc 'a-z0-9' | head -c8)"
        echo "$username/$(random)/$IP4/$port/$(gen48 $IP6)"
    done
}

# Tạo script cấu hình mạng
gen_network_scripts() {
    awk -F "/" '{print "ip -6 addr add "$5"/64 dev eth0"}' $WORKDIR/data.txt > $WORKDIR/boot_ifconfig.sh
    awk -F "/" '{print "iptables -I INPUT -p tcp --dport "$4" -m conntrack --ctstate NEW -m recent --set --name proxy"$4"\niptables -I INPUT -p tcp --dport "$4" -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 100 --name proxy"$4" -j DROP\niptables -I INPUT -p tcp --dport "$4" -j ACCEPT"}' $WORKDIR/data.txt > $WORKDIR/boot_iptables.sh
    chmod +x $WORKDIR/boot_*.sh
}

# Tạo script rotation IPv6 định kỳ
create_rotation_script() {
    cat <<'EOF' > $WORKDIR/rotate_ipv6.sh
#!/bin/bash
WORKDIR="/home/anhhungproxy"
IP6_PREFIX=$(head -n1 $WORKDIR/data.txt | awk -F "/" '{print $5}' | cut -d: -f1-3)

# Xóa IPv6 cũ
bash $WORKDIR/boot_ifconfig.sh | sed 's/add/del/g' | bash

# Tạo IPv6 mới
gen48() {
    printf "$1:%04x:%04x:%04x:%04x:%04x\n" \
        $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) \
        $((RANDOM%65536)) $((RANDOM%65536))
}

# Cập nhật data.txt với IPv6 mới
awk -F "/" -v prefix="$IP6_PREFIX" 'BEGIN{srand()}{
    new_ipv6=sprintf("%s:%04x:%04x:%04x:%04x:%04x", prefix, 
        int(rand()*65536), int(rand()*65536), int(rand()*65536),
        int(rand()*65536), int(rand()*65536))
    print $1"/"$2"/"$3"/"$4"/"new_ipv6
}' $WORKDIR/data.txt > $WORKDIR/data.txt.new
mv $WORKDIR/data.txt.new $WORKDIR/data.txt

# Apply IPv6 mới
bash $WORKDIR/boot_ifconfig.sh

# Restart 3proxy
killall 3proxy
sleep 2
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg

echo "[$(date)] IPv6 rotated successfully"
EOF
    chmod +x $WORKDIR/rotate_ipv6.sh
}

# Tạo keepalive script để duy trì traffic
create_keepalive_script() {
    cat <<'EOF' > $WORKDIR/keepalive.sh
#!/bin/bash
# Script tự động tạo traffic nhẹ để tránh bị coi là idle

WORKDIR="/home/anhhungproxy"
LOG_FILE="$WORKDIR/keepalive.log"

while IFS=: read -r host port user pass; do
    # Random delay giữa các request (5-15 giây)
    sleep $((5 + RANDOM % 10))
    
    # Gửi request đơn giản qua proxy
    timeout 10 curl -x "socks5://$user:$pass@$host:$port" \
        -s "https://ifconfig.co" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo "[$(date)] Keepalive OK: $host:$port" >> $LOG_FILE
    fi
done < <(head -10 $WORKDIR/proxy.txt | sed 's/:/ /g' | awk '{print $1":"$2":"$3":"$4}')
EOF
    chmod +x $WORKDIR/keepalive.sh
}

# Cấu hình cron jobs
setup_cron() {
    # Rotation IPv6 mỗi 6 giờ
    (crontab -l 2>/dev/null; echo "0 */6 * * * bash $WORKDIR/rotate_ipv6.sh >> $WORKDIR/rotation.log 2>&1") | crontab -
    
    # Keepalive mỗi 10 phút
    (crontab -l 2>/dev/null; echo "*/10 * * * * bash $WORKDIR/keepalive.sh >> $WORKDIR/keepalive.log 2>&1") | crontab -
    
    # Dọn log cũ hàng tuần
    (crontab -l 2>/dev/null; echo "0 2 * * 0 find $WORKDIR -name '*.log' -mtime +7 -delete") | crontab -
}

# Cấu hình khởi động cùng hệ thống
setup_rc_local() {
    cat <<EOF > /etc/rc.d/rc.local
#!/bin/bash
bash $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_iptables.sh
ulimit -n 100000
# Tăng giới hạn connection tracking
echo 262144 > /proc/sys/net/netfilter/nf_conntrack_max
echo 65536 > /proc/sys/net/ipv4/ip_local_port_range
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
EOF
    chmod +x /etc/rc.d/rc.local
}

# Cấu hình sysctl tối ưu
optimize_sysctl() {
    cat <<EOF >> /etc/sysctl.conf
# Tối ưu cho proxy server
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.netfilter.nf_conntrack_max = 262144
EOF
    sysctl -p
}

# Upload proxy.txt
upload_proxy_txt() {
    echo "Uploading proxy list..."
    curl -F "file=@$WORKDIR/proxy.txt" https://file.io
}

### MAIN SCRIPT ###
echo "=== Cài đặt Proxy IPv6 với chống block ==="
yum install -y gcc make wget net-tools curl bsdtar zip cronie

WORKDIR="/home/anhhungproxy"
mkdir -p $WORKDIR
cd $WORKDIR

# Cấu hình IP và Port
IP4=$(curl -4 -s ifconfig.co)
read -p "Nhập subnet IPv6 /48 (ví dụ: 2602:fa81:b): " IP6
read -p "Số lượng proxy cần tạo (đề xuất: 100-500): " PROXY_COUNT
PROXY_COUNT=${PROXY_COUNT:-100}

START_PORT=21000
END_PORT=$((START_PORT + PROXY_COUNT - 1))

echo "IP4: $IP4 | IP6 prefix: $IP6 | Ports: $START_PORT-$END_PORT"

# Tạo và cấu hình
gen_data > data.txt
install_3proxy
gen_3proxy_cfg > /usr/local/etc/3proxy/3proxy.cfg
gen_proxy_txt
gen_network_scripts
create_rotation_script
create_keepalive_script
setup_rc_local
optimize_sysctl
setup_cron

# Khởi chạy
bash $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_iptables.sh
ulimit -n 100000
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg

echo ""
echo "=== CÀI ĐẶT HOÀN TẤT ==="
echo "Proxy đã được tạo: $WORKDIR/proxy.txt"
echo "Số lượng proxy: $(wc -l < $WORKDIR/proxy.txt)"
echo ""
echo "Tính năng chống block:"
echo "- IPv6 rotation tự động mỗi 6 giờ"
echo "- Keepalive traffic mỗi 10 phút"
echo "- Rate limiting: 100 conn/phút/port"
echo "- Bandwidth limit: 200 Mbps tổng, ~2.5MB/s/proxy"
echo ""
cat $WORKDIR/proxy.txt
echo ""
upload_proxy_txt
