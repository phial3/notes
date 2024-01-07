# Linux 网络虚拟化

[toc]

## Linux 虚拟网络设备



Linux 虚拟网络的背后都是由一个个的虚拟设备构成的。虚拟化技术没出现之前，计算机网络系统都只包含物理的网卡设备，通过网卡适配器，线缆介质，连接外部网络，构成庞大的 Internet。

实现这些功能的基本元素就是虚拟的网络设备，比如 tap/tun 和 veth-pair。



### 1. tap/tun



#### tap/tun 是什么

在 Linux 下，要实现核心态和用户态数据的交互，有多种方式：

- 可以通用 **socket 创建特殊套接字**，利用套接字实现数据交互；
- **通过 proc 文件系统创建文件来进行数据交互**；
- 还可以使用**设备文件**的方式
    - 访问设备文件会调用设备驱动相应的例程，设备驱动本身就是核心态和用户态的一个接口
    - Tun/tap 驱动就是利用设备文件实现用户态和核心态的数据交互。

tun/tap 设备的用处是将协议栈中的部分数据包转发给用户空间的应用程序，给用户空间的程序一个处理数据包的机会。设备最常用的场景是 VPN。

tap/tun 提供了一台主机内用户空间的数据传输机制。它虚拟了一套网络接口，这套接口和物理的接口无任何区别，可以配置 IP，可以路由流量，不同的是，它的流量只在主机内流通。



tun 和 tap 设备的区别：

- **tun 是网络层的虚拟网络设备**，<u>可以收发第三层数据报文包，如IP封包</u>，因此常用于一些**点对点 IP 隧道**，例如 OpenVPN，IPSec 等。
    - 收发的是IP层数据包，无法处理以太网数据帧
- **tap 是链路层的虚拟网络设备**，等同于一个<u>以太网设备，它可以收发第二层数据报文包，如以太网数据帧</u>。Tap 最常见的用途就是做为**虚拟机的网卡**，因为它和普通的物理网卡更加相近，也经常用作普通机器的虚拟网卡。
    - 收发以太网数据帧，拥有MAC层的功能，可以和物理网卡通过网桥相连，组成一个二层网络。
    - 例如 OpenVPN 的桥接模式可以从外部打一条隧道到本地网络。进来的机器就像本地的机器一样参与通讯，丝毫看不出这些机器是在远程。虚拟机的桥接模式也是一种十分常见的网络方案，虚拟机会分配到和宿主机器同网段的IP，其他同网段的机器也可以通过网络访问到这台虚拟机。



#### tap/tun 设备的操作简介



Linux tun/tap可以通过网络接口和字符设备两种方式进行操作：

- 当应用程序使用标准网络接口 socket API 操作 tun/tap 设备时，和操作一个真实网卡无异。
- 当应用程序使用字符设备操作 tun/tap 设备时，字符设备即充当了用户空间和内核空间的桥梁直接读写二层或三层的数据报文。tun/tap 对应的字符设备文件分别为：
    - `tun：/dev/net/tun`
    - `tap：/dev/tap0`

操作字符设备文件时：

- 当应用程序打开字符设备时，系统会自动创建对应的虚拟设备接口，一般以tunX和tapX方式命名
- 虚拟设备接口创建成功后，可以为其配置IP、MAC地址、路由等。
- 当一切配置完毕，应用程序通过此字符文件设备写入IP封包或以太网数据帧
- tun/tap的驱动程序会将数据报文直接发送到内核空间，内核空间收到数据后再交给系统的网络协议栈进行处理，最后网络协议栈选择合适的物理网卡将其发出，到此发送流程完成。
- 物理网卡收到数据报文时会交给网络协议栈进行处理，网络协议栈匹配判断之后通过tun/tap的驱动程序将数据报文原封不动的写入到字符设备上
- 应用程序从字符设备上读取到IP封包或以太网数据帧，最后进行相应的处理，收取流程完成。



#### tap/tun 设备的操作命令

操作 tap/tun 设备：

- `ip tuntap ...` 命令



示例：

1. 创建/删除 tap 设备：

```shell
# 创建 tap 
ip tuntap add dev tap0 mode tap 
# 创建 tun
ip tuntap add dev tun0 mode tun 

# 删除 tap
ip tuntap del dev tap0 mode tap
# 删除 tun
ip tuntap del dev tun0 mode tun 
```



查看创建的设备：

```shell
root@ubuntu:~# ifconfig -a
......
tap0: flags=4098<BROADCAST,MULTICAST>  mtu 1500
        ether ea:4b:85:47:c0:58  txqueuelen 1000  (Ethernet)
        RX packets 0  bytes 0 (0.0 B)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 0  bytes 0 (0.0 B)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0

```



