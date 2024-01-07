# 解决创建 Window 虚拟机只显示 2 个或 4 个 CPU 问题

 

## Win系统遇到的问题

在 Openstack 部署 Linux 虚拟机 cpu 数量与配置的 Flavor 数额相匹配，但是如果部署 Windows 系统的虚拟机，就会出现虚拟机中的 cpu 数量最多只有 4 个（Windows 某些版本最多只显示 2 个 cpu），无法满足业务的需求。

## 问题原因

 

### cpu 架构简介

首先说明一下 CPU 的架构，

主要有三个概念：Socket、Core、Thread

1.  **CPU Socket** : 代表真实物理 CPU **插槽**
2.  **CPU Core** : 代表每颗物理 CPU 的**核数，**一个 CPU 可以有多个 Core，各个 Core 之间是相互独立的，可以并行执行逻辑运算
3.  **CPU Thread** : 代表每个 CPU Core 的**线程数**，也就是一个 Core 又可以多线程执行，这就是超线程的概念，Thread 只能算是并发。

 

当我们通过 Openstack 创建一个 Windows 系统的虚拟机，为其分配的 vcpu 数量其实就是 Thread 的数量。

因此可以通过下面的公式计算出 vcpu 数量：

```shell
vcpu 个数 = CPU Socket 数量 * CPU Core 数量 * CPU Thread 数量
```

 

### Windows 对 CPU Socket 的支持

Windows 不同系统版本对于 CPU Socket （插槽）的支持不尽相同，一般，桌面版（如 Win7 等）最大支持 2 路 CPU，即 CPU Socket 为 2，而服务器版（Win Server）最大支持 4 路 CPU，即 CPU Socket 为 4

 

 

### Openstack 创建 Windows 系统对 CPU 的定义

 

首先，Openstack Nova 创建虚拟机调用的是 底层 的 libvirt，而 libvirt 对 CPU 的架构定义如下(virsh edit instance-xxx)，在 libvirt 对虚拟机的 xml 定义中：

```xml
  <cpu mode='host-model' check='partial'>
    <topology sockets='6' cores='1' threads='1'/>
  </cpu>
```



上面代表该虚拟机的 CPU Socket（插槽）为 6，CPU Core（核心）为 1，CPU Thread（线程数）为 1，总共的 vcpu 为 6 \* 1 \* 1 = 6 

 

但是如果是 windows 系统，只能识别最多 4 个 CPU Socket，如果 CPU Core（核心）为 1，CPU Thread（线程数）为 1，总共的 vcpu 为 4 \* 1 \* 1 = 4

 

如果不手动指定 CPU Socket，CPU Core，CPU Thread，那么 Nova 默认配置为：

- CPU Socket 为 Flavor 中指定的 vcpu 数
- CPU Core 为 1
- CPU Thread 为 1

## 解决办法

 

修改 Flavor 的元数据信息：

![](https://github.com/Nevermore12321/LeetCode/blob/blog/云计算/OpenStack/work_1_win虚拟机只能识别2cpu_1.png?raw=true)

在 Flavor 的元数据管理界面，在 Virtual CPU Topology 配置组下，有对于 cpu 的配置：

- vCPU Sockets
- vCPU Cores
- vCPU Threads
- Max vCPU Sockets - 最大允许多少插槽
- Max vCPU Cores - 最大允许多少核心
- Max vCPU Threads - 最大允许多少线程数

 

根据上面的示例，配置了 4 个 CPU Socket（注意 windows 系统最多只能识别 4 个），CPU Core（核心）为 2，CPU Thread（线程数）为 1，最终计算的 vcpu 数目 = 4 \* 2 \* 1 = 8

 

创建 Win10 虚拟机后，在虚拟机内部查看 cpu 数目：

 

![win10虚拟机查看任务管理器](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/OpenStack/wok_1_win10%E8%99%9A%E6%8B%9F%E6%9C%BA%E5%8F%AA%E8%83%BD%E8%AF%86%E5%88%AB2cpu_2.png?raw=true)

![win10虚拟机查看设备管理器](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/OpenStack/work_1_win10%E8%99%9A%E6%8B%9F%E6%9C%BA%E5%8F%AA%E8%83%BD%E8%AF%86%E5%88%AB2cpu_3.png?raw=true)

可以发现，Win10 系统已经能够识别到 8 个 vcpu 数目。

 

 