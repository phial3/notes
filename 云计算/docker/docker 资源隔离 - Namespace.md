[toc]


# docker 资源隔离 - Namespace


## Linux Namespace 概述

Namespace 是 Linux 内核用来隔离内核资源的方式。

Linux Namespace Kernel 功能，它可以隔离 系列的系统资源，比如 PIO ( Process ID)、 User ID Network 等。

1. Linux Namespace提供了一种内核级别隔离系统资源的方法，通过将系统的全局资源放在不同的Namespace中，来实现资源隔离的目的。
2. 不同 Namespace 的程序，可以享有一份独立的系统资源。
3. 也就是说，Namespace 可以保证 docker 不同 container 之间的资源是相互隔离，不可见的。



举个例子，进程 A 和进程 B 同属于一个命名空间，这里称为父命名空间，这时，进程 A 和 B 都通过 Clone 创建自己的子命名空间，此时，这个进程 A 和 B 创建的子进程就分别属于各个子命名空间的 init 进程（pid为1），且各个子进程之间是相互独立的。




## NameSpace 的分类

NameSpace 在 Linux 中一共有六种分类，分别是:

| Namespace 类型    | 系统调用参数    | 说明                                                         | 内核版本 |
| ----------------- | --------------- | ------------------------------------------------------------ | -------- |
| Mount Namespace   | CLONE_NEWNS     | Mount Point 文件系统挂载点                                   | 2.4.19   |
| UTS Namespace     | CLONE_NEWUTS    | Hostname and NIS domain name 主机名与NIS域名                 | 2.6.19   |
| IPC Namespace     | CLONE_NEWIPC    | System V IPC 信号量、消息队列和共享内存                      | 2.6.19   |
| PID Namespace     | CLONE_NEWPID    | Process IDs 进程号                                           | 2.6.24   |
| Network Namespace | CLONE_NEWNET    | Network devices（网络设备）、Network ports/stacks（网络端口/网络栈）等 | 2.6.29   |
| User Namespace    | CLONE_NEWUSER   | User and Group IDs 用户和用户组                              | 3.8      |
| Cgroup Namespace  | CLONE_NEWCGROUP | Cgroup root directory （Cgroup 的根目录）                    |          |


## Namespace 在 linux 中的视图 


在 Linux 中，查看命名空间的种类可以通过查看 `/proc` 文件系统查看一个进程的挂载信息，具体做法如下:
```shell
ll /proc/$pid/ns
```

例如：
```shell
> ll /proc/1345/ns
总用量 0
lrwxrwxrwx. 1 root root 0 7月   7 16:16 cgroup -> 'cgroup:[4026531835]'
lrwxrwxrwx. 1 root root 0 7月   7 16:16 ipc -> 'ipc:[4026531839]'
lrwxrwxrwx. 1 root root 0 7月   7 16:16 mnt -> 'mnt:[4026531840]'
lrwxrwxrwx. 1 root root 0 7月   7 16:16 net -> 'net:[4026531992]'
lrwxrwxrwx. 1 root root 0 7月   7 16:16 pid -> 'pid:[4026531836]'
lrwxrwxrwx. 1 root root 0 7月   7 16:16 pid_for_children -> 'pid:[4026531836]'
lrwxrwxrwx. 1 root root 0 7月   7 16:16 time -> 'time:[4026531834]'
lrwxrwxrwx. 1 root root 0 7月   7 16:16 time_for_children -> 'time:[4026531834]'
lrwxrwxrwx. 1 root root 0 7月   7 16:16 user -> 'user:[4026531837]'
lrwxrwxrwx. 1 root root 0 7月   7 16:16 uts -> 'uts:[4026531838]'

```

注意：

namespace 文件都是链接文件。链接文件的内容的格式为：
```shell
xxx:[inode number]   
```
- inode number 用来标识一个 namespace，也可以把它理解为 namespace 的 ID
- xxx 为 namespace 的类型

1. **如果两个进程的某个 namespace 文件指向同一个链接文件，说明其相关资源在同一个 namespace 中。**
2. **在 `/proc/[pid]/ns` 里放置这些链接文件的另外一个作用是，一旦这些链接文件被打开，只要打开的文件描述符(fd)存在，那么就算该 namespace 下的所有进程都已结束，这个 namespace 也会一直存在，后续的进程还可以再加入进来**。

还可以通过文件挂载的方式阻止 namespace 被删除。比如我们可以把当前进程中的 uts 挂载到 ~/uts 文件：
```shell
$ touch ~/uts
$ sudo mount --bind /proc/$$/ns/uts ~/uts
```



## Namespace 的使用

