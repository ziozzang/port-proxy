#!/bin/bash
##############################################################################
#
# Port-Proxy, V 0.95 (C) 2004 Accordata GmbH,  Ralf Amandi
# Port-Proxy is Perl script to forward ports from the local system to another system.
# Ralf.Amandi@accordata.net
#
# patched & install script by ziozzang
#  - fixed for network disconnect testing
#    (Freezing session which looks like network cable is disconnected)
##############################################################################

PORT_PROXY_PATH=${PORT_PROXY_PATH:-"/usr/bin"}
# Listening Port , Target IP/Host : Target Port | ....
PORT_PROXY_LISTS=${PORT_PROXY_LISTS:-"127.0.0.1:8800,www.daum.net:80|1.2.3.4:8800,www.naver.com:80"}
PORT_PROXY_CONF=${PORT_PROXY_CONF:-"/etc/port-proxy.conf"}

cwds=`cwd`

if [[ -f "/etc/init.d/port-proxy" ]]; then
  service port-proxy stop
fi

wget -O "${PORT_PROXY_PATH}/port-proxy" "https://raw.githubusercontent.com/ziozzang/port-proxy/master/src/port-proxy"
chmod +x port-proxy

sed -i -e "s,\./port-proxy\.conf,${PORT_PROXY_CONF},g" ${PORT_PROXY_PATH}/port-proxy

rm -f ${PORT_PROXY_CONF}
while IFS='|' read -ra ADDR; do
  for i in "${ADDR[@]}"; do
    echo "$i"
    arr=$(echo $i | tr "," "\n")

    cnt=0
    prms=()
    for x in $arr
    do
      prms[ $cnt ]="$x"
      cnt=$(($cnt + 1))
    done
    cat >> ${PORT_PROXY_CONF} <<EOF
forward=${prms[0]},${prms[1]}
allow_proxy_to=${prms[1]}
EOF
  done
done <<< "${PORT_PROXY_LISTS}"

rm -f /etc/init/port-proxy.conf
cat > /etc/init/port-proxy.conf <<EOF
# port-proxy upstart script
# this script will start/stop/restart port-proxy
description "start, stop and restart the port-proxy"
version "0.95-p1"
author "Jioh L. Jung"

start on (local-filesystems and net-device-up IFACE!=lo)
stop on runlevel [016]

# configuration variables
env PORT_PROXY_PATH=${PORT_PROXY_PATH}

respawn

exec ${PORT_PROXY_PATH}/port-proxy >> /var/log/port-proxy.log 2>&1
EOF

rm -f /etc/init.d/port-proxy
cd /etc/init.d
ln -s /lib/init/upstart-job port-proxy

cd ${cwds}

update-rc.d -f port-proxy remove
update-rc.d port-proxy defaults
service port-proxy start


