#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

### === FUNCTION ZONE === ###

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c8
}

gen48() {
    # sinh IPv6 hợp lệ trong /48 (chống bị flag)
    printf "%s:%x:%x:%x:%x\n" "$1" \
        $((RANDOM % 65536)) \
        $((RANDOM % 65536)) \
        $((RANDOM % 65536)) \
        $((RANDOM % 65536))
}

install_3proxy() {
    echo "Installing 3proxy..."
    URL="https://github.com/z3APA3A/3proxy/archive/3proxy-0.8.6.tar.gz"
    wget -qO- $URL | tar -xz
    cd 3proxy-3proxy-0.8.6
    make -f Makefile.Linux >/dev/null 2>&1
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd ..
}

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
flush

auth strong
users $(awk -F "/" '{print $1":CL:"$2}' $WORKDIR/data.txt | paste -sd " ")

$(awk -F "/" '{print "allow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\n"}' $WORKDIR/data.txt)
EOF
}

gen_proxy_txt() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' $WORKDIR/data.txt > $WORKDIR/proxy.txt
}

gen_data() {
    seq $START_PORT $END_PORT | while read port; do
        echo "user$port/$(random)/$IP4/$port/$(gen48 $IP6)"
    done
}

gen_network_scripts() {
    awk -F "/" '{print "ip -6 addr add "$5"/64 dev eth0"}' $WORKDIR/data.txt > $WORKDIR/boot_ifconfig.sh
    awk -F "/" '{print "iptables -I INPUT -p tcp --dport "$4" -j ACCEPT"}' $WORKDIR/data.txt > $WORKDIR/boot_iptables.sh
    chmod +x $WORKDIR/boot_*.sh
}

create_keepalive_service() {

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
}

### === MAIN SCRIPT === ###

yum install -y gcc make wget net-tools curl zip nmap-ncat >/dev/null

WORKDIR="/home/anhhungproxy"
mkdir -p $WORKDIR && cd $WORKDIR

IP4=$(curl -4 -s ifconfig.co)
read -p "Nhập subnet IPv6 /48 (ví dụ 2602:fa81:b): " IP6

START_PORT=21000
END_PORT=21999

echo "IP4: $IP4 | IPv6 prefix: $IP6"

gen_data > data.txt
install_3proxy
gen_3proxy_cfg > /usr/local/etc/3proxy/3proxy.cfg
gen_proxy_txt
gen_network_scripts
create_keepalive_service

bash $WORKDIR/boot_ifconfig.sh
bash $WORKDIR/boot_iptables.sh
ulimit -n 200000
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &

echo "Proxy đã tạo xong!"
echo "---- proxy.txt ----"
cat $WORKDIR/proxy.txt