Namespace API 主要使用如下 个系统调用：
- `clone()` - 创建新进程。根据系统调用参数来判断哪些类型的 Namespace 被创建，而且它们的子进程也会被包含到这些 Namespace 中。
- `unshare()` - 将进程移出某个 Namespace
- `setns()` - 将进程加入到 Namespace 中。


### clone() 系统调用

可以通过clone系统调用来创建一个独立Namespace的进程，它的函数描述如下：
```c
int clone(int (*child_func)(void *), void *child_stack, int flags, void *arg);
```

通过flags参数来控制创建进程时的特性，比如新创建的进程是否与父进程共享虚拟内存等。比如可以传入CLONE_NEWNS标志使得新创建的进程拥有独立的Mount Namespace，也可以传入多个flags使得新创建的进程拥有多种特性，比如：
```c
flags = CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC;
```

### setns 加入已存在的 Namepspace

setns()函数可以把进程加入到指定的Namespace中，它的函数描述如下：
```c
int setns(int fd, int nstype);
```
参数描述如下：
- **fd 参数**：表示文件描述符，前面提到可以通过打开/proc/$pid/ns/的方式将指定的Namespace保留下来，也就是说可以通过文件描述符的方式来索引到某个Namespace。
- **nstype 参数**：用来检查fd关联Namespace是否与nstype表明的Namespace一致，如果填0的话表示不进行该项检查。


### unshare 脱离到新的 Namespace

unshare()系统调用用于将当前进程和所在的Namespace分离，并加入到一个新的Namespace中，相对于setns()系统调用来说，unshare()不用关联之前存在的Namespace，只需要指定需要分离的Namespace就行，该调用会自动创建一个新的Namespace。
```c
int unshare(int flags);
```




## Namespaee 类型详解


### 1. Mount Namespace


#### 说明
Mount Namespace 用来隔离文件系统的挂载点，不同 Mount Namespace 的进程拥有不同的挂载点，同时也拥有了不同的文件系统视图。Mount Namespace 是历史上第一个支持的 Namespace，它通过 CLONE_NEWNS 来标识的。

在 Mount Namespace 调用 mount（）和 umount（） 仅仅只会影响
当前 Namespace 内的文件系统，而对全局的文件系统是没有影响的。

mount所达到的效果是：像访问一个普通的文件一样访问位于其他设备上文件系统的根目录，也就是将该设备上目录的根节点挂到了另外一个文件系统的页节点上，达到给这个文件系统扩充容量的目的。

可以通过/proc文件系统查看一个进程的挂载信息，具体做法如下：
```shell
cat /proc/$pid/mountinfo
```

例如：
```shell
> cat /proc/1345/mountinfo
21 96 0:20 / /sys rw,nosuid,nodev,noexec,relatime shared:2 - sysfs sysfs rw,seclabel
22 96 0:5 / /proc rw,nosuid,nodev,noexec,relatime shared:26 - proc proc rw
23 96 0:6 / /dev rw,nosuid shared:22 - devtmpfs devtmpfs rw,seclabel,size=1427292k,nr_inodes=356823,mode=755
24 21 0:7 / /sys/kernel/security rw,nosuid,nodev,noexec,relatime shared:3 - securityfs securityfs rw
25 23 0:21 / /dev/shm rw,nosuid,nodev shared:23 - tmpfs tmpfs rw,seclabel

```

各个部分的含义为：
1. **mount ID**:  unique identifier of the mount (may be reused after umount)
2. **parent ID**:  ID of parent (or of self for the top of the mount tree)
3. **major:minor**:  value of st_dev for files on filesystem
4. **root**:  root of the mount within the filesystem
5. **mount point**:  mount point relative to the process's root
6. **mount options**:  per mount options
7. **optional fields**:  zero or more fields of the form "tag[:value]"
8. **separator**:  marks the end of the optional fields
9. **filesystem type**:  name of filesystem of the form "type[.subtype]"
10. **mount source**:  filesystem specific information or "none"
11. **super options**:  per super block options


#### Go 示例
```shell
> cat main.go
package main

import (
        "log"
        "os"
        "os/exec"
        "syscall"
)

func main() {
        # 启动一个 shell 终端
        cmd := exec.Command("sh")
        
        # 配置启动线程的 Flag
        cmd.SysProcAttr = &syscall.SysProcAttr{
                Cloneflags: syscall.CLONE_NEWNS
        }

        cmd.Stdin = os.Stdin
        cmd.Stdout = os.Stdout
        cmd.Stderr = os.Stderr

        if err := cmd.Run(); err != nil {
                log.Fatal(err)
        }
}
```


