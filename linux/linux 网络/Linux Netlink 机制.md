# Linux Netlink 机制详解

[toc]

## Netlink 背景介绍



由于内核开发和维护的复杂性，只有最关键和性能关键的代码被放置在内核中。其他诸如图形用户界面（GUI）、管理和控制代码通常以用户空间应用程序的形式进行编程。在Linux中，将某些功能的实现在内核和用户空间之间进行划分的做法非常常见。那么问题是内核代码和用户空间代码如何进行通信呢？

答案是内核和用户空间之间存在各种IPC方法，如系统调用、ioctl、proc文件系统或Netlink套接字。本文将讨论Netlink套接字，并揭示其作为一种面向网络功能友好的IPC的优势。





## 概述



**内核和用户态通信的桥梁netlink socket**



### 介绍

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





### Netlink Socket

Netlink套接字是一种用于在内核和用户空间进程之间传输信息的特殊IPC机制。它通过标准套接字API（供用户空间进程使用）和内核模块的特殊内核API之间的全双工通信链路来实现。Netlink套接字使用`AF_NETLINK`地址族，而TCP/IP套接字使用AF_INET地址族。每个Netlink套接字功能在内核头文件include/linux/netlink.h中定义了自己的协议类型。。

下面是当前由Netlink套接字支持的功能及其协议类型的子集：

- **NETLINK_ROUTE**：用于路由（如BGP、OSPF、RIP）和设备的钩子功能。用户空间路由守护程序可以通过这个协议类型更新内核路由表。 
- **NETLINK_USERSOCK**：保留给用户模式套接字协议。这个协议类型为用户空间应用程序提供了一种在内核和用户空间之间进行通信的方式。 
- **NETLINK_FIREWALL**：未使用的协议类型，之前用于ip_queue。 
- **NETLINK_SOCK_DIAG**：用于套接字监视的协议类型。 
- **NETLINK_NFLOG**：netfilter/iptables的ULOG协议类型，用于用户空间iptables管理工具和内核空间Netfilter模块之间的通信。
- **NETLINK_XFRM**：用于IPsec的协议类型。 
- **NETLINK_SELINUX**：SELinux事件通知的协议类型。
- **NETLINK_AUDIT**：用于审计的协议类型。
- **NETLINK_NETFILTER**：netfilter子系统的协议类型。
- **NETLINK_IP6_FW**：IPv6防火墙的协议类型。
- **NETLINK_DNRTMSG**：DECnet路由消息的协议类型。
- **NETLINK_KOBJECT_UEVENT**：内核消息到用户空间的协议类型，用于内核对象的事件。
- **NETLINK_GENERIC**：通用的协议类型。
- **NETLINK_SCSITRANSPORT**：SCSI传输的协议类型。
- **NETLINK_ECRYPTFS**：eCryptfs的协议类型。
- **NETLINK_RDMA**：RDMA（远程直接内存访问）的协议类型。
-  **NETLINK_CRYPTO**：加密层的协议类型。
- **NETLINK_SMC**：SMC（System Management Control）监视的协议类型。



### Netlink 特点

为什么上述功能使用Netlink而不是系统调用？

为新功能添加系统调用、ioctl或proc文件是一项复杂的任务；这样做可能会污染内核并损害系统的稳定性。相比之下，Netlink套接字则更为简单：<u>只需在netlink.h中添加一个常量，即协议类型。然后，内核模块和应用程序可以立即使用类似套接字的API进行通信</u>。



Netlink 特点有：

1. **非阻塞**
   - <u>Netlink 是异步的</u>，因为与其他套接字API一样，它<u>提供**套接字队列**来平滑处理消息的突发</u>。发送 Netlink 消息的系统调用将消息排入接收方的 Netlink 队列，然后调用接收方的接收处理程序。
   - <u>在接收处理程序的上下文中，接收方可以决定立即处理消息，或者将消息留在队列中，并在不同的上下文中稍后处理</u>。
   - 与 Netlink 不同，**系统调用则需要同步处理**。因此，<u>如果使用系统调用来将消息从用户空间传递到内核，如果处理该消息的时间很长，可能会影响内核的调度粒度</u>。
2. **没有编译依赖**
   - **在内核中实现系统调用的代码在编译时静态地链接到内核中**；因此，将系统调用代码包含在可加载模块中（这是大多数设备驱动程序的情况）是不合适的。
   - 使用 Netlink 套接字，则**不存在 Linux 内核的 Netlink 核心与驻留在可加载内核模块中的 Netlink 应用程序之间的编译时依赖关系。**
