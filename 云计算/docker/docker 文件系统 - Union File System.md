[TOC]

# docker 文件系统 - Union File System

## Union File System

Union File System 联合文件系统：

> 联合文件系统（Union File System，Unionfs）是一种分层的轻量级文件系统，它**可以把多个目录内容联合挂载到同一目录下，从而形成一个单一的文件系统**，这种特性**可以让使用者像是使用一个目录一样使用联合文件系统**。

对于Docker来说，联合文件系统可以说是其镜像和容器的基础。***联文件系统可以使得Docker把镜像做成分层结构，从而使得镜像的每一层都可以被共享***。从而节省大量的存储空间。

UnionFS 的是一种为 Linux FreeBSD NetBSD 操作系统设计的，把其他文件系统联合到一个联合挂载点的文件系统服务。

*   它使用 branch 不同文件系统的文件和目录“透明地”覆盖，形成一个单一一致的文件系统。
*   branch **或者是 read-only 或者是 read-write** 的，所以当对这个虚拟后的联合文件系统进行*写操作的时候，系统是真正写到了一个新的文件中*
*   虚拟后的联合文件系统是可以对任何文件进行操作的 但是其实它并没有改变原来的文件，这是因为 unionfs 用到了一个重要的资源管理技术，**写时复制**。

**写时复制（copy-on-write ，COW）**

*   如果一个资源是重复的，但**没有任何修改**，这时**并不需要立即创建一个新的资源**这个资源可以被新旧实例共享
*   创建新资源发生在第一次写操作，也就是对资源进行修改的时候
*   通过这种资源共享的方式，可以显著地减少未修改资源复制带来的消耗，但是也会在进行资源修改时增加小部分的开销。

说到这里，就不得不提一下 Linux  系统要能运行的话，它至少需要两个文件系统：

*   boot file system（bootfs）
    *   包含 boot loader 和 kernel。
    *   用户不会修改这个文件系统。
    *   **在启动（boot）过程完成后，整个内核都会被加载进内存，此时 bootfs 会被卸载掉从而释放出所占用的内存**。
    *   对于同样内核版本的不同的 Linux 发行版的 bootfs 都是一致的。
*   root file system（rootfs）
    *   包含典型的目录结构，包括 /dev, /proc, /bin, /etc, /lib, /usr, /tmp 等再加上要运行用户应用所需要的所有配置文件，二进制文件和库文件。
    *   该文件系统在不同的 Linux 发行版中是不同的。而且**用户可以对这个文件进行修改**。

对于 docker 来说：

*   所有 Docker 容器都共享主机系统的 bootfs 即 Linux 内核（bootfs 共享宿主机，无法修改）
*   每个容器有自己的 rootfs，它来自不同的 Linux 发行版的基础镜像，包括 Ubuntu，Debian 和 SUSE 等
*   所有基于一种基础镜像的容器都共享这种 rootfs（也就是根据镜像的发行版来决定 rootfs）

联合文件系统更多的是一种概念或者标准，真正实现联合文件系统才是关键，当前Docker中常见的联合文件系统有三种：

*   AUDFS
*   Devicemapper
*   OverlayFS（overlay2 是现在docker正在采用的文件系统）

## UnionFs 的三种类型

### 1. AUFS

#### 概述

AUFS 是联合文件系统，意味着它在主机上使用多层目录存储，每一个目录在 AUFS 中都叫作分支，而在 Docker 中则称之为层（layer），但最终呈现给用户的则是一个普通单层的文件系统，**把多层以单一层的方式呈现出来的过程叫作联合挂载**。

![AUFS文件系统](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/docker/UnionFS-AUFS%E5%8E%9F%E7%90%86.png?raw=true)

**AUFS优点**:

1.  可以在多个运行的container中高效的共享image，可以实现容器的快速启动，并减少磁盘占用量；
2.  共享image-layers的方式，可以高效的是使用page cache

**AUFS缺点**:

1.  性能上不如overlay2；
2.  当文件进行写操作的时候，如果文件过大，或者文件位于底层的image中，则可能会引入高延迟。

#### docker 中的 AUFS

**每一个镜像层和容器层都是 /var/lib/docker 下的一个子目录，镜像层和容器层都在 aufs/diff 目录下。**

每一层的目录名称是镜像或容器的 ID 值，联合挂载点在 aufs/mnt 目录下，**mnt 目录是真正的容器工作目录**。

