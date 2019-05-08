#!/bin/bash

# This function checks if a package exists, and if not, will install it
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

# clone the ovs repo and checkout version 2.5
git clone https://github.com/openvswitch/ovs.git /root/ovs
git checkout origin/branch-2.5

# install all the things
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

# start ovs, create a bride which is basically a virtual switch. Bring the bridge interface up
ovs-ctl start
ovs-vsctl add-br br0
ifconfig br0 up

# get a list of wireless networks
a=$(ifconfig | grep ^w.* | awk 'NR==1 {print $1}' | grep -o '\w' | tr -d '\n')
b=$(ifconfig | grep ^w.* | awk 'NR==2 {print $1}' | grep -o '\w' | tr -d '\n')
c=$(ifconfig | grep ^w.* | awk 'NR==3 {print $1}' | grep -o '\w' | tr -d '\n')
# This part just ensures they default to none if their isn't a card for the specified option
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

# get name the user wants for the access point
read -p "Enter a name for the access point: " ssid

# get the ip address for the ODL node
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

# stop wireless service and DNS service so we can edit them without it being messy
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

# specify location of configuration file for hostapd
sed -i 's:#DAEMON_CONF="":DAEMON_CONF="/etc/hostapd/hostapd.conf":' /etc/default/hostapd

# This is for open wifi. Edit this for specific networks... or just plug in ethernet
cat > /root/wpa.conf << EOF
network={
    key_mgmt=NONE
    priority=-999
}
EOF

# connect to the internet (This is to get to the ODL instance)
wpa_supplicant -i wlp2s0 -c wpa.conf -B

# wait for a connection
sleep 5

# pull dhcp or you're just connected to wifi but have no ip.. like plugging into a switch but. no IP.
dhclient wlp2s0

# update dns
sed -i '/nameserver/i \
    nameserver 8.8.8.8' /etc/resolv.conf

# start the access point and the dhcp server
systemctl unmask hostapd
systemctl start hostapd
systemctl start dnsmasq

# set the controller with the specified ip and the default Openflow port
ovs-vsctl set-controller br0 tcp:$IP:6633