2. 创建好 tun/tap 设备后，就可以当作普通的网卡一样使用，下面配置网卡的 ip

```shell
root@ubuntu:~# ifconfig tap0 192.168.44.251 netmask 255.255.255.0 promisc
tap0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 192.168.44.251  netmask 255.255.255.0  broadcast 192.168.44.255
        inet6 fe80::20c:29ff:fecd:b183  prefixlen 64  scopeid 0x20<link>
        ether ea:4b:85:47:c0:58  txqueuelen 1000  (Ethernet)
        RX packets 0  bytes 0 (0.0 B)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 0  bytes 0 (0.0 B)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0
```



配置完后，可以直接ping通



### 2. veth pair

#### veth pair 是什么

`VETH(Virtual Ethernet)`是Linux提供的另外一种特殊的网络设备，中文称为`虚拟网卡`接口。它总是成对出现，要创建就创建一个pair。

一个Pair中的veth就像一个网络线缆的两个端点，数据从一个端点进入，必然从另外一个端点流出。每个veth都可以被赋予IP地址，并参与三层网络路由过程，可以实现不同netns之间网络通信。



veth-pair 是一对的虚拟设备接口，和 tap/tun 设备不同的是，它都是成对出现的。一端连着协议栈，一端彼此相连。



veth-pair 是成对出现的一种虚拟网络设备，一端连接着协议栈，一端连接着彼此，数据从一端出，从另一端进。

它的这个特性常常用来连接不同的虚拟网络组件，构建大规模的虚拟网络拓扑，比如连接 Linux Bridge、OVS、LXC 容器等。

一个很常见的案例就是它被用于 OpenStack Neutron，构建非常复杂的网络形态。



**veth设备的特点**

- veth 和其它的网络设备都一样，一端连接的是`内核协议栈`。
- veth 设备是`成对`出现的，另一端两个设备彼此相连。
- 一个设备`收到协议栈`的数据发送请求后，会将数据发送到另一个设备上去。



后面会有详细的实例操作 veth pair 设备。



#### veth 设备操作命令

1. 创建 veth pair 设备（一对）: `ip link add [VETH_NAME] type veth peer name [VETH_PEER_NAME]`

```shell
dev@debian:~$ sudo ip link add veth0 type veth peer name veth1
```



2. 给对应的 veth pair 设备配置 ip 等信息

```shell
# 配置 ip 和子网
dev@debian:~$ sudo ip addr add 192.168.3.101/24 dev veth0
dev@debian:~$ sudo ip addr add 192.168.3.102/24 dev veth1

# 配置相应的 veth 设备启动
dev@debian:~$ sudo ip link set veth0 up
dev@debian:~$ sudo ip link set veth1 up

```

3. 删除 veth 设备：`ip link delete [VETH_NAME] type veth`

```shell
dev@debian:~$ sudo ip link delete veth0 type veth
```

veth pair 无法单独存在，删除其中一个，另一个也会自动消失。



## Linux Bridge

### 简介

Linux Bridge（网桥）是用纯软件实现的虚拟交换机，有着和物理交换机相同的功能，例如二层交换，MAC地址学习等。因此我们可以把tun/tap，veth pair等设备绑定到网桥上，就像是把设备连接到物理交换机上一样。此外它和veth pair、tun/tap一样，也是一种虚拟网络设备，具有虚拟设备的所有特性，例如配置IP，MAC地址等。



Linux Bridge通常是搭配KVM、docker等虚拟化技术一起使用的，用于构建虚拟网络，因为此教程不涉及虚拟化技术，我们就使用前面学习过的netns来模拟虚拟设备。



### 操作



Linux 操作网桥有多种方式，介绍一下通过**bridge-utils**来操作，由于它不是Linux系统自带的工具，因此需要我们手动来安装它。

```shell
# centos
yum install -y bridge-utils
# ubuntu
apt-get install -y bridge-utils
```



brctl 命令的所有子命令有：