创建整个容器过程中，aufs文件夹的变化：

*当一个镜像未生成容器时*：

*   **diff文件夹**：*存储镜像内容*，每一层都存储在镜像层 ID 命名的子文件夹中。
*   **layers文件夹**：*存储镜像层关系的元数据*，在 diff 文件夹下的每一个镜像层在这里都会有一个文件，文件的内容为该层镜像的父级镜像的ID
*   **mnt文件夹**：*联合挂载点目录，未生成容器时，该目录为空*

*当一个镜像生成容器后，AUFS存储结构会发生如下变化*：

*   **diff文件夹**：*当容器运行时会在 diff 文件夹下生成容器层*
*   **layers文件夹**：*增加容器相关的元数据*
*   **mnt文件夹**：*容器的联合挂载点，这和容器中看到的文件内容一致*

**docker 中的 AUFS 具体的工作步骤**：

1.  **读取文件**：
    1.  文件在容器层中存在时：当文件存在于容器层时，直接从容器层读取。
    2.  当文件在容器层中不存在时：当容器运行时需要读取某个文件，如果容器层中不存在时，则从镜像层查找该文件，然后读取文件内容。
    3.  文件既存在于镜像层，又存在于容器层：当我们读取的文件既存在于镜像层，又存在于容器层时，将会从容器层读取该文件。（就近）
2.  **修改文件或者目录**：
    1.  第一次修改文件：当我们第一次在容器中修改某个文件时，AUFS 会触发写时复制(COW)操作，AUFS 首先从镜像层复制文件到容器层，然后再执行对应的修改操作。
    2.  删除文件或目录：当文件或目录被删除时，AUFS 并不会真正从镜像中删除它，因为镜像层是只读的，AUFS 会创建一个特殊的文件或文件夹，这种特殊的文件或文件夹会阻止容器的访问

#### 实际操作

下面开始自己动手用简单的命令来创建一个 AUFS 文件系统

1.  创建一个 demo 的根目录，名字叫 aufs。

```shell
[root@localhost file_system]# mkdir aufs
[root@localhost file_system]# cd aufs/
[root@localhost aufs]# pwd
/root/gsh_docker/file_system/aufs
```

1.  在 aufs 目录下创建一个名为 container-layer 文件夹，代表容器层的文件系统
    *   container-layer 文件夹里面有一个名为 container-layer.txt 文件，文件内容为 "I am container layer"

```shell
[root@localhost aufs]# mkdir container-layer
[root@localhost aufs]# touch container-layer/container-layer.txt
[root@localhost aufs]# echo "I am container layer" > container-layer/container-layer.txt
[root@localhost aufs]# cat container-layer/container-layer.txt
I am container layer
[root@localhost aufs]# tree
.
└── container-layer
    └── container-layer.txt
1 directory, 1 file
```

1.  在 aufs 目录下创建四个名为 image-layer{n} 的文件夹，n 取值分别为 1-4，代表容器镜像的四个层级
    *   分别在各个层级中，加入文件 image-layer{n}.txt ，内容为："I am image layer{n}"

```shell
[root@localhost aufs]# mkdir image-layer1 image-layer2 image-layer3 image-layer4
[root@localhost aufs]# echo "I am image layer1" > image-layer1/image-layer1.txt
[root@localhost aufs]# echo "I am image layer2" > image-layer2/image-layer2.txt
[root@localhost aufs]# echo "I am image layer3" > image-layer3/image-layer3.txt
[root@localhost aufs]# echo "I am image layer4" > image-layer4/image-layer4.txt
[root@localhost aufs]# tree
.
├── container-layer
│   └── container-layer.txt
├── image-layer1
│   └── image-layer1.txt
├── image-layer2
│   └── image-layer2.txt
├── image-layer3
│   └── image-layer3.txt
└── image-layer4
    └── image-layer4.txt

5 directories, 5 files
```

1.  在 aufs 目录下创建名为 mnt 的文件夹，代表挂载点。
    *   把 container-layer 和四个名为 image-layer{n} 的文件夹用 AUFS 的方式挂载到刚刚创建的 mnt 目录下。
    *   在 mount aufs 的命令中，没有指定待挂载的五个文件夹的权限，默认的行为是， **dirs 指定的左边起第一个目录是 read-write 权限， 后续的都是 read-only 权限**
    *   在 mount 命令中加入了 xino 的配置，这是为了解决”xino doesn't support /tmp/.aufs.xino(xfs)“ 的问题

