#!/bin/bash

packageExists () {
    if [ $(dpkg-query -W -f='${Status}' $1 2>/dev/null | grep -c "ok installed") -eq 0 ]
    then
        apt install -y $1;
    fi
}

# update apt package list
apt update

# check each package and install if it doesn't exist.
# use git for the right version of 
packageExists git
git clone https://github.com/openvswitch/ovs.git /root/ovs
git checkout origin/branch-2.5

packageExists net-tools
packageExists libcap-ng-dev
packageExists libunbound-dev
packageExists autoconf 
packageExists automake 
packageExists libtool
packageExists python-pyftpdlib 
packageExists netcat 
packageExists curl 
packageExists python-tftpy
packageExists build-essential
packageExists hostapd
packageExists dnsmasq

# works up to this point

# ovs package comes with executable boot.sh
# make preparations for installation, then install
cd /root/ovs/
./boot.sh
./configure
make
make install

# export the path so the binaries can be executed
export PATH=$PATH:/usr/local/share/openvswitch/scripts
# make the PATH change permanent
echo "export PATH=$PATH:/usr/local/share/openvswitch/scripts" >> ~/.bashrc

ovs-ctl start
ovs-vsctl add-br br0
ifconfig br0 up

# get a list of wireless networks
a=$(ifconfig | grep ^w.* | awk 'NR==1 {print $1}' | grep -o '\w' | tr -d '\n')
b=$(ifconfig | grep ^w.* | awk 'NR==2 {print $1}' | grep -o '\w' | tr -d '\n')
c=$(ifconfig | grep ^w.* | awk 'NR==3 {print $1}' | grep -o '\w' | tr -d '\n')
a=${a:-none}
b=${b:-none}
c=${c:-none}

# give the user the option to choose the interface they will use
choiceOkay=0
while [ $choiceOkay != 1 ]
do
    echo -n "Choose the interface that will be used as an access point to the SDN network:"
    printf "\na:$a\nb:$b\nc:$c\n"
    read choice
    if [ $choice != 'a' ] && [ $choice != 'b' ] && [ $choice != 'c' ]
    then
        echo "ERROR please enter one of the available options"
    else
        choiceOkay=1
    fi
done

# add an interface to the switch as a port
ovs-vsctl add-port br0 ${!choice}
read -p "Enter a name for the access point: " ssid
read -p "Enter the ip address of the cloud ODL node: " IP

#choiceOkay=0
#while [ $choiceOkay != 1 ]
#do
#    echo -n "Choose the interface that will connect to the internet and provide access to the controller:"
#    printf "\na:$a\nb:$b\nc:$c"
#    read choice
#    if [ $choice != 'a' ] && [ $choice != 'b' ] && [ $choice != 'c' ]
#    then
#        echo "ERROR please enter one of the available options"
#    else
#        choiceOkay=1
#    fi
#done

ovs-vsctl add-br br0 # add the bridge, or switch
ovs-vsctl add-port br0 ${!choice} # add the chosen interface to the bridge

systemctl stop wpa_supplicant
systemctl stop systemd-resolved


# configure the static ip
cat >> /etc/dhcpcd.conf << EOF
interface ${!choice}
static ip_address=192.168.3.254/24
denyinterfaces ${!choice}
EOF

# configure the dhcp server
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
cat >> /etc/dnsmasq.conf << EOF
interface=${!choice}
dhcp-range=192.168.3.1,192.168.3.20,255.255.255.0,24h
EOF

# configure open network
cat > /etc/hostapd/hostapd.conf << EOF
interface=${!choice}
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
ignore_broadcast_ssid=0
ssid=$ssid
EOF

# specify location of configure
sed -i 's:#DAEMON_CONF="":DAEMON_CONF="/etc/hostapd/hostapd.conf":' /etc/default/hostapd

cat > /root/wpa.conf << EOF
network={
    key_mgmt=NONE
    priority=-999
}
EOF

wpa_supplicant -i wlp2s0 -c wpa.conf -B
sleep 5
dhclient wlp2s0
# update dns
sed -i '/nameserver/i \
    nameserver 8.8.8.8' /etc/resolv.conf

systemctl unmask hostapd
systemctl start hostapd
systemctl start dnsmasq

ovs-vsctl set-controller br0 tcp:$IP:6633


