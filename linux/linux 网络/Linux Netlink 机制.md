# Linux Netlink 机制详解

[toc]



## 概述



现今，计算机之间的通信，最流行的TCP/IP协议。同一计算机之间的进程之间通信，经典方式是`系统调用`、`/sys`、`/proc`等，但是这些方式几乎都是用户空间主动向内核通信，而内核不能主动与用户空间通信；另外，这些方式实现起来不方便，扩展难，尤其是系统调用（内核会保持系统调用尽可能少————Linux一旦为某个系统调用分配了一个系统调用号后，就永远为它分配而不再改变，哪怕此系统调用不再使用，其相对应的系统调用号也不可再使用）。

为此，Linux首次提出了**`Netlink`机制**（现在已经以RFC形式提出国际标准），它**基于 Socket**，可以解决上述问题：**用户空间可以主动向内核发送消息，内核既也可以主动向用户空间发送消息**，而且 Netlink 的扩展也十分方便，只需要以模块的方式向内核注册一下协议或Family（这是对于`Generic Netlink`而言）即可，不会污染内核，也不会过多的增加系统调用接口。

如果想要理解本文或 Netlink 机制， 可能需要明白 Linux 对 Socket 体系的实现方式（或者说是TCP/IP协议），比如：

- 地址家族（Address Family）：即协议域，又称为协议族（family）。表示套接字的协议域（或地址族），指定了套接字通信所使用的协议类型。常见的协议族包括：
  - AF_INET(IPV4)
  - AF_INET6(IPV6)
  - AF_LOCAL（或称AF_UNIX，Unix域socket）
  - AF_ROUTE
  - AF_PACKET：用于原始网络数据包通信
  - ......
- socket类型（Socket Type）：表示套接字的类型，指定了套接字的通信语义和数据传输方式。常见的套接字类型包括：
  - SOCK_STREAM：流套接字（面向连接），提供可靠的、基于字节流的、全双工的数据传输。
  - SOCK_DGRAM：数据报套接字（无连接），提供不可靠的、无连接的、固定最大长度的数据传输。
  - SOCK_RAW：原始套接字，用于直接访问底层网络协议，通常需要特权权限。
- 协议（Protocol）：表示套接字使用的具体协议。在大多数情况下，可以将此参数设置为 0，表示使用默认协议。
  - 例如，对于 AF_INET 和 SOCK_STREAM 类型的套接字，通常使用 TCP 协议，对于 AF_INET 和 SOCK_DGRAM 类型的套接字，通常使用 UDP 协议
  - IPPROTO_TCP、IPPTOTO_UDP、IPPROTO_SCTP、IPPROTO_TIPC等，它们分别对应TCP传输协议、UDP传输协议、STCP传输协议、TIPC传输协议



### Open a Socket





Netlink是一种`Address Family`，同`AF_INET`、`AF_INET6`等一样，在此 Family 中可以定义多种 Protocol（协议）。**Netlink最多只允许定义32个协议，而且内核中已经使用了将近20个**，也就是说，还剩余10个左右可以定义自己的协议。 另外，**Netlink数据的传输使用数据报（SOCK_DGRAM）形式**。因此，在用户空间创建一个Socket的形式如下（假设协议为XXX）

```c
fd = socket(AF_NETLINK, SOCK_DGRAM, XXX);

// 或者

fd = socket(AF_NETLINK, SOCK_RAW, XXX);
```