```shell
[root@localhost aufs]# mkdir mnt
[root@localhost aufs]# mount -t aufs -o dirs=./container-layer:./image-layer4:./image-layer3:./image-layer2:./image-layer1,xino=/dev/shm/aufs.xino mnt ./mnt
[root@localhost aufs]# tree mnt
mnt
├── container-layer.txt
├── image-layer1.txt
├── image-layer2.txt
├── image-layer3.txt
└── image-layer4.txt

0 directories, 5 files
```

1.  我们来查看一下挂载目录的权限
    *   可以看到：第一个挂载的 container-layer 目录是 rw 读写，后面的所有目录都是 ro 只读的

```shell
> cat /sys/fs/aufs/si_5bebd5231489d4a5/*
/root/gsh_docker/file_system/aufs/container-layer=rw
/root/gsh_docker/file_system/aufs/image-layer4=ro
/root/gsh_docker/file_system/aufs/image-layer3=ro
/root/gsh_docker/file_system/aufs/image-layer2=ro
/root/gsh_docker/file_system/aufs/image-layer1=ro
64
65
66
67
68
/dev/shm/aufs.xino
```

1.  模拟运行容器行为，修改 mnt/image-layer1.txt 文件
    *   往 mnt/image-layer 文件末尾添加一行文字 "write to mnt's image-layer1.txt"

```shell
[root@localhost aufs]# echo -e "\n write to mnt's image-layer4.txt" >> ./mnt/image-layer4.txt
[root@localhost aufs]# cat mnt/image-layer4.txt
I am image layer4

 write to mnt's image-layer4.txt

```

1.  现在根据写时复制（COW），来分析 AUFS 最终做了些什么
    *   首先，mnt 只是一个虚拟挂载点，查看原始的 image-layer4/image-layer4.txt ，发现并没有改动
    ```shell
    [root@localhost aufs]# cat image-layer4/image-layer4.txt
    I am image layer4
    ```
    *   挂载的层级关系由上到下分别是：container-layer(rw) -> image-layer4(ro) -> image-layer3(ro) -> image-layer2(ro) -> image-layer1(ro), 我们查看一下最上层 container-layer 目录，发现多了一个文件
    ```shell
     [root@localhost aufs]# ls container-layer
     container-layer.txt  image-layer4.txt
     [root@localhost aufs]# cat container-layer/image-layer4.txt
     I am image layer4
    
     write to mnt's image-layer4.txt
    ```
    *   也就是说，当尝试向 mnt/image-layer4.txt 文件进行写操作的时候 系统首先在 mnt 目录下 查找名为 image-layer4.txt 文件，将其拷贝到 read-write 层的 container-layer
        目录中，接着对 container-layer 目录中的 image-layer4.txt 文件进行写操作。

### 2. Devicemapper

#### 概述

Devicemapper 是 Linux 内核提供的框架，从 Linux 内核 2.6.9 版本开始引入。

Devicemapper 与 AUFS 不同，AUFS 是一种文件系统，而 **Devicemapper 是一种映射块设备的技术框架**。

Devicemapper 的工作机制主要围绕三个核心概念：

*   **映射设备（mapped device）**：即对外提供的逻辑设备，它是由 Devicemapper 模拟的一个虚拟设备，并不是真正存在于宿主机上的物理设备。
*   **目标设备（target device）**：目标设备是映射设备对应的物理设备或者物理设备的某一个逻辑分段，是真正存在于物理机上的设备。
*   **映射表（map table）**：映射表记录了映射设备到目标设备的映射关系，它记录了映射设备在目标设备的起始地址、范围和目标设备的类型等变量。

映射设备通过映射表关联到具体的物理目标设备。事实上，映射设备不仅可以通过映射表关联到物理目标设备，也可以关联到虚拟目标设备，然后虚拟目标设备再通过映射表关联到物理目标设备。

DeviceMapper 由2个磁盘构成，分别是 metadata 和 data：
![DeviceMapper原理图](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/docker/UnionFS-devicemapper%E7%9A%84%E5%8E%9F%E7%90%86.jpg?raw=true)

#### Devicemapper 的两种模式