3. **支持多播**
   - **Netlink 套接字支持多播**，这是它相对于系统调用、ioctl和proc的另一个优点。
   - <u>一个进程可以将消息多播到一个 Netlink 组地址，其他任意数量的进程可以监听该组地址。这为内核向用户空间分发事件提供了一种近乎完美的机制。</u>
4. **双工**
   - <u>系统调用和 ioctl 是单工 IPC</u>，这意味着<u>仅可由用户空间应用程序发起这些IPC的会话</u>。但是，如果内核模块需要向用户空间应用程序发送紧急消息，使用这些IPC是无法直接实现的。通常，应用程序需要定期轮询内核以获取状态变化，尽管密集轮询是昂贵的。
   - Netlink 通过允许内核也能够发起会话，优雅地解决了这个问题。将其**称为Netlink套接字的双工特性**。
5. **API 通用**
   - Netlink 套接字提供了一种 BSD 套接字风格的 API，这种风格被软件开发社区广泛理解。因此，与使用相对晦涩的系统调用 API 和 ioctl 相比，学习和使用成本要低得多。



这里注意：关于BSD路由套接字
 在 BSD TCP/IP 堆栈实现中，有一个称为**路由套接字**的特殊套接字。它的**地址族是 AF_ROUTE**，**协议族是 PF_ROUTE**，**套接字类型是 SOCK_RAW**。在BSD中，<u>路由套接字被用于进程在内核路由表中添加或删除路由</u>。

在 Linux 中，**Netlink 套接字协议类型 NETLINK_ROUTE 提供了与路由套接字等价的功能**。Netlink 套接字提供了比BSD路由套接字更丰富的功能。





## Netlink Socket API

标准套接字API（如socket()、sendmsg()、recvmsg()和close()）可以被用户空间应用程序用来访问Netlink套接字。请查阅手册页面以获取这些API的详细定义。在这里，我们仅讨论如何在 Netlink 套接字的上下文中选择这些 API 的参数。这些 API 对于任何使用 TCP/IP 套接字编写过普通网络应用程序的人来说都应该非常熟悉。



### 1. 创建 socket

为了使用`socket()`创建一个套接字，可以使用以下接口：

```c
int socket(int domain, int type, int protocol);
```

其中，

- 套接字的协议(domain)：是 `AF_NETLINK`
- 而套接字的类型(type) ：可以是 SOCK_RAW 或 SOCK_DGRAM，因为 <u>netlink 是一种面向数据报的服务</u>。
- 协议(protocol)：选择了使用该套接字的 netlink 特性。以下是一些预定义的netlink协议类型：
  - NETLINK_ROUTE
  - NETLINK_XFRM
  - NETLINK_ROUTE6
  - 也可以添加自己定义的 netlink 协议类型。



对于每种 netlink 协议类型，最多可以定义 32 个组播组。每个组播组用一个位掩码 `1<<i` 来表示，其中 `0<=i<=31`。当一组进程和内核进程协调一起实现相同的功能时，发送组播 netlink 消息可以减少使用的系统调用数量，并减轻应用程序维护组播组成员资格所带来的负担。



### 2. 绑定 socket

就像对于 TCP/IP 套接字一样，netlink 的 `bind()` API 将本地（源）套接字地址与已打开的套接字关联起来。netlink 地址结构如下：

```c
include/uapi/linux/netlink.h
struct sockaddr_nl
{
  	sa_family_t    nl_family;  /* AF_NETLINK   */
  	unsigned short nl_pad;     /* zero         */
  	__u32          nl_pid;     /* 进程pid */
  	__u32          nl_groups;  /* 组播组掩码 */
} nladdr;
```

- 在使用 `bind()` 时，<u>`sockaddr_nl` 的 `nl_pid` 字段可以填入调用进程自己的 pid</u>。在这里，nl_pid 用作这个 netlink 套接字的本地地址。应用程序负责选择一个唯一的 32 位整数填充到 `nl_pid` 中：
  1. **算法 1：使用应用程序的进程ID作为 `nl_pid`，如果对于给定的 netlink 协议类型，进程只需要一个 netlink 套接字**。

```c
NL_PID 算法 1：nl_pid = getpid();
```