1. 首先，运行代码，查看一下 `/proc` 件内容。 proc 是一个文件系统，提供额外的
可以通过内核和内核模块将信息发送给进程。
```shell
> ls /proc
1     169   2455  28    3341  465  587  789  9          devices      keys         net            thread-self
10    17    2476  287   3342  467  588  812  952        diskstats    key-users    pagetypeinfo   timer_list
11    170   2490  29    3346  469  589  814  971        dma          kmsg         partitions     tty
12    171   25    3     34    470  590  838  974        driver       kpagecgroup  sched_debug    uptime
13    173   2518  30    35    471  6    839  979        execdomains  kpagecount   schedstat      version
1345  174   2531  31    36    472  66   842  acpi       fb           kpageflags   scsi           vmallocinfo
1348  18    2540  32    37    477  684  845  asound     filesystems  loadavg      self           vmstat
1363  2     2544  3256  38    547  721  847  buddyinfo  fs           locks        slabinfo       zoneinfo
1373  20    26    33    39    558  783  848  bus        interrupts   mdstat       softirqs
1387  2252  27    3313  4     582  784  849  cgroups    iomem        meminfo      stat
14    2264  2714  3317  40    583  785  867  cmdline    ioports      misc         swaps
15    23    2721  3319  41    584  786  877  consoles   irq          modules      sys
16    2320  2723  3322  43    585  787  885  cpuinfo    kallsyms     mounts       sysrq-trigger
168   24    2724  3323  462   586  788  887  crypto     kcore        mtrr         sysvipc

```

2. 这里 proc 还是宿主机的，下面 将 `/proc` mount 到当前程序自己的 Namespace 下面来。
    - 注意下面的 mount 命令 第三个 proc 是 device 名称，可以设备名指定为 nodev
```shell
mount -t proc proc /proc
```

3. 再次查看 `/proc` 目录，发现目录就变少了。但不影响父命名空间。



### 2. UTS Namespce

#### 说明

UTS Namespace 主要用来隔离 nodename domainname 个系统标识。在 UT Namespace 里面 每个 Namespace 允许有自己的 hostname


主机名和域名可以用来代替IP地址，如果没有这一层隔离，同一主机上不同的容器的网络访问就可能出问题。

#### Go 示例

```shell
> cat main.go
package main

import (
        "log"
        "os"
        "os/exec"
        "syscall"
)

func main() {
        # 启动一个 shell 终端
        cmd := exec.Command("sh")
        
        # 配置启动线程的 Flag
        cmd.SysProcAttr = &syscall.SysProcAttr{
                Cloneflags: syscall.CLONE_NEWNS | syscall.CLONE_NEWUTS
        }

        cmd.Stdin = os.Stdin
        cmd.Stdout = os.Stdout
        cmd.Stderr = os.Stderr

        if err := cmd.Run(); err != nil {
                log.Fatal(err)
        }
}
```

1. 运行程序，查看当前的 uts namespace，并且修改主机名
```shell
> go run main.go
sh-4.4# hostname
localhost.localdomain
sh-4.4# hostname -b gsh
sh-4.4# hostname
gsh
```
2. 新开一个shell，查看当前的主机名，发现宿主机的主机名并没有被修改
```shell
> hostname
localhost.localdomain
```


### 3. IPC Namespace

#### 说明

IPC Namespace 是对进程间通信的隔离，进程间通信常见的方法有信号量、消息队列和共享内存。

IPC Namespace主要针对的是SystemV IPC和Posix消息队列，这些IPC机制都会用到标识符，比如用标识符来区分不同的消息队列，IPC Namespace要达到的目标是相同的标识符在不同的Namepspace中代表不同的通信介质(比如信号量、消息队列和共享内存)。


#### Go 示例

```shell
> cat main.go
package main

import (
        "log"
        "os"
        "os/exec"
        "syscall"
)

func main() {
        # 启动一个 shell 终端
        cmd := exec.Command("sh")
        
        # 配置启动线程的 Flag
        cmd.SysProcAttr = &syscall.SysProcAttr{
                Cloneflags: syscall.CLONE_NEWNS | syscall.CLONE_NEWUTS | syscall.CLONE_NEWIPC 
        }

        cmd.Stdin = os.Stdin
        cmd.Stdout = os.Stdout
        cmd.Stderr = os.Stderr

        if err := cmd.Run(); err != nil {
                log.Fatal(err)
        }
}
```

1. 开启两个shell，第一个宿主机的shell终端，查看现有的 ipc Message Queues
```shell
> ipcs -q

--------- 消息队列 -----------
键        msqid      拥有者  权限     已用字节数 消息
```
2. 在宿主机的shell终端中，创建 message queue
```shell
> ipcmk -Q
消息队列 id：0
> ipcs -q

--------- 消息队列 -----------
键        msqid      拥有者  权限     已用字节数 消息
0x487ab3e2 0          root       644        0            0
```
3. 在另一个shell终端中，运行程序，并且查看 子命名空间的消息队列
```shell
> go run main.go
sh-4.4$ ipcs -q

--------- 消息队列 -----------
键        msqid      拥有者  权限     已用字节数 消息
```