devicemapper是RHEL下Docker Engine的默认存储驱动，它有两种配置模式:

*   **loop-lvm**
    *   loop-lvm是默认的模式，它使用OS层面离散的文件来构建精简池(thin pool)。
    *   该模式主要是设计出来让 Docker 能够简单的被”开箱即用(out-of-the-box)”而无需额外的配置。
    *   如果是在生产环境的部署Docker，官方明文不推荐使用该模式。
*   **direct-lvm**
    *   direct-lvm 是 Docker 推荐的生产环境的推荐模式，他使用块设备来构建精简池来存放镜像和容器的数据。

![DeviceMapper两种模式](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/docker/UnionFS-devicemapper%E7%9A%84%E4%B8%A4%E7%A7%8D%E6%A8%A1%E5%BC%8F.jpg?raw=true)

#### Devicemapper 实现镜像分层与共享

Devicemapper 使用专用的块设备实现镜像的存储，并且像 AUFS 一样**使用了写时复制的技术来保障最大程度节省存储空间**，所以 Devicemapper 的镜像分层也是依赖快照来是实现的。

Devicemapper 的每一个镜像层都是其下一层的快照，最底层的镜像层是我们的瘦供给池，通过这种方式实现镜像分层有以下优点：

*   相同的镜像层，仅在磁盘上存储一次。例如，我有 10 个运行中的 busybox 容器，底层都使用了 busybox 镜像，那么 busybox 镜像只需要在磁盘上存储一次即可。
*   快照是写时复制策略的实现，也就是说，当我们需要对文件进行修改时，文件才会被复制到读写层。
*   相比对文件系统加锁的机制，Devicemapper 工作在块级别，因此可以实现同时修改和读写层中的多个块设备，比文件系统效率更高。

操作流程:

*   当我们需要读取数据时，如果数据存在底层快照中，则向底层快照查询数据并读取。
*   当我们需要写数据时，则向瘦供给池动态申请存储空间生成读写层，然后把数据复制到读写层进行修改。Devicemapper 默认每次申请的大小是 64K 或者 64K 的倍数，因此每次新生成的读写层的大小都是 64K 或者 64K 的倍数。

### 3. OverlayFS

#### 概述

OverlayFS 是一个现代的联合文件系统，它类似于AUFS，但是速度更快，实现更简单。

Docker为OverlayFS提供了两种存储驱动:原始的 overlay 和更新且更稳定的 overlay2。将 Linux内核驱动称为 OverlayFS, Docker 存储驱动称为 overlay 或 overlay2。

**docker 默认使用 overlay2 驱动程序而不是 overlay，因为 overlay2 在inode利用率方面更有效**。

#### overlay2 原理

overlayFS 则是联合挂载技术的一种实现，与 aufs 类似，overalyFS 驱动有2种：overlay2 和 overlay，**overlay2 是相对于 overlay 的一种改进，在 inode 利用率方面比 overlay 更有效**。

overlayfs 通过三个目录来实现：

*   **lower 目录**
    *   可以是多个，是处于最底层的目录，作为**只读层**
    *   **lowerdir 是只读的镜像层(image layer)**，其中就包含 bootfs 和 rootfs 层：
        *   bootfs(boot file system) 主要包含 bootloader 和 kernel，bootloader 主要是引导加载 kernel，当 boot 成功 kernel 被加载到内存中，bootfs 就被 umount 了
        *   rootfs(root file system) 包含的就是典型 Linux 系统中的 /dev、/proc、/bin、/etc 等标准目录
*   **upper 目录**
    *   只有一个，作为**读写层**
    *   其实就是 Container 层，在启动一个容器的时候会在最后的image层的上一层自动创建，所有对容器数据的更改都会发生在这一层。
*   **work 目录**
    *   为工作基础目录，挂载后内容会被清空，且**在使用过程中其内容用户不可见**
*   **merged 目录**: 三种目录合并出来的目录
    *   为最后联合挂载完成给用户呈现的统一视图，也就是说 **merged 目录里面本身并没有任何实体文件**，给我们展示的只是参与联合挂载的目录里面文件而已
    *   **真正的文件还是在 lower 和 upper 中**。所以，在 merged 目录下编辑文件，或者直接编辑 lower 或 upper 目录里面的文件都会影响到 merged 里面的视图展示。
    *   也就是说，只要 container 层中有此文件，便展示container层中的文件内容，若 container 层中没有，则展示 image 层中的