​	2. **算法 2：在相同进程的不同线程想要在同一 netlink 协议下打开不同的 netlink 套接字时，相同进程的不同 pthread 可以为相同的 netlink 协议类型拥有各自的 netlink 套接字**。

```c
NL_PID 算式 2：pthread_self() << 16 | getpid();
```



- <u>如果应用程序希望接收**针对特定多播组**的协议类型的n etlink 消息</u>，**应将所有感兴趣的多播组的位掩码OR在一起，形成 `sockaddr_nl` 的 `nl_groups` 字段**。**否则，应将nl_groups清零**，以便应用程序只接收针对应用程序的协议类型的单播 netlink 消息。



填充了 `nladdr` 之后，可以按如下方式进行绑定：

```c
bind(fd, (struct sockaddr*)&nladdr, sizeof(nladdr));
```



### 3. 发送 Netlink 消息



**为了将 netlink 消息发送给内核或其他用户空间进程，需要提供另一个 `struct sockaddr_nl nladdr` 作为目的地址**，就像发送 UDP 数据包一样。**如果消息目标是内核，`nl_pid` 和 `nl_groups` 都应该填写为 0**。

- 如果消息是**单播消息**，目的地是另一个进程，则 `nl_pid` 是另一个进程的 pid，而 `nl_groups` 是 0，假设系统使用了`nlpid` 算式 1。

- 如果消息是**多播消息**，目的地是一个或多个多播组，则所有目的地多播组的位掩码应该 OR 在一起，形成 `nl_groups` 字段。

然后，可以将 netlink 地址提供给 `struct msghdr msg`，使用 `sendmsg()` API 发送消息，就像下面一样：

```c
struct msghdr msg;
msg.msg_name = (void *)&(nladdr);
msg.msg_namelen = sizeof(nladdr);
```



#### 公共消息头



**1. struct msghdr**

**netlink 套接字还需要其自己的消息头**。这是为所有协议类型的 netlink 消息提供一个共同的基础。

```c
struct user_msghdr {
    void        __user *msg_name;    /* ptr to socket address structure */
    int        msg_namelen;        /* size of socket address structure */
    struct iovec    __user *msg_iov;    /* scatter/gather array */
    __kernel_size_t    msg_iovlen;        /* # elements in msg_iov */
    void        __user *msg_control;    /* ancillary data */
    __kernel_size_t    msg_controllen;        /* ancillary data buffer length */
    unsigned int    msg_flags;        /* flags on received message */
};
```



我们知道socket消息的发送和接收函数一般有这几对：

- recv/send
- readv/writev
- recvfrom/sendto。
- 当然还有 recvmsg/sendmsg

应用层向内核传递消息可以使用 sendto() 或 sendmsg() 函数，其中 sendmsg 函数需要应用程序手动封装 msghdr 消息结构，而 sendto() 函数则会由内核代为分配。其中

- msg_name：指向数据包的目的地址；
- msg_namelen：目的地址数据结构的长度；
- msg_iov：消息包的实际数据块，定义如下：

前面三对函数各有各的特点功能，而 recvmsg/sendmsg 就是要囊括前面三对的所有功能，当然还有自己特殊的用途。**`msghdr` 的前两个成员(`msg_name` 和 `msg_namelen`)就是为了满足 recvfrom/sendto 的功能**；

**中间两个成员 `msg_iov` 和 `msg_iovlen` 则是为了满足 readv/writev 的功能**；

- msg_iov：消息包的实际数据块
- msg_iovlen：msg_iov 缓冲区数组元素个数。

**最后的 `msg_flags` 则是为了满足 recv/send 中 flag 的功能**；

- msg_flags：接收消息的标识。

 **`msg_control` 和 `msg_controllen` 则是满足 recvmsg/sendmsg 特有的功能**。

- msg_control：消息的辅助数据；
- msg_controllen：消息辅助数据的大小；





**2. struct iovec**

msghdr 结构体中的 msg_iovlen 就是 iovec 类型，表示实际的数据块

```c
struct iovec
{
	void __user *iov_base;	/* BSD uses caddr_t (1003.1g requires void *) */
	__kernel_size_t iov_len; /* Must be size_t (1003.1g) */
};
```

- iov_base：消息包实际载荷的首地址；
- iov_len：消息实际载荷的长度。



**2. struct nlmsghdr**



<u>因为 Linux 内核的 netlink 核心假设每个 netlink 消息中都存在以下头部，所以应用程序必须在发送的每个 netlink 消息中提供此头部</u>：