```shell
root@ubuntu:~# brctl -h
Usage: brctl [commands]
commands:
        addbr           <bridge>                add bridge
        delbr           <bridge>                delete bridge
        addif           <bridge> <device>       add interface to bridge
        delif           <bridge> <device>       delete interface from bridge
        hairpin         <bridge> <port> {on|off}        turn hairpin on/off
        setageing       <bridge> <time>         set ageing time
        setbridgeprio   <bridge> <prio>         set bridge priority
        setfd           <bridge> <time>         set bridge forward delay
        sethello        <bridge> <time>         set hello time
        setmaxage       <bridge> <time>         set max message age
        setpathcost     <bridge> <port> <cost>  set path cost
        setportprio     <bridge> <port> <prio>  set port priority
        show            [ <bridge> ]            show a list of bridges
        showmacs        <bridge>                show a list of mac addrs
        showstp         <bridge>                show bridge stp info
        stp             <bridge> {on|off}       turn stp on/off

```



常用命令如

1. 新建一个网桥：

```shell
brctl addbr <bridge>
```

2. 添加一个设备（例如eth0）到网桥：

```shell
brctl addif <bridge> eth0
```

3. 显示当前存在的网桥及其所连接的网络端口：

```shell
brctl show
```

4. 启动网桥：

```shell
ip link set <bridge> up
```

5. 删除网桥，需要先关闭它：

```shell
ip link set <bridge> downbrctl delbr <bridge>
```

6. 或者使用ip link del 命令直接删除网桥

```shell
ip link del <bridge>
```





## Linux Network Namespace

### 简介



Namespace：是 Linux 提供的一种内核级别环境隔离的方法。不同命名空间下的资源集合无法互相访问。

network namespace 是实现网络虚拟化的重要功能，它能创建多个隔离的网络空间，它们有独自的网络栈信息。不管是虚拟机还是容器，运行的时候仿佛自己就在独立的网络中。



### 操作

操作 network namespace 可以使用 `ip netns` 命令。

```shell
root@ubuntu:~# ip netns help
Usage:  ip netns list
        ip netns add NAME
        ip netns attach NAME PID
        ip netns set NAME NETNSID
        ip [-all] netns delete [NAME]
        ip netns identify [PID]
        ip netns pids NAME
        ip [-all] netns exec [NAME] cmd ...
        ip netns monitor
        ip netns list-id [target-nsid POSITIVE-INT] [nsid POSITIVE-INT]
NETNSID := auto | POSITIVE-INT
```



1. 创建 network namespace: `ip netns add xxx`

```shell
# 创建名为 ns1 的 network namespace
root@ubuntu:~# ip netns add ns1
root@ubuntu:~# ip netns list
ns1
```



`ip netns` 命令创建的 network namespace 会出现在 `/var/run/netns/` 目录下，如果需要管理其他不是 `ip netns` 创建的 network namespace，只要在这个目录下创建一个指向对应 network namespace 文件的链接就行。

```shell
root@ubuntu:~# cd /var/run/netns/
root@ubuntu:/var/run/netns# ls
ns1
```



有了自己创建的 network namespace，我们还需要看看它里面有哪些东西。**对于每个 network namespace 来说，它会有自己独立的网卡、路由表、ARP 表、iptables 等和网络相关的资源**。





2. 在对应的 network namespace 中执行命令：`ip netns exec [NS_NAME] [COMMAND]`

```shell
# 在 ns1 namespace 下执行 ip addr 命令
root@ubuntu:~# ip netns exec ns1 ip addr
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00

```



同样也可以在指定的namespace下打开一个新的终端，在终端中执行命令（相当于在对应的namespace下执行命令）：

```shell
root@ubuntu:~# ip netns exec ns1 bash
root@ubuntu:~# ip addr
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00

# 上面的 bash 不好区分到底是在哪个 namespace 下，可以使用：
root@ubuntu:~# ip netns exec ns1 /bin/bash --rcfile <(echo "PS1=\"namespace ns1> \"")
namespace ns1> ip addr
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
```

每个 namespace 在创建的时候会自动创建一个 `lo` 的 interface，它的作用和 linux 系统中默认看到的 `lo` 一样，都是为了实现 loopback 通信。如果希望 `lo` 能工作，不要忘记启用它：

```shell
root@ubuntu:~# ip netns exec ns1 ip link set lo up
root@ubuntu:~# ip netns exec ns1 ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host
       valid_lft forever preferred_lft forever

```



默认情况下，network namespace 是不能和主机网络，或者其他 network namespace 通信的。



3. 将某个设备添加到对应的 network namespace 中：`ip link set [DEVICE_NAME] netns [NAMESPACE_NAME]`

```shell
root@ubuntu:~# ip link set veth0 netns net0
```











## 操作实例

### 示例: 两个 Network Namespace 直接相连

直接相连是最简单的方式，一对 veth-pair 直接将两个 namespace 连接在一起。



1. 创建两个 network namespace

```shell
root@ubuntu:~# ip netns add ns1
root@ubuntu:~# ip netns add ns2
root@ubuntu:~# ip netns list
ns2
ns1

```