![overlay2原理](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/docker/UnionFS-overlay2%E5%8E%9F%E7%90%86.PNG?raw=true)

通过上图可以发现：

*   镜像层是 lowerdir ，容器层是 upperdir. 联合视图通过文件夹 merged 展现出来，并有效地挂载到容器里。
*   整个过程类似于 git merge 的过程，从上到下，如果有重复的文件，上层就会**掩盖**掉下层的同名文件。
*   overlay2 驱动程序仅适用于两层。这意味着多层 image 镜像不能实现为多个 OverlayFS 层。相比于比AUFS，查找搜索都更快

**overlay2 驱动程序原生支持最多 128个 lower 层**。 该功能为与层相关的Docker命令(如Docker build和Docker commit)提供了更好的性能，并且在后备文件系统上消耗更少的inode。

**注意事项**

*   **copy\_up 操作只发生在文件首次写入，以后都是只修改副本(写时复制)**
*   overlayfs 只适用两层目录，相比于 AUFS，查找搜索都更快。
*   **容器层的文件删除只是一个"障眼法"，是靠 whiteout 文件将其遮挡，image 层并没有删除**，这也就是为什么++使用 docker commit 提交保存的镜像会越来越大，无论在容器层怎么删除数据，image层都不会改变++。

#### overlay2 读取文件、修改文件步骤

**++读取文件++**：容器内进程读取文件分为以下三种情况:

*   **文件在容器层中存在**：当文件存在于容器层并且不存在于镜像层时，直接从容器层读取文件；
*   **当文件在容器层中不存在**：当容器中的进程需要读取某个文件时，如果容器层中不存在该文件，则从镜像层查找该文件，然后读取文件内容；
*   **文件既存在于镜像层，又存在于容器层**：当我们读取的文件既存在于镜像层，又存在于容器层时，将会从容器层读取该文件。

**++修改文件或目录++**：overlay2 对文件的修改采用的是**写时复制**的工作机制，这种工作机制可以最大程度节省存储空间。具体的文件操作机制如下:

*   **第一次修改文件**：当我们第一次在容器中修改某个文件时，overlay2 会触发写时复制操作，overlay2 首先从镜像层复制文件到容器层，然后在容器层执行对应的文件修改操作。
*   **删除文件或目录**：当文件或目录被删除时，overlay2 并不会真正从镜像中删除它，因为镜像层是只读的，overlay2 会创建一个特殊的文件或目录，这种特殊的文件或目录会阻止容器的访问。

#### docker 中的 overlay2

docker 默认的存储目录在 `/var/lib/docker/`，也可以查看镜像的信息来找到存储目录：

```shell
[root@localhost etc]# docker inspect ubuntu:20.04
...
        "GraphDriver": {
            "Data": {
                "MergedDir": "/var/lib/docker/overlay2/abfc0aa191c267d658c15c3ae8712b6b548a28e05d9b6d397989aa6e06c8438c/merged",
                "UpperDir": "/var/lib/docker/overlay2/abfc0aa191c267d658c15c3ae8712b6b548a28e05d9b6d397989aa6e06c8438c/diff",
                "WorkDir": "/var/lib/docker/overlay2/abfc0aa191c267d658c15c3ae8712b6b548a28e05d9b6d397989aa6e06c8438c/work"
            },
            "Name": "overlay2"
        },
...
```

查看 /var/lib/docker 目录，如下所示:

```shell
[root@localhost docker]# pwd
/var/lib/docker
[root@localhost docker]# ls
buildkit  containers  image  network  overlay2  plugins  runtimes  swarm  tmp  trust  volumes
```

*   containers：是容器目录，每启动一个容器便会在这里记录
*   image: 存储镜像管理数据的目录
*   network: docker的网关、容器的IP地址等信息
*   overlay2: Docker存储驱动，常见的有overlay、overlay2、aufs
*   volumes: 卷管理目录

##### 1. contains 目录

首先，启动了两个容器，分别是 nenux 和 mysql-test