### 4. PID Namespace

#### 说明

PID Namespace 是用来隔离进程 ID 。同样一个进程在不同的 PID Namespace 里可
有不同的 PID 。

这样就可以理解 docker container 里面 ps -ef 经常会发现， 在容器前台运行的那个进程 PID 但是在容器 ，使用 ps -ef 会发 样的进程却有不同的 PID 这就是 PID Namespace 做的事情。


#### Go 示例
```shell
> cat main.go
package main

import (
        "log"
        "os"
        "os/exec"
        "syscall"
)

func main() {
        # 启动一个 shell 终端
        cmd := exec.Command("sh")
        
        # 配置启动线程的 Flag
        cmd.SysProcAttr = &syscall.SysProcAttr{
                Cloneflags: syscall.CLONE_NEWNS | syscall.CLONE_NEWUTS | syscall.CLONE_NEWIPC | syscall.CLONE_NEWPID
        }

        cmd.Stdin = os.Stdin
        cmd.Stdout = os.Stdout
        cmd.Stderr = os.Stderr

        if err := cmd.Run(); err != nil {
                log.Fatal(err)
        }
}
```

1. 运行程序，查看子命名空间中的pid
```shell
> go run main.go
sh-4.4$ echo $$
1
```



### 5. User Namespace

#### 说明

User Namespace 主要是隔离用户用户组 ID。

就是说一个进程的 User ID 和 Group ID 在 User Namespace 内外是不同的。

较常用是，在宿主机上以一个非 root 用户运行创建一个 User Namespace。然后在 User Namespace 里面却映射成 root 用户。这意味着这个进程在 User Namespace 里面有 root 权限，但是在 User namespace 外面却没有 root 的权限。


从 Linux Kernel 3.8 开始，非 root 进程也可以创建 User Namespace，并且此用户在 Namespace 面可以被映射成 root 且在 Namespace root 权限。



#### Go 示例
```shell
> cat main.go
package main

import (
        "log"
        "os"
        "os/exec"
        "syscall"
)

func main() {
        # 启动一个 shell 终端
        cmd := exec.Command("sh")
        
        # 配置启动线程的 Flag
        cmd.SysProcAttr = &syscall.SysProcAttr{
                Cloneflags: syscall.CLONE_NEWNS | syscall.CLONE_NEWUTS | syscall.CLONE_NEWIPC | syscall.CLONE_NEWPID
        }

        cmd.Stdin = os.Stdin
        cmd.Stdout = os.Stdout
        cmd.Stderr = os.Stderr

        if err := cmd.Run(); err != nil {
                log.Fatal(err)
        }
}
```

1. 在宿主机上查看当前用户是 root
```shell
> id
uid=0(root) gid=0(root) 组=0(root) 环境=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
```
2. 执行程序，查看子命名空间中的用户和用户组为 nobody
```shell
> go run main.go
sh-4.4$ id
uid=65534(nobody) gid=65534(nobody) 组=65534(nobody) 环境=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
```



### 6. Network Namespace


#### 说明

Network Namespace 是用来隔离网络设备、 IP 地址端口 等网络栈的 Namespace。

Network Namespace 可以让每个容器拥有自己独立的（虚拟的）网络设备，而且容器内的应用可以绑定到自己的端口，每个 Namespace 内的端口都不会互相冲突。在宿主机上搭建网桥后，就能很方便地实现容器之间的通信，而且不同容器上的应用可以使用相同的端口



#### Go 示例

```shell
> cat main.go
package main

import (
        "log"
        "os"
        "os/exec"
        "syscall"
)

func main() {
        # 启动一个 shell 终端
        cmd := exec.Command("sh")
        
        # 配置启动线程的 Flag
        cmd.SysProcAttr = &syscall.SysProcAttr{
                Cloneflags: syscall.CLONE_NEWNS | syscall.CLONE_NEWUTS | syscall.CLONE_NEWIPC | syscall.CLONE_NEWPID | syscall.CLONE_NEWNET
        }

        cmd.Stdin = os.Stdin
        cmd.Stdout = os.Stdout
        cmd.Stderr = os.Stderr

        if err := cmd.Run(); err != nil {
                log.Fatal(err)
        }
}
```


1. 运行程序，查看子命名空间中的网络信息, 发现没有任何网络信息。
```
> go run main.go
sh-4.4$ ifconfig
```