2. 创建一对 veth pair 设备，名为 veth0 和 veth1

```shell
root@ubuntu:~# ip link add veth0 type veth peer name veth1
root@ubuntu:~# ip link list
....
12: veth1@veth0: <BROADCAST,MULTICAST,M-DOWN> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000
    link/ether ca:3c:c0:e6:52:0e brd ff:ff:ff:ff:ff:ff
13: veth0@veth1: <BROADCAST,MULTICAST,M-DOWN> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000
    link/ether 96:96:1e:21:d9:ea brd ff:ff:ff:ff:ff:ff
```

3. 将新建的一对 veth pair 设备，设备 veth0 添加到 ns1，veth1 添加到 ns2 中

```shell
root@ubuntu:~# ip link set veth0 netns ns1
root@ubuntu:~# ip netns exec ns1 ip addr
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
13: veth0@if12: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN group default qlen 1000
    link/ether 96:96:1e:21:d9:ea brd ff:ff:ff:ff:ff:ff link-netns ns2
root@ubuntu:~# ip link set veth1 netns ns2
root@ubuntu:~# ip netns exec ns2 ip addr
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
12: veth1@if13: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN group default qlen 1000
    link/ether ca:3c:c0:e6:52:0e brd ff:ff:ff:ff:ff:ff link-netns ns1
```

4. 给两个 veth0 veth1 配上 IP 并启用

```shell
root@ubuntu:~# ip netns exec ns1 ip address add 100.1.1.10/24 dev veth0
root@ubuntu:~# ip netns exec ns1 ip link set veth0 up
root@ubuntu:~# ip netns exec ns1 ip addr
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
13: veth0@if12: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state LOWERLAYERDOWN group default qlen 1000
    link/ether 96:96:1e:21:d9:ea brd ff:ff:ff:ff:ff:ff link-netns ns2
    inet 100.1.1.10/24 scope global veth0
       valid_lft forever preferred_lft forever


root@ubuntu:~# ip netns exec ns2 ip address add 100.1.1.11/24 dev veth1
root@ubuntu:~# ip netns exec ns2 ip link set veth1 up
root@ubuntu:~# ip netns exec ns2 ip addr
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
12: veth1@if13: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether ca:3c:c0:e6:52:0e brd ff:ff:ff:ff:ff:ff link-netns ns1
    inet 100.1.1.11/24 scope global veth1
       valid_lft forever preferred_lft forever
    inet6 fe80::c83c:c0ff:fee6:520e/64 scope link
       valid_lft forever preferred_lft forever
```



5. 测试 veth0 与 veth1 连通性

```shell
root@ubuntu:~# ip netns exec ns1 ping 100.1.1.11
PING 100.1.1.11 (100.1.1.11) 56(84) bytes of data.
64 bytes from 100.1.1.11: icmp_seq=1 ttl=64 time=0.048 ms
64 bytes from 100.1.1.11: icmp_seq=2 ttl=64 time=0.093 ms
^C
--- 100.1.1.11 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1011ms
rtt min/avg/max/mdev = 0.048/0.070/0.093/0.022 ms


root@ubuntu:~# ip netns exec ns2 ping 100.1.1.10
PING 100.1.1.10 (100.1.1.10) 56(84) bytes of data.
64 bytes from 100.1.1.10: icmp_seq=1 ttl=64 time=0.026 ms
64 bytes from 100.1.1.10: icmp_seq=2 ttl=64 time=0.096 ms
^C
--- 100.1.1.10 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1006ms
rtt min/avg/max/mdev = 0.026/0.061/0.096/0.035 ms
```



### 示例: 两个 Network Namespace 通过 Bridge 相连

Linux Bridge 相当于一台交换机，可以中转两个 namespace 的流量，将两个 network namespace 的两对 veth 设备都连到同一个 交换机 bridge 上。

1. 创建两个 network namespace

```shell
root@ubuntu:~# ip netns add ns2
root@ubuntu:~# ip netns list
ns2
ns1
```

2. 创建一个 Linux bridge 网桥设备,并且开启设备

```shell
root@ubuntu:~# ip link add br-gsh type bridge
root@ubuntu:~# ip link set br-gsh up
root@ubuntu:~# ip link show type bridge
3: docker0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default
    link/ether 02:42:cb:79:08:4f brd ff:ff:ff:ff:ff:ff
14: br-gsh: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default qlen 1000
    link/ether b2:5b:67:d0:04:af brd ff:ff:ff:ff:ff:ff
```