```shell
[root@localhost containers]# docker ps
CONTAINER ID   IMAGE                    COMMAND                  CREATED          STATUS          PORTS                                                  NAMES
224d5cdd45ec   mysql                    "docker-entrypoint.s…"   41 minutes ago   Up 41 minutes   0.0.0.0:3306->3306/tcp, :::3306->3306/tcp, 33060/tcp   mysql-test
82bce47695b0   sonatype/nexus3:latest   "sh -c ${SONATYPE_DI…"   4 months ago     Up 23 hours                                                            nexus
```

在 /var/lib/docker/contains/ 目录下，可以看到有两个文件夹，文件夹名字对应的是 启动容器ID:

```shell
[root@localhost containers]# pwd
/var/lib/docker/containers
[root@localhost containers]# ls
224d5cdd45ece672195025cae3dd18f6a16987bf6bf0919cc084a04800aee789
82bce47695b06dd88828bda4c062f35cef7c3e1da3ad78e3f089d24ee3dedda9
```

找到对应 mysql-test 的容器，224d5cdd45ec 开头的文件夹中，查看对应的文件信息：

```shell
[root@localhost 224d5cdd45ece672195025cae3dd18f6a16987bf6bf0919cc084a04800aee789]# ls
224d5cdd45ece672195025cae3dd18f6a16987bf6bf0919cc084a04800aee789-json.log  hostconfig.json  mounts
checkpoints                                                                hostname         resolv.conf
config.v2.json                                                             hosts            resolv.conf.hash
```

*   hosts, hostname resolv.conf 都是容器中的配置信息
*   mounts 表示容器的挂载信息
*   config.v2.json 表示容器的详细信息
*   hostconfig.json 表示容器的 cpu、内存等配置信息
*   xxx-json.log 表示容器运行过程中的 日志信息

##### 2. image 目录（重要）

在 /var/lib/docker/image 目录下，当前使用的存储引擎是 overlay2，因此只有 一个目录名字叫 "overlay2"，如果之前有使用过别的存储引擎，例如 aufs 等，会有不同的目录。

```shell
[root@localhost image]# pwd
/var/lib/docker/image
[root@localhost image]# ls
overlay2
[root@localhost image]# tree -L 2 overlay2/
overlay2/
├── distribution
│   ├── diffid-by-digest
│   └── v2metadata-by-diffid
├── imagedb
│   ├── content
│   └── metadata
├── layerdb
│   ├── mounts
│   ├── sha256
│   └── tmp
└── repositories.json

10 directories, 1 file

```

可以看到，在overlay2目录下，最主要的就是 imagedb 和 layerdb 目录：

*   layerdb
    *   tmp: 临时文件，不用管
    *   mounts: 如果我们启动一个容器，便可以发现Docker会在layerdb目录下新生成一个mounts目录，mounts目录下有着以容器ID命名的文件，其内部记录了容器层layer的元数据信息：
    *   sha256: 针对每个 layerid（使用chainID保存） 的详细信息
*   imagedb
    *   content: 保存 image 具体详细的信息，包括 image 包括了那些 layer
    *   metadata: 保存 image 的元数据

***

image 是由多个 layer 组合而成的，而 layer 又是一个共享的层，可能有多个 image 会指向同一个 layer。

那如何才能确认image包含了哪些layer呢？答案就在imagedb这个目录中。

```shell
[root@localhost image] pwd
/var/lib/docker/image/overlay2/imagedb/content/sha256
[root@localhost image] ls
031acd2d33c7f2252f6437cc91df319ae9b8f583fa79bb7cc8326480a7a6593d
29768cc0970f8a41c04d7cc43f6c23a8e52eaaa9cdeefaf3529720b7999c10ec
451450fcf10789c989da7d93dc5d08615f392b9b9a09073e1cfde6cecba40e35
54c9d81cbb440897908abdcaa98674db83444636c300170cfd211e40a66f704f
56f2ec1313357ebdc2e344f9ebae2cb50e2dfe5e7aba57442937dbf976dac403
589f7296a4a2c2c65c73d635976e718120edf8b75951dcbbc737b39f6178de06
5d0da3dc976460b72c77d94c8a1ad043720b0416bfc16c52c45d4847e53fadb6
605c77e624ddb75e6110f997c58876baa13f8754486b461117934b24a9dc3a85
734a461bdaf74d9dcc9f51acd3ff85e63db49408664ffec06ca54411c0f2fb5c
7a2f515f57e72d82d3b1e232844ec87f25993f7143efbbcf39ef6e551e452826
8234082ee653d65b400098b1b5d4cf88ab14bdea0df71a30efd01e3d454500c8
...

[root@localhost image] docker images
REPOSITORY                                            TAG       IMAGE ID       CREATED         SIZE
mysql                                                 latest    8234082ee653   13 days ago     444MB

```

