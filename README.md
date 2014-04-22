port-proxy
==========

port-proxy with service install


original source from "Accordata Port-Proxy V0.95"
http://www.accordata.net/downloads/port-proxy/


Install
=======

* run install.sh script. this script automatically generate upstart script for service.
* set /etc/port-proxy.conf
* service port-proxy restart


```
# listening port or port with binding ip , destination
export PORT_PROXY_LISTS="80,localhost:8080|127.0.0.1:82,www.naver.com:80"
wget -qO- https://raw.githubusercontent.com/ziozzang/port-proxy/master/src/install.sh | bash

```


Configuration
=============


All the configuration is done in the file port-proxy.conf, which is readed from the current directory when starting port-proxy

There are the following parameters which can apear multiple times:

**forward=local addr,destination addr,[proxy 1],[proxy 2]**

* local addr : Define where port-proxy listen for connections.
It can be either a port or an address with port (eg. 127.0.0.1:8080; localhost:8080)
Without an address your system listens on all interfaces, also an dialup line.
* destination addr	: Defines the destination as addr:port (eg. 192.168.0.1:80 or remotehost.com:80)
Please note: If you use an proxy, this address is from the view of the proxy. If you use localhost or 127.0.0.1 it addresses the proxy host.
If you enter the special address [PROXY], port-proxy behave like an https proxy an reads the destination from the connecting client.
* proxy 1	 Defines an https proxy to use.
* proxy 2	 Defines an 2nd https proxy to use. This is usally port-proxy listening an port 443

**allow_proxy_to=addr**

Defines which destinations are allowed if you use [PROXY] as destination.

Addr is executed with perl regex and my be something like this:

```
allow_proxy_to=localhost:23	# allow telnet
allow_proxy_to=192.168..*:80	# http to all 192.168.x.x
```

**Example 1: Port forwarding**

Task: Allow access to a service on a know host

```[client] --- [proxy] --- [remote]```

Your client has no access to [remote], but has access to [proxy], To fetch mail from [remote], you may configure on [proxy]:

```forward=110,remote.com:110```

Your client connects to [proxy] an port 110 an fetches mail from remote.com.


**Example 2: Port forwarding with https tunnel**

Task: Your client want to telnet to a know host, but is behind an firewall with only access to an https proxy. 
Configuration on Client (not working): 

```forward=localhost:9023,remote.com:23,https-proxy:8080```

Since most proxys allow only connection to port 443 you don't has access to remote.com:23.
To get it work, you need to setup telnet on port 443 at remote.com:

* Insert in inetd.conf of remote.com: ```443 stream tcp nowait root /usr/sbin/tcpd in.telnetd```
* Use configuration: ```forward=localhost:9023,remote.com:443,https-proxy:8080```
* On your client use: ```telnet localhost 9023```

Another disadvantage is that you only can configure one service on port 443.

**Example 3: Port forwarding with https tunnel and an special proxy to access individual remote addesses**

```[client] --- [https-proxy] --- [remote host proxy:443] -- [remote service]```
To cover the problems noted above, port-proxy can behave like an proxy listening an port 443 and forward to your needed service.

You need to run port-proxy on [client] and [remote]
port-proxy.conf on your client (telnet example):

```forward=localhost:9023,localhost:23,https-proxy:8080,remote.com:443```
(Note: 'localhost:23' is from the view of remote.com. Therefore it addresses telnet on remote.com)

port-proxy.conf on remote.com:
```
forward=443,[PROXY]	 # Listen on port 443 and behave like an https proxy
allow_proxy_to=localhost:23	# telnet
```

Connection flow:

* On client: telnet localhost:9023
* port-proxy connects to https-proxy:8080
* https-proxy connects to remote.com:443
* port-proxy an remote.com connects localhost:23 (telnet)

Running port-proxy
==================

```
perl port-proxy [-d] [-D] [-c conffile]
-d	 Enable debug output
-D	 Become a background process (detach don't work on windows)
-c conffile	 Specify an config file
```

**Example:**

```
/usr/bin/port-proxy -D -c /etc/port-proxy.conf
```

License
=======

This script is published 'as is', without warrenty or support.

You are allowed to use and distribut without changes If you distribute modified version, you must not remove the copyright or author information.

You should document the changes and may add your copyright for that parts.

If you use parts in your software, you should honor our work somewhere in your documentation.