3. 创建两队 veth 设备，分别是：
    - veth0 - br-veth0
    - veth1 - br-veth1

```shell
root@ubuntu:~# ip link add veth0 type veth peer name br-veth0
root@ubuntu:~# ip link add veth1 type veth peer name br-veth1
root@ubuntu:~# ip link list type veth
15: br-veth0@veth0: <BROADCAST,MULTICAST,M-DOWN> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000
    link/ether aa:67:77:a1:60:b0 brd ff:ff:ff:ff:ff:ff
16: veth0@br-veth0: <BROADCAST,MULTICAST,M-DOWN> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000
    link/ether 96:96:1e:21:d9:ea brd ff:ff:ff:ff:ff:ff
17: br-veth1@veth1: <BROADCAST,MULTICAST,M-DOWN> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000
    link/ether f2:b4:65:14:34:06 brd ff:ff:ff:ff:ff:ff
18: veth1@br-veth1: <BROADCAST,MULTICAST,M-DOWN> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000
    link/ether ca:3c:c0:e6:52:0e brd ff:ff:ff:ff:ff:ff
```

4. 分别将两对 veth-pair 加入两个 ns 和 br0，并启动 veth 设备
    - veth0 连接 ns1，br-veth0 连接网桥 br-gsh
    - veth1 连接 ns2，br-veth1 连接网桥 br-gsh

```shell
# 添加到两个 ns 中,并启动 veth 设备
root@ubuntu:~# ip link set veth0 netns ns1
root@ubuntu:~# ip netns exec ns1 ip link set veth0 up
root@ubuntu:~# ip netns exec ns1 ip addr
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
16: veth0@if15: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state LOWERLAYERDOWN group default qlen 1000
    link/ether 96:96:1e:21:d9:ea brd ff:ff:ff:ff:ff:ff link-netnsid 0
    
root@ubuntu:~# ip link set veth1 netns ns2
root@ubuntu:~# ip netns exec ns2 ip link set veth1 up
root@ubuntu:~# ip netns exec ns2 ip addr
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
18: veth1@if17: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state LOWERLAYERDOWN group default qlen 1000
    link/ether ca:3c:c0:e6:52:0e brd ff:ff:ff:ff:ff:ff link-netnsid 0
    
    
# 将 br-vethx 连接到网桥，并且启动
root@ubuntu:~# ip link set br-veth0 master br-gsh
root@ubuntu:~# ip link set br-veth1 master br-gsh
root@ubuntu:~# ip link set br-veth0 up
root@ubuntu:~# ip link set br-veth1 up
root@ubuntu:~# brctl show
bridge name     bridge id               STP enabled     interfaces
br-gsh          8000.b25b67d004af       no              br-veth0
                                                        br-veth1
docker0         8000.0242cb79084f       no              veth09ad58b
```

5. 给两个 ns 中的 veth 配置 IP 并启用

```shell
root@ubuntu:~# ip netns exec ns1 ip address add 100.1.1.10/24 dev veth0
root@ubuntu:~# ip netns exec ns1 ip addr
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
16: veth0@if15: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 96:96:1e:21:d9:ea brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 100.1.1.10/24 scope global veth0
       valid_lft forever preferred_lft forever
    inet6 fe80::9496:1eff:fe21:d9ea/64 scope link
       valid_lft forever preferred_lft forever
root@ubuntu:~# ip netns exec ns2 ip address add 100.1.1.11/24 dev veth1
root@ubuntu:~# ip netns exec ns2 ip addr
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
18: veth1@if17: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether ca:3c:c0:e6:52:0e brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 100.1.1.11/24 scope global veth1
       valid_lft forever preferred_lft forever
    inet6 fe80::c83c:c0ff:fee6:520e/64 scope link
       valid_lft forever preferred_lft forever
```

6. 测试两个 network namespace 的连通性

这样之后，竟然通不了，是因为

> 原因是因为系统为bridge开启了iptables功能，导致所有经过br0的数据包都要受iptables里面规则的限制，而docker为了安全性（我的系统安装了 docker），将iptables里面filter表的FORWARD链的默认策略设置成了drop，于是所有不符合docker规则的数据包都不会被forward，导致你这种情况ping不通。
>
> 解决办法有两个，二选一：
>
> 1. 关闭系统bridge的iptables功能，这样数据包转发就不受iptables影响了：echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables
> 2. 为br0添加一条iptables规则，让经过br0的包能被forward：iptables -A FORWARD -i br0 -j ACCEPT
>
> 第一种方法不确定会不会影响docker，建议用第二种方法。



