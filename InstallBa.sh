#!/bin/bash
# =================================================
# 3Proxy + IPv6 Keepalive Optimized Script 2025
# =================================================

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

WORKDIR="/home/anhhungproxy"
mkdir -p $WORKDIR && cd $WORKDIR

# -------------------------
# Cài công cụ cần thiết
# -------------------------
yum install -y gcc make wget net-tools curl zip nmap-ncat iproute iptables >/dev/null

# -------------------------
# Nhập IP4 và IPv6 /48
# -------------------------
IP4=$(curl -4 -s ifconfig.co)
read -p "Nhập IPv6 /48 prefix (ví dụ 2602:fd92:200): " IPV6_PREFIX
START_PORT=21000
END_PORT=21999
NUM_PROXY=1000   # số lượng proxy

echo "IPv4: $IP4 | IPv6 /48: $IPV6_PREFIX"

# -------------------------
# Sinh dữ liệu proxy
# -------------------------
random_pass() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c5
}

# Sinh IPv6 random trong /64 (subnet được gán)
gen_ipv6() {
    printf "%s:%x:%x:%x:%x\n" "$1" $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))
}

# Tạo data.txt
> $WORKDIR/data.txt
for ((i=0;i<$NUM_PROXY;i++)); do
    port=$((START_PORT+i))
    user="user$port"
    pass=$(random_pass)
    ipv6=$(gen_ipv6 "$IPV6_PREFIX")
    echo "$user/$pass/$IP4/$port/$ipv6" >> data.txt
done

# -------------------------
# Cài 3proxy
# -------------------------
install_3proxy() {
    echo "Installing 3proxy..."
    URL="https://github.com/z3APA3A/3proxy/archive/3proxy-0.8.6.tar.gz"
    wget -qO- $URL | tar -xz
    cd 3proxy-3proxy-0.8.6
    make -f Makefile.Linux >/dev/null
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd ..
}
install_3proxy

# -------------------------
# Tạo file proxy.txt cho client
# -------------------------
awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' $WORKDIR/data.txt > $WORKDIR/proxy.txt

# -------------------------
# Tạo 3proxy.cfg
# -------------------------
cat <<EOF > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush

auth strong
users $(awk -F "/" '{print $1":CL:"$2}' $WORKDIR/data.txt | paste -sd " ")

$(awk -F "/" '{print "allow " $1 "\nproxy -6 -n -a -i"$3" -e"$5" -p"$4}' $WORKDIR/data.txt)
EOF

# -------------------------
# Gán IPv6 /64 vào interface
# -------------------------
# Xóa IPv6 cũ
ip -6 addr flush dev eth0
ip -6 addr add ${IPV6_PREFIX}::/64 dev eth0

# -------------------------
# Firewall
# -------------------------
for port in $(seq $START_PORT $END_PORT); do
    iptables -I INPUT -p tcp --dport $port -j ACCEPT
done

# -------------------------
# Tạo systemd keepalive
# -------------------------
cat << 'EOF' > /root/ipv6_keepalive.sh
#!/bin/bash
PORT_START=21000
PORT_END=21999
while true; do
    for port in $(seq $PORT_START $PORT_END); do
        nc -6 -z -w 1 ::1 $port >/dev/null 2>&1
    done
    sleep 20
done
EOF
chmod +x /root/ipv6_keepalive.sh

cat <<EOF > /etc/systemd/system/ipv6_keepalive.service
[Unit]
Description=IPv6 Keep Alive Service
After=network.target

[Service]
ExecStart=/bin/bash /root/ipv6_keepalive.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ipv6_keepalive
systemctl restart ipv6_keepalive

# -------------------------
# Chạy 3proxy
# -------------------------
ulimit -n 200000
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &

echo "=============================="
echo "Proxy đã tạo xong. proxy.txt:"
cat $WORKDIR/proxy.txt
echo "=============================="