```c
struct nlmsghdr
{
      __u32 nlmsg_len;   /* 消息长度 */
      __u16 nlmsg_type;  /* 消息类型 */
      __u16 nlmsg_flags; /* 额外标志 */
      __u32 nlmsg_seq;   /* 序列号 */
      __u32 nlmsg_pid;   /* 发送进程PID */
};
```

- **nlmsg_len** 必须填写 netlink 消息的总长度，包括头部，这是 netlink 所需要的。

- **nlmsg_type** 可以被应用程序使用，对于 netlink 核心来说是不透明的值。内核在include/uapi/linux/netlink.h中定义了以下4种通用的消息类型，它们分别是：

  - <u>NLMSG_NOOP</u>：不执行任何动作，必须将该消息丢弃；
  - <u>NLMSG_ERROR</u>：消息发生错误；
  - <u>NLMSG_DONE</u>：标识分组消息的末尾；
  - <u>NLMSG_OVERRUN</u>：缓冲区溢出，表示某些消息已经丢失。

- **nlmsg_flags** 用于给消息提供额外的控制，由 netlink 核心读取和更新。定义在include/uapi/linux/netlink.h中；

  ```c
  #define NLM_F_REQUEST        1    /* It is request message.     */
  #define NLM_F_MULTI          2    /* Multipart message, terminated by NLMSG_DONE */
  #define NLM_F_ACK        	 4    /* Reply with ack, with zero or error code */
  #define NLM_F_ECHO        	 8    /* Echo this request         */
  #define NLM_F_DUMP_INTR     16    /* Dump was inconsistent due to sequence change */
   
  /* Modifiers to GET request */
  #define NLM_F_ROOT    	0x100    /* specify tree    root    */
  #define NLM_F_MATCH     0x200    /* return all matching    */
  #define NLM_F_ATOMIC    0x400    /* atomic GET        */
  #define NLM_F_DUMP    (NLM_F_ROOT|NLM_F_MATCH)
   
  /* Modifiers to NEW request */
  #define NLM_F_REPLACE   0x100    /* Override existing        */
  #define NLM_F_EXCL    	0x200    /* Do not touch, if it exists    */
  #define NLM_F_CREATE    0x400    /* Create, if it does not exist    */
  #define NLM_F_APPEND    0x800    /* Add to end of list        */
  ```

  

- **nlmsg_seq** 消息序列号，用以将消息排队，有些类似TCP协议中的序号（不完全一样），但是netlink的这个字段是可选的，不强制使用；

- **nlmsg_pid** 发送端口的 ID 号，对于内核来说该值就是 0，对于用户进程来说就是其 socket 所绑定的 ID 号。



因此，netlink 消息包括 nlmsghdr 和消息载荷。一旦输入了消息，就将其发送到 `struct msghdr msg`：

```c
struct iovec iov;

iov.iov_base = (void *)nlh;
iov.iov_len = nlh->nlmsg_len;

msg.msg_iov = &iov;
msg.msg_iovlen = 1;
```

通过上述步骤，调用 `sendmsg()` 发送出 netlink 消息：

```c
sendmsg(fd, &msg, 0);
```





### 4. 接收 Netlink 消息



接收应用程序<u>需要分配足够大的缓冲区来存放 netlink 消息头和消息载荷</u>。然后可以像下面这样填充 `struct msghdr msg`，并使用标准的 recvmsg() 来接收 netlink 消息，假设缓冲区由 nlh 指向：

```c
struct sockaddr_nl nladdr;
struct msghdr msg;
struct iovec iov;

iov.iov_base = (void *)nlh;
iov.iov_len = MAX_NL_MSG_LEN;
msg.msg_name = (void *)&(nladdr);
msg.msg_namelen = sizeof(nladdr);

msg.msg_iov = &iov;
msg.msg_iovlen = 1;
recvmsg(fd, &msg, 0);
```

消息接收正确后，nlh应该指向刚刚接收到的netlink消息的头部。nladdr应持有接收消息的目的地址，其中包括PID和消息发送的多播组。



### 5. 关闭连接



调用 `close(fd)` 将关闭文件描述符 fd 所标识的 Netlink 套接字。



## Netlink 内核空间 API



