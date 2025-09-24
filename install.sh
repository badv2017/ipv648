#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

gen48() {
    printf "$1:%x:%x:%x:%x:%x\n" \
    $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) \
    $((RANDOM%65536)) $((RANDOM%65536))
}

install_3proxy() {
    echo "Installing 3proxy..."
    URL="https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.4.tar.gz"
    wget -qO- $URL | tar -xz
    cd 3proxy-0.9.4
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd ..
}

gen_3proxy_cfg() {
    cat <<EOF
daemon
maxconn 1000
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

setup_systemd_service() {
    cat <<EOF > /etc/systemd/system/3proxy.service
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
LimitNOFILE=100000
ExecStartPre=/bin/bash $WORKDIR/boot_ifconfig.sh
ExecStartPre=/bin/bash $WORKDIR/boot_iptables.sh
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now 3proxy
}

upload_proxy_txt() {
    curl -F "file=@$WORKDIR/proxy.txt" https://file.io
}

### MAIN ###
dnf install -y gcc make wget net-tools curl bsdtar zip iptables-nft

WORKDIR="/home/anhhungproxy"
mkdir -p $WORKDIR
cd $WORKDIR

IP4=$(curl -4 -s ifconfig.co)
read -p "Nhập subnet IPv6 /48 (ví dụ: 2602:fa81:b): " IP6
START_PORT=21000
END_PORT=21999

echo "IP4: $IP4 | IP6 prefix: $IP6"
gen_data > data.txt
install_3proxy
gen_3proxy_cfg > /usr/local/etc/3proxy/3proxy.cfg
gen_proxy_txt
gen_network_scripts
setup_systemd_service

echo "Proxy đã tạo xong. File proxy.txt:"
cat $WORKDIR/proxy.txt
upload_proxy_txt
