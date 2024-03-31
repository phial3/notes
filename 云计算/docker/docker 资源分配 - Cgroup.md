[toc]

# docker 资源分配 - Cgroup


## 概述


**Linux Cgroups (Control Groups ）**
- 提供了对一组进程及将来子进程的资源限制、控制和统计的能力，这些资源包括 CPU、内存、存储、网络等。
- 通过 Cgroups ，可以方便地限制某个进程的资源占用，并且可以实时地监控进程的监控和统计信息
- **cgroups(Control Groups) 是 linux 内核提供的一种机制**。
- 可以根据需求把一系列系统任务及其子任务整合(或分隔)到按资源划分等级的不同组内，从而为系统资源管理提供一个统一的框架。
- 简单说，**cgroups 可以限制、记录任务组所使用的物理资源**。本质上来说，**cgroups 是内核附加在程序上的一系列钩子(hook)，通过程序运行时对资源的调度触发相应的钩子以达到资源追踪和限制的目的。**



### Cgroup 作用

实现 cgroups 的主要目的是为不同用户层面的资源管理提供一个统一化的接口。从单个任务的资源控制到操作系统层面的虚拟化，cgroups 提供了四大功能：
- **资源限制**：cgroups 可以对任务使用的资源总额进行限制。比如设定任务运行时使用的内存上限，一旦超出就发 OOM。
- **优先级分配**：通过分配的 CPU 时间片数量和磁盘 IO 带宽，实际上就等同于控制了任务运行的优先级。
- **资源统计**：cgoups 可以统计系统的资源使用量，比如 CPU 使用时长、内存用量等。这个功能非常适合当前云端产品按使用量计费的方式。
- **任务控制**：cgroups 可以对任务执行挂起、恢复等操作。



### Cgroup 的概念

- **Task(任务)** ：
    - 在 linux 系统中，内核本身的调度和管理并不对进程和线程进行区分，只是根据 clone 时传入的参数的不同来从概念上区分进程和线程。
    - 任务，对应于系统中运行的一个实体，一般是指进程
- **Cgroup(控制组)**：
    - cgroups 中的资源控制以 cgroup 为单位实现。
    - Cgroup 表示按某种资源控制标准划分而成的任务组，包含一个或多个子系统。
    - 一个任务可以加入某个 cgroup，也可以从某个 cgroup 迁移到另一个 cgroup。
- **Subsystem(子系统)**：
    - cgroups 中的子系统就是一个资源调度控制器(又叫 controllers)。比如 CPU 子系统可以控制 CPU 的时间分配，内存子系统可以限制内存的使用量。
- **hierarchy(层级树)**：
    - 一系列 cgroup 组成的树形结构。
    - 每个节点都是一个 cgroup，cgroup 可以有多个子节点，子节点默认会继承父节点的属性。系统中可以有多个 hierarchy
    - 例如：系统对一组定时的任务进程通过cgroupl限制了CPU的使用率，然后其中有一个定时dump日志的进程还需要限制磁盘IO，为了避免限制了磁盘IO之后影响到其他进程，就可以创建cgroup2，使其继承于cgroupl井限制磁盘的IO，这样cgroup2便继承了cgroupl中对CPU使用率的限制，并且增加了磁盘IO的限制而不影响到cgroupl中的其他进程。




### Subsystems,Hierarchies,Control Groups 和 Tasks 的关系

#### 规则1 

**同一个hierarchy能够附加一个或多个subsystem**

![规则1](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/docker/cgroup%E8%A7%84%E5%88%991.jpg?raw=true)



#### 规则2 

**同一个subsystem只能附加到一个hierarchy上**

如下图将cpu和memory 的 subsystems(或者任意多个subsystems)附加到同一个hierarchy

![规则2](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/docker/cgroup%E8%A7%84%E5%88%992.jpg?raw=true)



#### 规则3 

- **系统每次新建一个hierarchy时，该系统上的所有task默认构成了这个新建的hierarchy的初始化cgroup，这个cgroup也称为root cgroup。**
- **对于你创建的每个hierarchy，task只能存在于其中一个cgroup中，*即一个task不能存在于同一个hierarchy的不同cgroup中***
- **但是一个task可以存在在不同hierarchy中的多个cgroup中。如果操作时把一个task添加到同一个hierarchy中的另一个cgroup中，则会从第一个cgroup中移除**


如下图,cpu和memory subsystem被附加到cpu_mem_cg的hierarchy。而net_cls subsystem被附加到net_cls hierarchy。并且httpd进程被同时加到了cpu_mem_cg hierarchy的cg1 cgroup中和net hierarchy的cg3 cgroup中。并通过两个hierarchy的subsystem分别对httpd进程进行cpu,memory及网络带宽的限制。



![规则3](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/docker/cgroup%E8%A7%84%E5%88%993.jpg?raw=true)



#### 规则4

**系统中的任何一个task(Linux中的进程)fork自己创建一个子task(子进程)时，子task会自动的继承父task cgroup的关系，在同一个cgroup中，但是子task可以根据需要移到其它不同的cgroup中。父子task之间是相互独立不依赖的。**

如下图,httpd进程在cpu_and_mem hierarchy的/cg1 cgroup中并把PID 4537写到该cgroup的tasks中。之后httpd(PID=4537)进程fork一个子进程httpd(PID=4840)与其父进程在同一个hierarchy的统一个cgroup中，但是由于父task和子task之间的关系独立不依赖的，所以子task可以移到其它的cgroup中。


![规则4](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/docker/cgroup%E8%A7%84%E5%88%994.jpg?raw=true)


### Subsystem 子系统类型

cgroups 中的子系统就是一个资源调度控制器(又叫 controllers)，类型有：
- **blkio** 对块设备的 IO 进行限制。
- **cpu** 限制 CPU 时间片的分配，与 cpuacct 挂载在同一目录。
- **cpuacct** 生成 cgroup 中的任务占用 CPU 资源的报告，与 cpu 挂载在同一目录。
- **cpuset** 给 cgroup 中的任务分配独立的 CPU(多处理器系统) 和内存节点。
- **devices** 允许或禁止 cgroup 中的任务访问设备。
- **freezer** 暂停/恢复 cgroup 中的任务。
- **hugetlb** 限制使用的内存页数量。
- **memory** 对 cgroup 中的任务的可用内存进行限制，并自动生成资源占用报告。
- **net_cls** 使用等级识别符（classid）标记网络数据包，这让 Linux 流量控制器（tc 指令）可以识别来自特定 cgroup 任务的数据包，并进行网络限制。
- **net_prio** 允许基于 cgroup 设置网络流量(netowork traffic)的优先级。
- **perf_event** 允许使用 perf 工具来监控 cgroup。
- **pids** 限制任务的数量。
- **Hierarchy**(层级) 层级有一系列 cgroup 以一个树状结构排列而成，每个层级通过绑定对应的子系统进行资源控制。层级中的 cgroup 节点可以包含零个或多个子节点，子节点继承父节点挂载的子系统。一个操作系统中可以有多个层级。



Linux 中查看所有的 Subsystem 子系统类型可以通过：
```shell
cat /proc/cgroups
```

例如：
```shell
root@ubuntu:~# cat /proc/cgroups
#subsys_name    hierarchy       num_cgroups     enabled
cpuset  0       101     1
cpu     0       101     1
cpuacct 0       101     1
blkio   0       101     1
memory  0       101     1
devices 0       101     1
freezer 0       101     1
net_cls 0       101     1
perf_event      0       101     1
net_prio        0       101     1
hugetlb 0       101     1
pids    0       101     1
rdma    0       101     1
misc    0       101     1

```



### Subsystem 配置参数介绍


#### 1. blkio - BLOCK IO 资源控制

限额类限额类是主要有两种策略:
- 一种是基于完全公平队列调度（CFQ：Completely Fair Queuing ）的按权重分配各个 cgroup 所能占用总体资源的百分比
    - 好处是当资源空闲时可以充分利用，但只能用于最底层节点 cgroup 的配置；
- 一种则是设定资源使用上限
    - 这种限额在各个层次的 cgroup 都可以配置，但这种限制较为生硬，并且容器之间依然会出现资源的竞争。



1. **按比例分配块设备 IO 资源**
    - **blkio.weight** 
        - 填写 100-1000 的一个整数值，作为相对权重比率，作为通用的设备分配比。
    - **blkio.weight_device**
        - 针对特定设备的权重比，写入格式为 `device_types:node_numbers weight`，空格前的参数段指定设备，weight参数与blkio.weight相同并覆盖原有的通用分配比。
        - 查看一个设备的 device_types:node_numbers 可以使用：`ls -l /dev/DEV`，看到的用逗号分隔的两个数字就是。也可以也称之为major_number:minor_number。


2. **控制 IO 读写速度上限**
    - **blkio.throttle.read_bps_device**
        - 按每秒读取块设备的数据量设定上限，格式 `device_types:node_numbers bytes_per_second`
    - **blkio.throttle.write_bps_device**
        - 按每秒写入块设备的数据量设定上限，格式`device_types:node_numbers bytes_per_second`
    - **blkio.throttle.read_iops_device**
        - 按每秒读操作次数设定上限，格式`device_types:node_numbers operations_per_second`
    - **blkio.throttle.write_iops_device**
        - 按每秒写操作次数设定上限，格式`device_types:node_numbers operations_per_second`
    - **blkio.throttle.io_serviced**
        - 针对特定操作 (read, write, sync, 或 async) 按每秒操作次数设定上限，格式`device_types:node_numbers operation operations_per_second`
    - **blkio.throttle.io_service_bytes**
        - 针对特定操作 (read, write, sync, 或 async)按每秒数据量设定上限，格式`device_types:node_numbers operation bytes_per_second`


3. **统计与监控 以下内容都是只读的状态报告，通过这些统计项更好地统计、监控进程的 io 情况**
    - **blkio.reset_stats**
        - 重置统计信息，写入一个 int 值即可。
    - **blkio.time**
        - 统计 cgroup 对设备的访问时间，按格式`device_types:node_numbers milliseconds`读取信息即可，以下类似。
    - **blkio.io_serviced**
        - 统计 cgroup 对特定设备的 IO 操作（包括 read、write、sync 及 async）次数，格式`device_types:node_numbers operation number`
    - **blkio.sectors**
        - 统计 cgroup 对设备扇区访问次数，格式 `device_types:node_numbers sector_count`
    - **blkio.io_service_bytes**
        - 统计 cgroup 对特定设备 IO 操作（包括 read、write、sync 及 async）的数据量，格式`device_types:node_numbers operation bytes`
    - **blkio.io_queued**
        - 统计 cgroup 的队列中对 IO 操作（包括 read、write、sync 及 async）的请求次数，格式`number operation`    
    - **blkio.io_service_time**
        - 统计 cgroup 对特定设备的 IO 操作（包括 read、write、sync 及 async）时间 (单位为 ns)，格式`device_types:node_numbers operation time`
    - **blkio.io_merged**
        - 统计 cgroup 将 BIOS 请求合并到 IO 操作（包括 read、write、sync 及 async）请求的次数，格式``number operation`
    - **blkio.io_wait_time**
        - 统计 cgroup 在各设备中各类型IO 操作（包括 read、write、sync 及 async）在队列中的等待时间(单位 ns)，格式`device_types:node_numbers operation time`
    - **blkio.recursive_***
        - 各类型的统计都有一个递归版本，Docker 中使用的都是这个版本。获取的数据与非递归版本是一样的，但是包括 cgroup 所有层级的监控数据。


#### 2. cpu - CPU 资源控制

CPU 资源的控制也有两种策略:
- 一种是完全公平调度 （CFS：Completely Fair Scheduler）策略，提供了限额和按比例分配两种方式进行资源控制；
- 一种是实时调度（Real-Time Scheduler）策略，针对实时进程按周期分配固定的运行时间。配置时间都以微秒（µs）为单位，文件名中用us表示。


1. **设定CPU使用的周期和使用的时间上限**
- **cpu.cfs_period_us**
    - 设定周期时间，必须与cfs_quota_us配合使用。
- **cpu.cfs_quota_us**
    - 设定周期内最多可使用的时间。
    - 这里的配置指 task 对单个 cpu 的使用上限，若cfs_quota_us是cfs_period_us的两倍，就表示在两个核上完全使用。数值范围为 1000 - 1000,000（微秒）。
- **cpu.stat**
    - 统计信息，包含nr_periods（表示经历了几个cfs_period_us周期）、nr_throttled（表示 task 被限制的次数）及throttled_time（表示 task 被限制的总时长）。

2. **按权重比例设定 CPU 的分配**
- **cpu.shares**
    - 设定一个整数（必须大于等于 2）表示相对权重，最后除以权重总和算出相对比例，按比例分配 CPU 时间。
    - 例如 ：cgroup A 设置 100，cgroup B 设置 300，那么 cgroup A 中的 task 运行 25% 的 CPU 时间。对于一个 4 核 CPU 的系统来说，cgroup A 中的 task 可以 100% 占有某一个 CPU，这个比例是相对整体的一个值。

3. **RT 调度策略下的配置 实时调度策略与公平调度策略中的按周期分配时间的方法类似，也是在周期内分配一个固定的运行时间。**
- **cpu.rt_period_us**
    - 设定周期时间。
- **cpu.rt_runtime_us**
    - 设定周期中的运行时间。


4. **cpuacct - CPU 资源报告**: 提供 CPU 资源用量的统计，时间单位都是纳秒
- **cpuacct.usage**
    - 统计 cgroup 中所有 task 的 cpu 使用时长
- **cpuacct.stat**
    - 统计 cgroup 中所有 task 的用户态和内核态分别使用 cpu 的时长
- **cpuacct.usage_percpu**
    - 统计 cgroup 中所有 task 使用每个 cpu 的时长

5. **cpuset - CPU 绑定**: 为 task 分配独立 CPU 资源的子系统，参数较多，这里只选讲两个必须配置的参数，同时 Docker 中目前也只用到这两个。
- **cpuset.cpus**
    - 在这个文件中填写 cgroup 可使用的 CPU 编号，如0-2,16代表 0、1、2 和 16 这 4 个 CPU。
- **cpuset.mems**
    - 与 CPU 类似，表示 cgroup 可使用的 memory node，格式同上



#### 3. device - 限制 task 对 device 的使用

1. 设备黑/白名单过滤
- **devices.allow**
    - 允许名单，语法`type device_types:node_numbers access type` 
    - type有三种类型：b（块设备）、c（字符设备）、a（全部设备）；
    - access也有三种方式：r（读）、w（写）、m（创建）。
- **devices.deny**
    - 禁止名单，语法格式同上。 统计报告
- **devices.list**
    - 报告为这个 cgroup 中的task 设定访问控制的设备


#### 4. freezer - 暂停 / 恢复 cgroup 中的 task

只有一个属性，表示进程的状态，把 task 放到 freezer 所在的 cgroup，再把 state 改为 FROZEN，就可以暂停进程。不允许在 cgroup 处于 FROZEN 状态时加入进程。
- **freezer.state** 
    - 包括如下三种状态:
        - FROZEN 停止
        - FREEZING 正在停止，这个是只读状态，不能写入这个值。 - THAWED 恢复



#### 5. memory - 内存资源管理

1. 限额类
    - **memory.limit_bytes**
        - 强制限制最大内存使用量，单位有k、m、g三种，填-1则代表无限制。
    - **memory.soft_limit_bytes**
        - 软限制，只有比强制限制设置的值小时才有意义。填写格式同上。
        - 当整体内存紧张的情况下，task 获取的内存就被限制在软限制额度之内，以保证不会有太多进程因内存挨饿。
        - 可以看到，加入了内存的资源限制并不代表没有资源竞争。
    - **memory.memsw.limit_bytes**
        - 设定最大内存与 swap 区内存之和的用量限制。填写格式同上。

2. 报警与自动控制
    - **memory.oom_control**
        - 该参数填 0 或 1。0表示开启，当 cgroup 中的进程使用资源超过界限时立即杀死进程； 1表示不启用。
        - 默认情况下，包含 memory 子系统的 cgroup 都启用。
        - 当oom_control不启用时，实际使用内存超过界限时进程会被暂停直到有空闲的内存资源。

3. 统计与监控类
- **memory.usage_bytes**
    - 报告该 cgroup 中进程使用的当前总内存用量（以字节为单位）
- **memory.max_usage_bytes**
    - 报告该 cgroup 中进程使用的最大内存用量
- **memory.failcnt**
    - 报告内存达到在 memory.limit_in_bytes 设定的限制值的次数
- **memory.stat**
    - 包含大量的内存统计数据。
- **cache**
    - 页缓存，包括 tmpfs（shmem），单位为字节。
- **rss**
    - 匿名和 swap 缓存，不包括 tmpfs（shmem），单位为字节。
- **mapped_file**
    - memory-mapped 映射的文件大小，包括 tmpfs（shmem），单位为字节
- **pgpgin**
    - 存入内存中的页数
- **pgpgout**
    - 从内存中读出的页数
- **swap**
    - swap 用量，单位为字节
- **active_anon**
    - 在活跃的最近最少使用（least-recently-used，LRU）列表中的匿名和 swap 缓存，包括 tmpfs（shmem），单位为字节
- **inactive_anon**
    - 不活跃的 LRU 列表中的匿名和 swap 缓存，包括 tmpfs（shmem），单位为字节
- **active_file**
    - 活跃 LRU 列表中的 file-backed 内存，以字节为单位
- **inactive_file**
    - 不活跃 LRU 列表中的 file-backed 内存，以字节为单位
- **unevictable**
    - 无法再生的内存，以字节为单位
- **hierarchical_memory_limit**
    - 包含 memory cgroup 的层级的内存限制，单位为字节
- **hierarchical_memsw_limit**
    - 包含 memory cgroup 的层级的内存加 swap 限制，单位为字节



## Cgroup的使用

使用 cgroups 的方式有几种：
- 使用 cgroups 提供的虚拟文件系统，直接通过创建、读写和删除目录、文件来控制 cgroups
- 使用命令行工具，比如 libcgroup 包提供的 cgcreate、cgexec、cgclassify 命令
- 使用 rules engine daemon 提供的配置文件
- systemd、lxc、docker 这些封装了 cgroups 的软件也能让你通过它们定义的接口控制 cgroups 的内容




### 通过文件系统直接操作 cgroup

#### 1. 查看 cgroups 挂载信息

```shell
$ mount -t cgroup
cgroup on /sys/fs/cgroup/systemd type cgroup (rw,nosuid,nodev,noexec,relatime,xattr,name=systemd)
cgroup on /sys/fs/cgroup/rdma type cgroup (rw,nosuid,nodev,noexec,relatime,rdma)
cgroup on /sys/fs/cgroup/cpuset type cgroup (rw,nosuid,nodev,noexec,relatime,cpuset)
cgroup on /sys/fs/cgroup/cpu,cpuacct type cgroup (rw,nosuid,nodev,noexec,relatime,cpu,cpuacct)
cgroup on /sys/fs/cgroup/freezer type cgroup (rw,nosuid,nodev,noexec,relatime,freezer)
cgroup on /sys/fs/cgroup/net_cls,net_prio type cgroup (rw,nosuid,nodev,noexec,relatime,net_cls,net_prio)
cgroup on /sys/fs/cgroup/memory type cgroup (rw,nosuid,nodev,noexec,relatime,memory)
cgroup on /sys/fs/cgroup/blkio type cgroup (rw,nosuid,nodev,noexec,relatime,blkio)
cgroup on /sys/fs/cgroup/pids type cgroup (rw,nosuid,nodev,noexec,relatime,pids)
cgroup on /sys/fs/cgroup/perf_event type cgroup (rw,nosuid,nodev,noexec,relatime,perf_event)
cgroup on /sys/fs/cgroup/hugetlb type cgroup (rw,nosuid,nodev,noexec,relatime,hugetlb)
cgroup on /sys/fs/cgroup/devices type cgroup (rw,nosuid,nodev,noexec,relatime,devices)

```


#### 2. 创建 cgroup

1. 首先，要创建并挂载一个hierarchy (Cgroup 树)，也就是一个目录
```shell
root@ubuntu:~/docker_demo/cgroup# pwd
/root/docker_demo/cgroup
# 创建一个 hierarchy
root@ubuntu:~/docker_demo/cgroup# mkdir cgroup-test
```
2. 挂在一个 hierarchy。
```shell
root@ubuntu:~/docker_demo/cgroup# mount -t cgroup -o none,name=cgroup-test cgroup-test cgroup-test/
root@ubuntu:~/docker_demo/cgroup# ls cgroup-test/
cgroup.clone_children  cgroup.procs  cgroup.sane_behavior  notify_on_release  release_agent  tasks
```

这些文件就是这个hierarchy中cgroup根节点的配置项，上面这些文件的含义分别如下：
- **cgroup.clone_children**
    - cpuset的subsystem会读取这个配置文件，如果这个值是1(默认是0），子cgroup才会继承父cgroup的cpuset的配置。
- **cgroup.procs**
    - 是树中当前节点cgroup中的进程组ID，现在的位置是在根节点，这个文件中会有现在系统中所有进程组的ID
- **notify_on_release** 和 **release_agent** 一起使用。
    - notify_on_release标识当这个cgroup最后一个进程退出的时候是否执行了release_agent; 
    - release_agent则是一个路径，通常用作进程退出之后自动清理掉不再使用的cgroup。
- **tasks**
    - 标识该cgroup下面的进程ID，如果把一个进程ID写到tasks文件中，便会将相应的进程加入到这个cgroup中



#### 3. 创建 cgroup

创建 cgroup，可以直接用 mkdir 在对应的hierarchy中创建一个目录

在刚刚创建的hierarchy（根cgroup节点）上创建两个子cgroup，分别是 cgroup1 和 cgroup2：
```shell
root@ubuntu:~/docker_demo/cgroup# cd cgroup-test/
root@ubuntu:~/docker_demo/cgroup/cgroup-test# mkdir cgroup-1
root@ubuntu:~/docker_demo/cgroup/cgroup-test# mkdir cgroup-2

root@ubuntu:~/docker_demo/cgroup/cgroup-test# tree
.
├── cgroup-1
│   ├── cgroup.clone_children
│   ├── cgroup.procs
│   ├── notify_on_release
│   └── tasks
├── cgroup-2
│   ├── cgroup.clone_children
│   ├── cgroup.procs
│   ├── notify_on_release
│   └── tasks
├── cgroup.clone_children
├── cgroup.procs
├── cgroup.sane_behavior
├── notify_on_release
├── release_agent
└── tasks

```
可以看到，新建的两个文件夹就是两个 cgroup，Linux Kernel 会将这两个子 cgroup 继承其父 cgroup 的属性。


#### 4. 在 cgroup 中运行进程

**一个进程在一个Cgroups的hierarchy中，只能在一个cgroup节点上存在**，系统的所有进程都会默认在根节点上存在，可以将进程移动到其他cgroup节点，只需要将进程ID写到移动到的cgroup节点的tasks文件中即可。
```shell
root@ubuntu:~/docker_demo/cgroup/cgroup-test/cgroup-1# echo $$
1334
root@ubuntu:~/docker_demo/cgroup/cgroup-test/cgroup-1# echo $$ > tasks
root@ubuntu:~/docker_demo/cgroup/cgroup-test/cgroup-1# cat /proc/1334/cgroup
5:name=cgroup-test:/cgroup-1
0::/user.slice/user-0.slice/session-1.scope
```
可以看到当前进程 1334 已经加入到了 从cgroup-test 的 cgroup-1 中了


#### 5. 设置 cgroup 参数

一般系统已经为我们创建一个根 hierarchy，那就是 /sys/fs/cgroup .

我们可以在这个目录下新建 子 Cgroup 来限制资源，设置子 从group 参数也很简单：
```shell
echo 0-1 > /sys/fs/cgroup/cpuset/mycgroup/cpuset.cpus
```

注意，这里 cgroup v1 和 cgroup v2 在目录结构上不同，后面在分析 docker 时作简单介绍。


#### 6. 删除 cgroup

```shell
rmdir /sys/fs/cgroup/cpu/mycgroup/
# 或者 
umount /xx/cgroup-test
```




### 通过 cgroup-tools 工具操作 cgroup

#### 1. 查看 cgroups 挂载信息

lssubsys 可以查看系统中存在的 subsystems：
```shell
$ lssubsys -am
cpuset /sys/fs/cgroup/cpuset
cpu,cpuacct /sys/fs/cgroup/cpu,cpuacct
blkio /sys/fs/cgroup/blkio
memory /sys/fs/cgroup/memory
devices /sys/fs/cgroup/devices
freezer /sys/fs/cgroup/freezer
net_cls,net_prio /sys/fs/cgroup/net_cls,net_prio
perf_event /sys/fs/cgroup/perf_event
hugetlb /sys/fs/cgroup/hugetlb
pids /sys/fs/cgroup/pids
rdma /sys/fs/cgroup/rdma
```

#### 2. 创建 cgroup

`cgcreate` 可以用来为用户创建指定的 cgroups：

下面命令表示在 /sys/fs/cgroup/cpu 和 /sys/fs/cgroup/memory 目录下面分别创建 cgroup-1 目录，也就是为 cpu 和 memory 子资源创建对应的 cgroup。
```shell
cgcreate -a gsh -t gsh -g cpu,memory:cgroup-1
ls cpu/test1 
cgroup.clone_children  cpuacct.stat   cpuacct.usage_all     cpuacct.usage_percpu_sys   cpuacct.usage_sys   cpu.cfs_period_us  cpu.shares  notify_on_release
cgroup.procs           cpuacct.usage  cpuacct.usage_percpu  cpuacct.usage_percpu_user  cpuacct.usage_user  cpu.cfs_quota_us   cpu.stat    tasks
```

选项说明：
- `-t` 指定 tasks 文件的用户和组，也就是指定哪些人可以把任务添加到 cgroup 中，默认是从父 cgroup 继承
- `-a` 指定除了 tasks 之外所有文件（资源控制文件）的用户和组，也就是哪些人可以管理资源参数
- `-g` 指定要添加的 cgroup，冒号前是逗号分割的子资源类型，冒号后面是 cgroup 的路径（这个路径会添加到对应资源 mount 到的目录后面）。也就是说在特定目录下面添加指定的子资源



#### 3. 设置 cgroup 的参数

cgset 命令可以设置某个子资源的参数，比如如果要限制某个 cgroup 中任务能使用的 CPU 核数：
```shell
cgset -r cpuset.cpus=0-1 /mycgroup
```
说明：
- -r 后面跟着参数的键值对，每个子资源能够配置的键值对都有自己的规定


cgset 还能够把一个 cgroup 的参数拷贝到另外一个 cgroup 中：
```shell
cgset --copy-from group1/ group2/
```

#### 4. 删除 cgroup


cgdelete 可以删除对应的 cgroups，它和 cgcreate 命令类似，可以用 -g 指定要删除的 cgroup：
```shell
cgdelete -g cpu,memory:test1
```
说明：
- cgdelete 也提供了 -r 参数可以递归地删除某个 cgroup 以及它所有的子 cgroup。
- 如果被删除的 cgroup 中有任务，这些任务会自动移到父 cgroup 中。



#### 5. 运行进程到某个 cgroup 中

cgexec 执行某个程序，并把程序添加到对应的 cgroups 中：
```shell
cgexec -g memory,cpu:gsh bash
```


cgroups 是可以有层级结构的，因此可以直接创建具有层级关系的 cgroup，然后运行在该 cgroup 中：
```shell
cgcreate -g memory,cpu:groupname/foo
cgexec -g memory,cpu:groupname/foo bash
```


#### 6. 把已经运行的进程移动到某个 cgroup

要把某个已经存在的程序（能够知道它的 pid）移到某个 cgroup，可以使用 cgclassify 命令，比如把当前 bash shell 移入到特定的 cgroup 中：
```shell
cgclassify -g memory,cpu:/mycgroup $$
```
说明：
- 如果同时移动多个进程，最后的pid 参数用空格隔开，可以加入多个



## cgroup v1 与 v2

### cgroup v2版本的区别

之前谈到的规则，都是针对 cgroup v1 版本的，v2版本做了一些改动，Ubuntu 21.04已经开始默认支持 cgroup v2 版本。


v2 相较于 v1，主要有以下不同:
- **Cgroups v2 中所有的controller都会被挂载到一个unified hierarchy下**，不在存在像v1中允许不同的controller挂载到不同的hierarchy的情况
    - 也就是，现在所有的 cgroup 都被挂载在同一个 hierarchy 下
- Proess只能绑定到cgroup的根(“/“)目录和cgroup目录树中的叶子节点
- **通过cgroup.controllers和cgroup.subtree_control指定哪些controller可以被使用**
- v1版本中的task文件和cpuset controller中的cgroup.clone_children文件被移除
- 当cgroup为空时的通知机制得到改进，通过cgroup.events文件通知
- 支持线程模式


可以使用下面命令将Cgroups v2挂载到文件系统，并且所有可用的controller会自动被挂载进去。
```
mount -t cgroup2 none $MOUNT_POINT
```


如果在v2版本，在 /sys/fs/cgroup 目录下新建一个 cgroup，都会有如下目录：
```shell
root@ubuntu:/sys/fs/cgroup# ls
cgroup.controllers      cgroup.threads         dev-mqueue.mount  io.stat                        sys-kernel-config.mount
cgroup.max.depth        cpu.pressure           init.scope        memory.numa_stat               sys-kernel-debug.mount
cgroup.max.descendants  cpuset.cpus.effective  io.cost.model     memory.pressure                sys-kernel-tracing.mount
cgroup.procs            cpuset.mems.effective  io.cost.qos       memory.stat                    system.slice
cgroup.stat             cpu.stat               io.pressure       misc.capacity                  user.slice
cgroup.subtree_control  dev-hugepages.mount    io.prio.class     sys-fs-fuse-connections.mount

```
v2版本需要注意：
- `cgroup.controllers`
    - 这是一个read-only文件。包含了该Cgroup下所有可用的controllers。
    - 和`cgroup.subtree_control`文件 是用来控制 子 Cgroup 节点可以使用的 子系统控制器。
- `cgroup.subtree_control`
    - 这个文件中包含了该Cgroup下已经被开启的controllers。
    - 并且`cgroup.subtree_control`中包含的controllers是`cgroup.controllers`文件controller的子集。
    - `cgroup.subtree_control`文件内容格式如下,controller之间使用空格间隔，前面用”+”表示启用,使用”-“表示停用。比如下面的例子:
    ```shell
    echo '+pids -memory' > x/y/cgroup.subtree_control
    ```
- `cgroup.procs`
    
    - 用来关联进程Id。这个文件在V1版本使用列举线程组Id的。
- `tasks`
    - 文件用来 关联进程信息，只有叶子节点有此文件。
- `cgroup.max.depth`
    - 这个文件定义子cgroup的最大深度。
    - 0意味着不能创建cgroup。如果尝试创建cgroup，会报EAGAIN错误；max表示没有限制，默认值是max。
- `cgroup.max.descendants`
    - 当前可以创建的活跃cgroup目录的最大数量，默认值”max”表示不限制。超过限制，返回EAGAIN。
- `cgroup.threads`
    - Cgroup v2 版本支持线程模式，将 threaded 写入到 cgroup.type 就会开启 Thread模式。
    - 当开始线程模式后，一个进程的所有线程属于同一个cgroup，会采用Tree结构进行管理。



### cgroup v2 版本的子系统资源

cgroup v2 版本的子系统资源与 v1 有很多不同，详见：

[Cgroup](https://facebookmicrosites.github.io/cgroup2/docs/overview.html)


### cgroup v2版本的实例

1. 在终端中，首先获取该终端进程的 pid ，通过 stress 命令，占用一定的内存，
```shell
# 查看当前终端的 pid
root@ubuntu:~# echo $$
2520

# 开启一个进程，占用 200m 内存
root@ubuntu:~# stress --vm-bytes 200m --vm-keep -m 1
stress: info: [2985] dispatching hogs: 0 cpu, 0 io, 1 vm, 0 hdd

# 在新的终端中，top查看占用内存情况，可以看到，一共8g内存，占用2.5%， 也就是 0.2g
root@ubuntu:~# top
top - 08:12:11 up  8:54,  3 users,  load average: 0.40, 0.50, 0.26
Tasks: 172 total,   2 running, 170 sleeping,   0 stopped,   0 zombie
%Cpu(s): 25.4 us,  1.6 sy,  0.0 ni, 73.0 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st
MiB Mem :   7917.6 total,   6516.6 free,    573.0 used,    828.0 buff/cache
MiB Swap:   4096.0 total,   4096.0 free,      0.0 used.   7092.1 avail Mem

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   2986 root      20   0  208508 204920    268 R 100.0   2.5   0:12.97 stress
```
2. 其次在 /sys/fs/cgroup 目录下，新建一个 cgroup ，也就是新建一个目录 cgourp-gsh
```shell
root@ubuntu:~# cd /sys/fs/cgroup/
root@ubuntu:/sys/fs/cgroup# mkdir cgroup-gsh
root@ubuntu:/sys/fs/cgroup# cd cgroup-gsh/
root@ubuntu:/sys/fs/cgroup/cgroup-gsh# ls
cgroup.controllers      cgroup.subtree_control  cpuset.cpus.effective  cpu.weight.nice  memory.events.local  memory.stat
cgroup.events           cgroup.threads          cpuset.cpus.partition  io.max           memory.high          memory.swap.current
cgroup.freeze           cgroup.type             cpuset.mems            io.pressure      memory.low           memory.swap.events
cgroup.kill             cpu.idle                cpuset.mems.effective  io.prio.class    memory.max           memory.swap.high
cgroup.max.depth        cpu.max                 cpu.stat               io.stat          memory.min           memory.swap.max
cgroup.max.descendants  cpu.max.burst           cpu.uclamp.max         io.weight        memory.numa_stat     pids.current
cgroup.procs            cpu.pressure            cpu.uclamp.min         memory.current   memory.oom.group     pids.events
cgroup.stat             cpuset.cpus             cpu.weight             memory.events    memory.pressure      pids.max
```
3. 设置刚刚新建的 cgroup-gsh 的内存的最大限额为 100m
```shell
# 设置最大内存限额 100m
root@ubuntu:/sys/fs/cgroup/cgroup-gsh# echo "100m" > memory.high
root@ubuntu:/sys/fs/cgroup/cgroup-gsh# cat memory.high
104857600
```
4. 将第一步中的终端进程的pid，加入到 cgroup-gsh 中
```shell
root@ubuntu:/sys/fs/cgroup/cgroup-gsh# echo 2520 >> cgroup.procs
root@ubuntu:/sys/fs/cgroup/cgroup-gsh# cat cgroup.procs
2520
```
5. 在次在第一步的终端中，运行 stress 占用 200m 内存，top 查看
```shell
# 可以发现，内存占用量已经变为 8g % 1.3% 也就是 100m
top - 08:29:51 up  9:12,  3 users,  load average: 0.91, 0.96, 0.78
Tasks: 172 total,   2 running, 170 sleeping,   0 stopped,   0 zombie
%Cpu(s):  0.2 us, 15.1 sy,  0.0 ni, 84.2 id,  0.3 wa,  0.0 hi,  0.3 si,  0.0 st
MiB Mem :   7917.6 total,   6617.3 free,    471.7 used,    828.6 buff/cache
MiB Swap:   4096.0 total,   3986.1 free,    109.9 used.   7193.2 avail Mem

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   3077 root      20   0  208508 101688    268 R  71.4   1.3   0:38.66 stress
```



## docker 中的 cgroup


### docker 在 cgroup 中的目录结构(V2版本)


1. 首先，我在ubuntu中运行了两个 container，如下所示：
```shell
root@ubuntu:~# docker ps
CONTAINER ID   IMAGE                      COMMAND                  CREATED        STATUS         PORTS                                                                                                                                                 NAMES
dd96987d56df   ubuntu                     "bash"                   16 hours ago   Up 2 seconds                                                                                                                                                         nostalgic_mcclintock
47b8c46c7f16   rabbitmq:3.10-management   "docker-entrypoint.s…"   7 days ago     Up 7 seconds   4369/tcp, 5671/tcp, 0.0.0.0:5672->5672/tcp, :::5672->5672/tcp, 15671/tcp, 15691-15692/tcp, 25672/tcp, 0.0.0.0:15672->15672/tcp, :::15672->15672/tcp   rabbitmq

```

2. 我们来看看 docker 在 cgroup 中的目录结构
    - v1 版本的 cgroup，docker 会在 /sys/fs/cgroup 目录下直接建一个 docker 的 cgroup 来管理所有的容器
    - 不同于 v1，v2 版本的 cgroup，docker 在 /sys/fs/cgroup/system.slice 目录下
    - 如下所示，在 system.slice 目录下，有两个 docker 开头的文件夹，这就是我们启动的两个 容器 所在的子 cgroup。
    - docker-[CONTAINER_ID] 可以看到 docker 后面跟的 container id 与 docker ps 显示的一致。
```shell
root@ubuntu:/sys/fs/cgroup# cd system.slice/
root@ubuntu:/sys/fs/cgroup/system.slice# ls
 ...
 docker-47b8c46c7f1631b08e28c9f92d1896b6e79b8c348376a48f35b0907f2111a79c.scope
 docker-dd96987d56df355b0149e0c04cbadcddd08f4e578b13557460a9e6d2ceec21ce.scope 
```


3. 在第一步启动的两个容器中，以 ubuntu 为镜像的容器启动命令为：`docker  run  -itd  -m  128m  ubuntu`
    - 这里限制该容器的最大内存使用量
    - 对照 nostalgic_mcclintock 容器的 id，进入到 cgroup 中查看
```shell
root@ubuntu:/sys/fs/cgroup/system.slice/docker-dd96987d56df355b0149e0c04cbadcddd08f4e578b13557460a9e6d2ceec21ce.scope# ls
cgroup.controllers      cpu.idle               cpu.uclamp.min            hugetlb.2MB.events.local  memory.events.local  memory.swap.high
cgroup.events           cpu.max                cpu.weight                hugetlb.2MB.max           memory.high          memory.swap.max
cgroup.freeze           cpu.max.burst          cpu.weight.nice           hugetlb.2MB.rsvd.current  memory.low           misc.current
cgroup.kill             cpu.pressure           hugetlb.1GB.current       hugetlb.2MB.rsvd.max      memory.max           misc.max
cgroup.max.depth        cpuset.cpus            hugetlb.1GB.events        io.max                    memory.min           pids.current
cgroup.max.descendants  cpuset.cpus.effective  hugetlb.1GB.events.local  io.pressure               memory.numa_stat     pids.events
cgroup.procs            cpuset.cpus.partition  hugetlb.1GB.max           io.prio.class             memory.oom.group     pids.max
cgroup.stat             cpuset.mems            hugetlb.1GB.rsvd.current  io.stat                   memory.pressure      rdma.current
cgroup.subtree_control  cpuset.mems.effective  hugetlb.1GB.rsvd.max      io.weight                 memory.stat          rdma.max
cgroup.threads          cpu.stat               hugetlb.2MB.current       memory.current            memory.swap.current
cgroup.type             cpu.uclamp.max         hugetlb.2MB.events        memory.events             memory.swap.events


# 查看最大内存的配置，134217728 是字节，134217728 / 1024 / 1024 = 128m
root@ubuntu:/sys/fs/cgroup/system.slice/docker-dd96987d56df355b0149e0c04cbadcddd08f4e578b13557460a9e6d2ceec21ce.scope# cat memory.max
134217728
```



### 用 Go 实现 Cgroup（v2）限制容器资源

在看代码之前，了解几个概念：
- `/proc/pid`目录：每一个/proc/pid目录中还存在一系列目录和文件，这些文件和目录记录的都是关于pid对应进程的信息
- `/proc/self`目录：这是一个link,当进程访问此链接时，就会访问这个进程本身的/proc/pid目录
```shell
root@ubuntu:~# ls -al  /proc/self
lrwxrwxrwx 1 root root 0 Jul  9 23:17 /proc/self -> 11715
```
- `/proc/self/exe` 代表当前程序


下面就是 go 实现的一个简单的 demo：
```go
package main

import (
        "fmt"
        "io/ioutil"
        "os"
        "os/exec"
        "path"
        "strconv"
        "syscall"
        "time"
)

// cgroup v2 版本的root hierarchy 路径
const cgroupRootHierarchyPath = "/sys/fs/cgroup"

func main() {

        // 判断是否是当前进程，主进程会fork一个新的进程运行 "/proc/self/exe"
        if os.Args[0] == "/proc/self/exe" {
                // 容器进程
                // 获取 容器内的 pid
                fmt.Printf("current pid %d", syscall.Getpid())
                fmt.Println()
                time.Sleep(2 * time.Second)

                // 在容器内，执行stress进程，占用 200m 内存
                cmd := exec.Command("sh", "-c", `stress --vm-bytes 200m --vm-keep -m 1`)

                cmd.SysProcAttr = &syscall.SysProcAttr{}

                // 设置容器内（子进程）的输入、输出、错误到标准的输入、输出、错误
                cmd.Stdin = os.Stdin
                cmd.Stdout = os.Stdout
                cmd.Stderr = os.Stderr

                // 容器中运行 stress 程序
                if err := cmd.Run(); err != nil {
                        fmt.Println(err)
                        os.Exit(1)
                }

        }

        // 下面是主进程
        // 主进程就运行当前的 golang 程序
        cmd := exec.Command("/proc/self/exe")
        // 设置主进程 fork 出子进程的 namespace 隔离
        cmd.SysProcAttr = &syscall.SysProcAttr{
                Cloneflags: syscall.CLONE_NEWNS | syscall.CLONE_NEWUTS | syscall.CLONE_NEWPID,
        }

        // 设置子进程的输入、输出、错误到标准的输入、输出、错误
        cmd.Stdin = os.Stdin
        cmd.Stdout = os.Stdout
        cmd.Stderr = os.Stderr

        // 主进程fork子进程，并且运行程序
        if err := cmd.Start(); err != nil {
                fmt.Println("ERROR", err)
                os.Exit(1)
        } else { // 在主进程中，设置 cgroup
                // 获取 fork 出来的进程，映射到外部命名空间的pid
                fmt.Println("%v", cmd.Process.Pid)

                // 在/sys/fs/cgroup 中创建一个 cgroup
                os.Mkdir(path.Join(cgroupRootHierarchyPath, "cgroup-gsh"), 0755)

                // 将容器进程加入到该 cgroup 中
                ioutil.WriteFile(path.Join(cgroupRootHierarchyPath, "cgroup-gsh", "cgroup.procs"), []byte(strconv.Itoa(cmd.Process.Pid)), 0644)

                // 设置该 cgroup 的内存最大限额为 100m
                ioutil.WriteFile(path.Join(cgroupRootHierarchyPath, "cgroup-gsh", "memory.high"), []byte("100m"), 0644)

        }

        cmd.Process.Wait()

}

```

说明：
- 我在子进程，也就是容器进程中，sleep 了两秒，因为如果不等待，子进程会先执行 stress 使用内存，但是不清楚什么原因，当父进程在stress之后将子进程pid加入到 cgroup 中并限制内存时，已经超量的内存并不会降低。
- 但是，如果限制内存在100m，stress 使用内存200m，再次修改 cgroup 的内存限额为 200m 时，内存使用量会变大。
- 结论：
    - **已经运行的程序，如果加入到cgroup中，并且超过内存限额，不会减少**
    - **已经运行的程序，如果加入到cgroup中，并且内存在限额范围之内，但是如果加大cgroup的内存限额，程序的内存使用量可以变更大**。