可以看到，mysql 的image id 8234082ee653 就是在 imagedb 中的 8234082ee653d65b400098b1b5d4cf88ab14bdea0df71a30efd01e3d454500c8 文件。查看文件内容可以得到：

```shell
[root@localhost image] cat 8234082ee653d65b400098b1b5d4cf88ab14bdea0df71a30efd01e3d454500c8 | jq .
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:c6c89a36c214d7ecf7a684bf0fc21692dd60e9f204f48545bcb4085185166031",
      "sha256:bd0f2368b7ff2649b60c162b722e2ef3c1a9eb5b9a9c6e7dccc6a9f8ba555dec",
      "sha256:f7d7cec5fa509573882b24162d3a5c4364187a868b38d6012b1e442afdee9313",
      "sha256:af0f418e1b53e2c41d8335cee13bb7b37d2d2da28858956f7084219106b0a101",
      "sha256:7491cd840f35ef3b088f196d362a2050af007582613b41d857f636fbd14ec019",
      "sha256:52dca70f3e0a3bd63cae5c8a005d219625da7fd68ab2a5d117acdde147653ef1",
      "sha256:f76c17720785ca75805ab25ceeac6a00e6fc8cc0c256927fd966cdf56543e9b4",
      "sha256:b043ec768dbc033cb900ef2632728723364490dc2315fe6872e1c057bf386099",
      "sha256:4180f7f5cb528991038d2763dc97188e94abe007e990d6fdefa08c9eaa19ffc2",
      "sha256:1522f9d90e57c4e717780fad79d2f57cfbf9f2326250a6c32e7f3c1fa6580297",
      "sha256:8043deb3c8bf0671983cd59c979aa026d7e9e4ffec301eeccd93897851bd4dd7"
    ]
  }
}
```

**最关键的一部分，也就是rootfs**。

*   可以看到 rootfs 的 diff\_ids 是一个包含了 11 个元素的数组，其实这11个元素正是组成 mysql 镜像的 11 个 layerID(diff\_id)
*   **从上往下看，就是底层到顶层**
*   也就是说 c6c89a36c214d7ecf7a684bf0fc21692dd60e9f204f48545bcb4085185166031 是 image 的最底层。
*   既然得到了组成这个 image 的所有 layerID，那么我们就可以带着这些 layerID 去寻找对应的 layer 了。

***

我们再次进入到 layerdb 目录中查看，

```shell
[root@localhost ] pwd
/var/lib/docker/image/overlay2/layerdb
[root@localhost ] ls
mounts  sha256  tmp
```

这里我们只关注 sha256 目录，注意：这个目录下的的 layer 是通过 ChainID 保存的。

```shell
[root@localhost ] pwd
/var/lib/docker/image/overlay2/layerdb/sha256

[root@localhost ] ls
c6c89a36c214d7ecf7a684bf0fc21692dd60e9f204f48545bcb4085185166031
fb63221c965d70bb446da3955db8ae731baa9184866b5fa3170d7c15d62a0cd1
fe0f76c5248c0d91755d6ac1b023fab7a1dc3b6e5f3208328112cb6f763bea31
...
```

可以发现：我们能在上面找到的 mysql 镜像的最底层 c6c89a36c214d7ecf7a684bf0fc21692dd60e9f204f48545bcb4085185166031，而其他 layer id(diff\_id) 则找不到。这是因为：
**layerdb/sha256下的目录名称是以layer的chainID来命名的**，它的计算方式为：

*   如果layer是最底层，没有任何父layer，那么diffID = chainID;
*   否则，`ChainID(layerN) = SHA256hex(ChainID(layerN-1) + " " + DiffID(layerN))`

例如，现在知道最底层的 chainID，求上一层的 chainID:

```shell
# ChainID(layer2) = SHA256hex(ChainID(layer1) + " " + DiffID(layer2))
[root@localhost ] echo -n "sha256:c6c89a36c214d7ecf7a684bf0fc21692dd60e9f204f48545bcb4085185166031 sha256:bd0f2368b7ff2649b60c162b722e2ef3c1a9eb5b9a9c6e7dccc6a9f8ba555dec" | sha256sum | awk '{print $1}'
b758e555d22ee9d83852d14c90d936cfce1a62182b2bd218472dccb9e7be98a4
```

