[TOC]

# Kubernetes CRI 存储

## PVC 和 PV 的原理

在 Kubernetes 中实际上存在一个专门处理持久化存储的控制器，叫作 **VolumeController**。它维护着多个控制循环，<u>其中一个循环扮演的就是撮合PV和PVC的“红娘”的角色，名叫 PersistentVolumeController</u> 。

- PersistentVolumeController 会不断查看当前每一个 PVC 是否巳经处于 Bound(已绑定）状态。
  
  - 如果不是，它就会遍历所有可用的 PV，并尝试将其与这个“单身”的 PVC 进行绑定。这样，Kubernetes 就可以保证用户提交的每一个PVC，只要有合适的 PV 出现，就能很快地进入绑定状态，从而结束“单身”之旅。
  
  - 所谓将一个 PV 与 PVC 进行＂绑定”，其实就是将这个 PV 对象的名字填在了 PVC 对象的 spec.volumeName 字段上。所以，接下来 Kubernetes 只要获取这个 PVC 对象，就一定能够找到它所绑定的 PV。

### 1. 持久化过程

"持久化" 宿主机目录的过程形象地称为“两阶段处理”:

- 第一阶段(Attach)
  
  - 当一个 Pod 调度到一个节点上之后，kubelet 就要负责为这个 Pod 创建它的 Volume 目录。默认情况下，kubelet 为 Volume 创建的目录是一个宿主机上的路径，如下所示：
    
    ```shell
    /var/lib/kubelet/pods/<Pod的ID>/volumes/kubernetes.io/<Volume类型>/<Volume名字＞
    ```
  
  - 接下来 kubelet 要进行的操作就取决于的 Volume 类型了。例如，如果 Volume 类型是远程块存储，比如 GoogleCloud 的PersistentDisk(GCE提供的远程磁盘服务），那么kubelet就需要先调用 GoolgeCloud 的 API,将它提供的 PersistentDisk 挂载到 Pod 所在的宿主机上。也就是挂载远程存储到本地。
  
  - “第一阶段"( Attach ) , Kubernetes 提供的可用参数是 nodeName，即宿主机的名字。

-   第二阶段(Mount)
  
  - Attach阶段完成后，为了能够使用该远程磁盘，kubelet 还要**格式化**这个磁盘设备，然后**把它挂载到宿主机指定的挂载点上**。不难理解，这个挂载点正是前面反复提到的 Volume 的宿主机目录。所以，这一步相当于执行：
    
    ```shell
    ＃ 通过 lsblk 命令荻取屈盘设备ID
    $ sudo lsblk
    ＃ 格式化成 ext4 格式
    $ sudo mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard /dev/<磁盘设备ID>
    ＃ 挂载到挂载点
    $ sudo mkdir -p /var/lib/kubelet/pods/<Pod 的 ID>/volumes/kubernetes.io/<Volume类型>/<Volume名字＞
    ```
  
  - Mount 阶段完成后，这个 Volume 的宿主机目录就是一个“持久化”的目录了，容器在其中写入的内容会保存在远程磁盘中。
  
  - “第二阶段"( Mount ),  Kubernetes 提供的可用参数是 dir，即 Volume 的宿主机目录

注意：  

如果你的Volume类型是远程文件存储（比如NFS), Kubelet 可以直接跳过第一阶段，因为远程文件存储一般没有一个“存储设备＂需要挂载在宿主机上。所以，k u belet会直接从“第二阶段"(Mount)开始准备宿主机上的 Volume 目录，只需要：

```shell
$  mount -t nfs <NFS服务器地址>:/ /var/lib/kubelet/pods/<Pod 的 ID>/volumes/kubernetes.io/<Volume类型>/<Volume名字＞
```

最终，两个阶段相当于执行了 docker 的命令:

```shell
docker run -v /var/lib/kubelet/pods/<Pod的ID>/volumes/kubernetes.io/<Volurne类型>/<Volume名字＞:/＜容器内的目标目录＞ 我的镜像．．．
```

### 2. 两个阶段的实现

“两阶段处理“流程是靠独立于 kubelet 主控制循环( kubelet sync  loop )的两个控制循环来实现的。

- “第一阶段”的 Attach ( 以及 Detach ) 操作，是由 VolumeController 负责维护的，这个控制循环叫作 AttachDetachControiler。
  
  - 它的作用就是不断检查每一个 Pod 对应的 PV 和该 Pod 所在宿主机之间的挂载情况，从而决定是否需要对这个 PV 进行 Attach ( 或者 Detach ) 操作。
  
  - 作为 Kubernetes 内置的控制器，VolumeController 自然是 kube-controller-manager 的一部分。所以， AttachDetachController 也一定是在 Master 节点上运行的。
  
  - 当然，Attach 操作只需要调用公有云或者具体存储项目的 API, 无须在具体的宿主机上执行操作，所以这个设计没有任何问题。

- “第二阶段”的 Mount ( 以及 Unmount ) 操作，控制循环叫作 VolumeManagerReconciler ，它运行起来之后，是一个独立于 kubelet 主循环的 Goroutine。
  
  - 通过将 Volume 的处理同 kubelet 的主循环解耦，Kubernetes 就避免了这些耗时的远程挂载操作拖慢 kubelet 的主控制循环，进而导致 Pod 的创建效率大幅下降的问题。
  
  - 实际上，kubelet 的一个主要设计原则就是，它的**主控制循环绝对不可以被阻塞**。
  
  - Mount ( 以及 Unmount ) 操作，必须发生在 Pod 对应的宿主机上，所以它必须是 kubelet 组件的一部分。

## StorageClass

PV 一般是管理员去创建，如果系统比较大，那么就会有成千上万个 PV 需要创建，工作量巨大，Kubernetes 提供了一套可以自动创建PY的机制：**Dynamic Provisioning（动态分配）**。

相比之下，前面人工管理 PV 的方式就叫作 Static Provisioning。

**Dynamic Provisioning 机制工作的核心在于一个名为 StorageClass 的 API 对象**。StorageClass 对象的作用其实就是创建 PV 的模板

下面就是一个 StorageClass 的示例：

```yaml
apiVersion: ceph.rook.io/vlbetal
kind: Pool
metadata:
  name:  replicapool
  namespace: rook-ceph
spec:
  replicated: 
    size: 3

---

apiVersion: storage.k8s.io/vl
kind: StorageClass
metadata:
  name: block-service
provisioner: ceph.rook.io/block
parameters:
  pool: replicapool
  #The value of "clusterNamespace" MUST be the same as the one in which your rook  cluster exist
  clusterNamespace: rook-ceph
```

定义好 StorageClass 后，就可以使用 PVC 进行绑定：

```yaml
apiVersion: vl
kind: PersistentVolumeClaim
metadata:
  name: claim1
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: block-service
  resources:
    requests:
      storage: 30Gi
```

有了 Dynamic Provisioning 机制，运维人员只需在 Kubernetes 集群里创建出数量有限的 StorageClass 对象即可，这就好比运维人员在 Kubernetes 集群里创建出了各种 PV 模板。

## LocalPV 的实现

**LocalPV 其实也就是本地持久化数据卷。**

在持久化存储领域，用户呼声最高的定制化需求莫过千<u>支持“本地”持久化存储</u>了。也就是说，用户希望 Kubernetes 能够**直接使用宿主机上的本地磁盘目录，而不依赖远程存储服务来提供“持久化”的容器Volume。**

### 1. LocalPV 适用场景

LocalPV 并不适用于所有应用。事实上，它的适用范围非常固定，比如：

- **高优先级的系统应用，需要在多个节点上存储数据，并且对I/0有较高要求**。

- 典型的应用包括：分布式数据存储，比如MongoDB、Cassandra等，分布式文件系统，比如GlusterFS、Ceph等，以及需要在本地磁盘上进行大批数据缓存的分布式应用

### 2. LocalPV 的实现

实现 LocalPV 有两个难点：

- 第一个难点：如何把本地磁盘抽象成 PV。
  
  - 不应该把宿主机上的目录用作 PV，因为这种本地目录的存储行为完全不可控，它所在的磁盘随时都可能被应用写满，甚至造成整个宿主机宥机。而且，不同本地目录之间也缺乏哪怕最基础的 I/O 隔离机制
  
  - 一个 LocalPV 对应的存储介质，一定是一块**额外挂载在宿主机上的磁盘或者块设备**（＂额外＂的意思是它不应该是宿主机根目录使用的主硬盘）。可以把这项原则称为“**一个 PV­ 一块盘**”。

- 第二个难点：调度器如何保证 Pod 始终能被正确地调度到它所请求的 LocalPV 所在的节点上？
  
  - 之前都是调度器将 POD 调度某一个节点上，但是现在，有可能将节点调度节点上后，该节点并没有对应的本地 PV

由于上面的两个难点，调度器就必须直到所有节点与 LocalPV 对应磁盘的映射关系，然后根据 volume 的映射再来调度 Pod 到对应的节点上。

把这项原则称为“在调度的时候考虑 Volume 分布＂。在K ubernetes 调度器里，有一个叫作 VolumeBindingChecker 的过滤条件专门负责此事。（默认开启）

### 3. LocalPV 的实例

实例：

- Node-1 上有挂载磁盘，作为 LocalPV

- 创建 PV 和 StorageClass

- 创建 Pod 时，默认调度到 Node-1 上

- 最后，查看 Pod 的调度节点
1. 在 Node-1 上创建挂载点
   
   ```shell
   ＃在node-1上执行
   $ mkdir /mnt/disks
   $ for vol in vol1  vol2  vol3; do
       mkdir /mnt/disks/$vol 
       mount -t tmpfs $vol /mnt/disks/$vol
   done
   ```

2. 创建 LocalPV 
   
   - 这里的 local.path 挂载的路径为 /mnt/disks/vol1
   
   - 并且在这个 PV 中，指定了 nodeAffinity，也就是亲和性，为 node-1
   
   - PV 亲和性，调度器在调度 Pod 时，就能够知道一个 PV 与节点的对应关系，从而做出正确的选择。这正是 Kubernetes 实现“在调度的时候就考虑 Volume 分布”的主要方法。
   
   ```yaml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: example-pv
   spec:
     capacity:
       storage: 5Gi
     volumeMode: Filesystem
     accessModes:
     - ReadWriteOnce
     persistentVolumeReclaimPolicy: Delete
     storageClassName: local-storage
     local:
       path: /mnt/disks/vol1
     nodeAffinity: 
       required: 
         nodeselectorTerms:
         - matchExpressions:
           - key: kubernetes.io/hostname
             operator: In
             values:
             - node-1
   ```

3. 创建 StorageClass，使用 PV 和 PVC 的最佳实践是创建一个 StorageClass 来描述这个PV
   
   - **provisioner 字段**，指定的是 no-provisioner。这是因为 LocalPV 目前尚不支持 Dynamic Provisioning，所以它**无法在用户创建 PVC 时就自动创建对应的 PV**。也就是说，前面创建 PV 的操作不可以省略
   
   - `volumeBindingMode=WaitForFirstConsumer` 的属性。它是 LocalPV 里一个非常重要的特性：**延迟绑定**
   
   - 之前的 PV 和 PVC 的绑定，都是在 创建 PVC 后，PVC 和 PV 就已经绑定了，但是延迟绑定不同，当创建 PVC 后不会立即绑定 PV，而是等到第一个使用者创建后，才会取绑定。
   
   ```yaml
   kind: StorageClass
   apiVersion: storage.k8s.io/v1
   metadata:
     name: local-storage
   provisioner: kubernetes.io/no-provisioner
   volumeBindingMode: WaitForFirstConsumer
   ```

4. 创建 PVC
   
   - 当创建 PVC 后，PV 不会立即和 PVC 进行绑定
   
   ```yaml
   kind: PersistentVolumeClaim
   apiVersion: v1
   metadata:
     name: example-local-claim
   spec: 
     accessModes: 
     -ReadWriteOnce
     resources: 
       requests: 
         storage: 5Gi
     storageClassName: local-storage
   ```

5. 创建 Pod
   
   - 创建完 Pod 后，可以发现， PV 和 PVC 才进行绑定，而且最终 Pod 调度到了 Node-1 上
   
   ```yaml
   kind: Pod
   apiVersion: v1
   metadata:
     name: example-pv-pod
   spec: 
     volumes:
     - name: example-pv-storage
       persistentVolumeClaim: 
         claimName: example-local-claim
     containers:
       - name: example-pv-container
         image: nginx
         ports: 
         - containerPort: 80
           name: "http-server"
         volumeMounts: 
         - mountPath: "/usr/share/nginx/html"
           name: example-pv-storage
   ```

### 4. LocalPV 延迟绑定说明

**现在有一个 Pod，它声明使用的 PVC 叫作 pvc-1，并且我们规定这个 Pod 只能在n ode-2 上运行。**

- 在 Kubernetes 集群中，有两个属性（比如大小、读写权限）相同的 Local 类型的 PV。第一个 PV 叫作 pv-1，它对应的磁盘所在的节点是 node-1；第二个 PV 叫作 pv-2，它对应的磁盘所在的节点是 node-2。

- 假设 Kubernetes 的 Volume 控制循环里首先检查到 pvc-1 和 pv-1 的属性是匹配的，于是将二者绑定在一起。

- 然后，你用 kubectl create 创建了这个 Pod。此时问题就出现了。

- 调度器发现这个 Pod 所声明的 pvc-1 已经绑定了 pv-1，而 pv-1 所在的节点是 node-1，根据“调度器必须在调度的时候就考虑Volume分布＂的原则，这个 Pod 自然会被调度到 node-1 上。

- 可是，前面规定这个 Pod 不能在 node-1 上运行。所以，最终这个Pod的调度必然会失败

上面这种现象就可以使用 `volumeBindingMode=WaitForFirstConsumer` 的属性来避免，也就是**延迟绑定**。也就是在创建 PVC 时不立即绑定 PV，而是等到 Pod 创建后，再去根据调度绑定某一个 PV。

### 5. LocalPV 的删除

需要注意的是，前面手动创建 PV 的方式，即 Static 的 PV 管理方式，在删除 PV 时需要按如下流程操作：

1. 删除使用这个 PV 的Pod；

2. 从宿主机移除本地磁盘（比如执行Umount操作）

3. 删除 PVC；

4. 删除PV

如果不按照这个流程执行，删除这个PV的操作就会失败。