内核空间的netlink API位于net/netlink/af_netlink.c模块。头文件incude/linux/netlink.h [github.com/jobs77/linu…](https://link.juejin.cn?target=https%3A%2F%2Fgithub.com%2Fjobs77%2Flinux%2Fblob%2Fmaster%2Finclude%2Flinux%2Fnetlink.h)

从内核方面来看，API 与用户空间 API 不同。**该 API 可以被内核模块用来访问 netlink 套接字，并与用户空间应用程序进行通信**。<u>除非使用现有的 netlink 套接字协议类型，否则需要通过向 netlink.h 添加一个常量来添加自己的协议类型</u>。例如，我们可以通过向 netlink.h 中添加以下行来为测试目的添加一个netlink协议类型：

```c
#define NETLINK_TEST_30  30
```





在用户空间中，我们调用 socket() 来创建 netlink 套接字，但在内核空间中，我们调用以下API：

```c
/* optional Netlink kernel configuration parameters */
struct netlink_kernel_cfg {
	unsigned int	groups;
	unsigned int	flags;
	void		(*input)(struct sk_buff *skb);
	struct mutex	*cb_mutex;
	int		(*bind)(struct net *net, int group);
	void		(*unbind)(struct net *net, int group);
	bool		(*compare)(struct net *net, struct sock *sk);
};

static inline struct sock *
netlink_kernel_create(struct net *net, int unit, struct netlink_kernel_cfg *cfg)
{
	return __netlink_kernel_create(net, unit, THIS_MODULE, cfg);
}
```

其中，

- unit 参数实际上是 netlink 协议类型，如 `NETLINK_TEST_30`。
- `netlink_kernel_cfg`中的函数指针`input`是当消息到达 netlink 套接字时调用的**回调函数**。



内核创建了用于 `NETLINK_TEST_30` 协议的 netlink 套接字后，当用户空间向内核发送 `NETLINK_TEST_30` 协议类型的 netlink 消息时，由 `netlink_kernel_create()` 注册的回调函数 `input()` 将被调用。以下是回调函数 input 的一个示例实现：

```c
void input(struct sock *sk, int len)
{
    struct sk_buff *skb;
    struct nlmsghdr *nlh = NULL;
    u8 *payload = NULL;

    while ((skb = skb_dequeue(&sk->receive_queue)) != NULL) {
        /* 处理skb->data指向的netlink消息 */
        nlh = (struct nlmsghdr *)skb->data;
        payload = NLMSG_DATA(nlh);
        /* 处理nlh和payload指向的netlink消息 */
    }
}
```



这个 `input()` 函数在由发送进程触发的 `sendmsg()` 系统调用的上下文中调用。

- 如果处理 netlink 消息很快，可以在 input() 内部处理 netlink 消息是可以的。
- 如果处理 netlink 消息花费的时间很长，我们希望将其从 `input()` 中分离出来，以避免阻塞其他系统调用进入内核。为此，我们可以使用专用的内核线程来不断执行以下步骤：
  - 使用 `skb = skb_recv_datagram(nl_sk)`（其中 `nl_sk` 是 `netlink_kernel_create()` 返回的 netlink 套接字）来接收netlink消息，
  - 然后处理 `skb->data` 指向的 netlink 消息。



当 `nl_sk` 中没有 netlink 消息时，这个内核线程会休眠。因此，在回调函数 input() 内部，我们只需唤醒正在休眠的内核线程，如下所示：

```c
void input (struct sock *sk, int len)
{
    wake_up_interruptible(sk->sleep);
}
```

这是用户空间和内核之间更可扩展的通信模型，并且它提高了上下文切换的粒度。





### 1. 从内核发送Netlink消息

与用户空间一样，**发送 netlink 消息时需要设置源 netlink 地址和目标 netlink 地址**。假设保存 netlink 消息的套接字缓冲区为 `struct sk_buff *skb`，则可以使用以下方式设置本地地址：

```c

NETLINK_CB(skb).groups = local_groups;
NETLINK_CB(skb).pid = 0;   /* from kernel */
```

目标地址可以通过以下方式设置：

```c
NETLINK_CB(skb).dst_groups = dst_groups;
NETLINK_CB(skb).dst_pid = dst_pid;
```

这些信息不存储在 `skb->data` 中，而是存储在套接字缓冲区 skb 的 netlink 控制块中。

要发送单播消息，可以使用：

```c
int 
netlink_unicast(struct sock *ssk, struct sk_buff *skb,
		    u32 portid, int nonblock)
```

其中，

- ssk 是 `netlink_kernel_create()` 返回的 netlink 套接字
- `skb->data` 指向要发送的 netlink 消息
- pid 是接收应用程序的 PID（假设使用 NLPID Formula 1）
- nonblock 表示当接收缓冲区不可用时该 API 是否应阻塞，或立即返回失败。



您还可以发送多播消息。以下 API 将 netlink 消息传递给 pid 指定的进程和 group 指定的多播组：

```c
int netlink_broadcast(struct sock *ssk, struct sk_buff *skb, u32 portid,
		      u32 group, gfp_t allocation)
```

- group 是所有接收多播组的 OR 位掩码
- allocation 是内核内存分配类型。通常，如果在中断上下文中调用 API，则使用 `GFP_ATOMIC`；否则，使用 `GFP_KERNEL`。这是因为该API可能需要分配一个或多个套接字缓冲区来克隆多播消息。



### 2. 从内核关闭Netlink套接字

假设通过 `netlink_kernel_create()` 返回的 `struct sock *nl_sk`，我们可以调用以下内核 API 来关闭内核中的 netlink 套接字：

```c
sock_release(nl_sk->socket);
```





## 例子

到目前为止，我们仅展示了最小的代码框架，以阐述netlink编程的概念。现在，我们将使用我们的NETLINK_TEST_30 netlink协议类型，并假设它已经添加到内核头文件中。以下列出的内核模块代码仅包含与netlink相关的部分，因此它应该插入到完整的内核模块框架中，您可以从许多其他参考源中找到。

### 5.1 内核与应用程序之间的单播通信

在此示例中，用户空间进程向内核模块发送netlink消息，而内核模块会将消息回显给发送进程。以下是用户空间代码：

```c
#include <sys/socket.h>
#include <linux/netlink.h>

#define MAX_PAYLOAD 2046  /* 最大有效载荷大小*/
struct sockaddr_nl src_addr, dest_addr;
struct msghdr msg;
struct nlmsghdr *nlh = NULL;
struct iovec iov;
int sock_fd;

void main() {
 sock_fd = socket(PF_NETLINK, SOCK_RAW, NETLINK_TEST_30);

 memset(&src_addr, 0, sizeof(src_addr));
 src_addr.nl_family = AF_NETLINK;
 src_addr.nl_pid = getpid();  /* 自身的PID */
 src_addr.nl_groups = 0;  /* 不在多播组中 */
 bind(sock_fd, (struct sockaddr*)&src_addr,
      sizeof(src_addr));
 
 memset(&dest_addr, 0, sizeof(dest_addr));
 dest_addr.nl_family = AF_NETLINK;
 dest_addr.nl_pid = 0;   /* 对于Linux内核 */
 dest_addr.nl_groups = 0; /* 单播 */

 nlh=(struct nlmsghdr *)malloc(
		         NLMSG_SPACE(MAX_PAYLOAD));
 /* 填充netlink消息头 */
 nlh->nlmsg_len = NLMSG_SPACE(MAX_PAYLOAD);
 nlh->nlmsg_pid = getpid();  /* 自身的PID */
 nlh->nlmsg_flags = 0;
 /* 填充netlink消息有效载荷 */
 strcpy(NLMSG_DATA(nlh), "Hello netlink socket!");

 iov.iov_base = (void *)nlh;
 iov.iov_len = nlh->nlmsg_len;
 msg.msg_name = (void *)&dest_addr;
 msg.msg_namelen = sizeof(dest_addr);
 msg.msg_iov = &iov;
 msg.msg_iovlen = 1;

 sendmsg(sock_fd, &msg, 0);

 /* 从内核读取消息 */
 memset(nlh, 0, NLMSG_SPACE(MAX_PAYLOAD));
 recvmsg(fd, &msg, 0);
 printf("收到消息有效载荷: %s\n",
	NLMSG_DATA(nlh));

 /* 关闭Netlink套接字 */
 close(sock_fd);
}

```

下面是内核代码：

```c
struct sock *nl_sk = NULL;

void nl_data_ready (struct sock *sk, int len)
{
  wake_up_interruptible(sk->sleep);
}

void netlink_test() {
 struct sk_buff *skb = NULL;
 struct nlmsghdr *nlh = NULL;
 int err;
 u32 pid;

 nl_sk = netlink_kernel_create(NETLINK_TEST_30,
                                   nl_data_ready);
 /* 等待来自用户空间的消息 */
 skb = skb_recv_datagram(nl_sk, 0, 0, &err);

 nlh = (struct nlmsghdr *)skb->data;
 printk("%s: received netlink message payload:%s\n",
        __FUNCTION__, NLMSG_DATA(nlh));

 pid = nlh->nlmsg_pid; /*发送进程的PID */
 NETLINK_CB(skb).groups = 0; /* 不在多播组中 */
 NETLINK_CB(skb).pid = 0;      /* 来自内核 */
 NETLINK_CB(skb).dst_pid = pid;
 NETLINK_CB(skb).dst_groups = 0;  /* 单播 */
 netlink_unicast(nl_sk, skb, pid, MSG_DONTWAIT);
 sock_release(nl_sk->socket);
}
```



加载执行上述内核代码的内核模块后，当我们运行用户空间可执行文件时，应该会在用户空间程序的输出中看到以下内容：

```c
收到消息有效载荷: Hello you!
```

在dmesg的输出中应该会出现以下消息：

```c
netlink_test: received netlink message payload:
Hello you!
```



### 5.2 内核与应用程序之间的多播通信

在这个例子中，有两个用户空间应用程序都在监听相同的netlink多播组。内核模块通过netlink套接字发送消息到多播组，所有应用程序都会接收到该消息。以下是用户空间的代码示例：

```c
#include <sys/socket.h>
#include <linux/netlink.h>

#define MAX_PAYLOAD 1024  
struct sockaddr_nl src_addr, dest_addr;
struct nlmsghdr *nlh = NULL;
struct iovec iov;
int sock_fd;

void main() {
 sock_fd=socket(PF_NETLINK, SOCK_RAW, NETLINK_TEST_30);

 memset(&src_addr, 0, sizeof(local_addr));
 src_addr.nl_family = AF_NETLINK;
 src_addr.nl_pid = getpid();  
 src_addr.nl_groups = 1;  // interested in group 1

 bind(sock_fd, (struct sockaddr*)&src_addr, sizeof(src_addr));

 memset(&dest_addr, 0, sizeof(dest_addr));

 nlh = (struct nlmsghdr *)malloc(NLMSG_SPACE(MAX_PAYLOAD));
 memset(nlh, 0, NLMSG_SPACE(MAX_PAYLOAD));

 iov.iov_base = (void *)nlh;
 iov.iov_len = NLMSG_SPACE(MAX_PAYLOAD);
 msg.msg_name = (void *)&dest_addr;
 msg.msg_namelen = sizeof(dest_addr);
 msg.msg_iov = &iov;
 msg.msg_iovlen = 1;

 printf("Waiting for message from kernel\n");

 /* Read message from kernel */
 recvmsg(fd, &msg, 0);
 printf("Received message payload: %s\n", NLMSG_DATA(nlh));
 close(sock_fd);
}
```

以下是内核空间的代码示例：

```c
#define MAX_PAYLOAD 2048
struct sock *nl_sk = NULL;

void netlink_test() {
 sturct sk_buff *skb = NULL;
 struct nlmsghdr *nlh;
 int err;

 nl_sk = netlink_kernel_create(NETLINK_TEST_30, nl_data_ready);
 skb=alloc_skb(NLMSG_SPACE(MAX_PAYLOAD),GFP_KERNEL);
 nlh = (struct nlmsghdr *)skb->data;
 nlh->nlmsg_len = NLMSG_SPACE(MAX_PAYLOAD);
 nlh->nlmsg_pid = 0;  
 nlh->nlmsg_flags = 0;
 strcpy(NLMSG_DATA(nlh), "Greeting from kernel!");
 NETLINK_CB(skb).groups = 1;  
 NETLINK_CB(skb).pid = 0;  
 NETLINK_CB(skb).dst_pid = 0;  
 NETLINK_CB(skb).dst_groups = 1;  

 netlink_broadcast(nl_sk, skb, 0, 1, GFP_KERNEL);
 sock_release(nl_sk->socket);
}
```



假设用户空间的代码被编译为可执行文件nl_recv，我们可以运行两个nl_recv的实例：

```c
./nl_recv &
Waiting for message from kernel
./nl_recv &
Waiting for message from kernel
```

然后，在加载执行内核空间代码的内核模块之后，两个nl_recv实例应该都会接收到以下消息：

```c
Received message payload: Greeting from kernel!
Received message payload: Greeting from kernel!
```