再次在 layerdb 的 sha256 目录中找上一层的 chainID 目录为：

```shell
[root@localhost ] pwd
/var/lib/docker/image/overlay2/layerdb/sha256
[root@localhost ] cd b758e555d22ee9d83852d14c90d936cfce1a62182b2bd218472dccb9e7be98a4
[root@localhost ] ls
cache-id  diff  parent  size  tar-split.json.gz
```

依次类推，能通过 layer 的 diff\_id 能找到所有的 ChainID。

再次来看一下每一层 ChainID 目录下的解构：

*   cache-id: 存储驱动通过cache-id索引到layer的实际文件内容
*   diff: 保存当前layer的 diff\_ID
*   parent: 上一层的 chainid
*   size: 当前 layer 的大小

这里，我们主要关注的是 cache-id，也就是实际 layer 存储的位置

```shell
[root@localhost ] pwd
/var/lib/docker/image/overlay2/layerdb/sha256/b758e555d22ee9d83852d14c90d936cfce1a62182b2bd218472dccb9e7be98a4
[root@localhost ] cat cache-id
4809ba89e26afef80ea8b1b90bcf26b35a37aa22b9a72e644a2a74aaee161514# 
```

记住这里的 4809ba89e26afef80ea8b1b90bcf26b35a37aa22b9a72e644a2a74aaee161514 cahce-id，我们在 overlay2 目录中继续查看

##### 3. overlay2 目录

/var/lib/docker/overlay2 目录下存放的就是镜像每一层的实际文件系统。也就是实际存储文件的地方。

注意：overlay2 目录下有一个 l 目录，保存的均是软链接文件，其文件名是避免使用mount命令时输出结果达到页面大小限制而生成的短名称；

```shell
[root@localhost ] pwd
/var/lib/docker/overlay2
[root@localhost ] ls
fb47b523462b47b178a7f9e76630000bc2c7117b931f80ca6a03fb1bb5902af9-init
fc80364838946ce95b24b3ae118c3589a8e4d20e1a79af41fe5dcd83deca21e7
fd24291382f6a1b053140b3eea7186836437176168919ee1cae3e1a2d8eff79d
fe1a67d2d5df5af7401096547f4fe0e344f31b298e11c7f34d14b255bda45dda
ff6d7634534f8109d3e70cb73ce267bdc392fb0b462431a38539b3801de8ef58
l
...
```

上文提到，layer 元数据中的 cache-id 会索引到 layer 的实际文件，例如上文提到的 mysql 镜像的 layer 第二层的 cache-id 为 4809ba89e26afef80ea8b1b90bcf26b35a37aa22b9a72e644a2a74aaee161514：

```shell
[root@localhost ] pwd
/var/lib/docker/overlay2/4809ba89e26afef80ea8b1b90bcf26b35a37aa22b9a72e644a2a74aaee161514
[root@localhost ] ls
committed  diff  link  lower  work
```

以上文件/目录的表示：

*   diff 目录: 文件存放的实际位置，文件目录，各层的目录都会放在下边
*   link 文件:  写明该存储对应的镜像层
*   lower 文件: 指名该镜像层对应的底层镜像层
*   work 目录: 文件系统的工作基础目录，挂载后内容会被清空，且在使用过程中其内容用户不可见

***

这里我们主要关注 diff 文件，现在来看一下 mysql 镜像第二层的实际文件系统：

```shell
[root@localhost ] pwd
/var/lib/docker/overlay2/4809ba89e26afef80ea8b1b90bcf26b35a37aa22b9a72e644a2a74aaee161514/diff
[root@localhost ] ls
docker-entrypoint-initdb.d  etc  run  var
```

#### OverlayFS 优缺点

OverlayFS优点：

1.  可以在多个运行的container中高效的共享image，可以实现容器的快速启动，并减少磁盘占用量；
2.  支持页缓存共享，可以高效的是使用page cache；
    3、相较于AUFS等，性能更好。

OverlayFS缺点
1、只支持POSIX标准的一个子集，与其他文件系统的存在不兼容性，如对open和rename操作的支持；