[TOC]

# Kubernetes 调度与资源管理

## kubernetes的资源模型和资源管理

### 1. requests + limits 资源模型

**Pod是kubernetes中最小的调度单元**，与调度和资源管理相关的属性都属于Pod对象的字段（实际上定义在Pod的各容器下），例如

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: frontend
spec:
  containers:
  - name: db
    image: mysql
    env:
    - name: MYSQL_ROOT_PASSWORD
      value: "password"
    resources:
      requests:
        memory: "64Mi"
        cpu: "250m"
      limits:
        memory: "128Mi"
        cpu: "500m"
  - name: wp
    image: wordpress
    resources:
      requests:
        memory: "64Mi"
        cpu: "250m"
      limits:
        memory: "128Mi"
        cpu: "500m"
```

可以看到上面定义了两种类型的资源：

- CPU：一般写作`cpu:“500m”`，表示500milicpu，意味着0.5cpu，也可以直接写成`cpu:0.5`，但这种写法不通用，仍建议使用`m`为单位

- 内存：默认单位时bytes，例如`memory:500Mi`，意味着内存为500 * 1024 * 1024 bytes；`memory:100M`意味着内存为500 * 1000 * 1000 bytes

**资源的分类**

- **可压缩资源**，例如CPU，当其不足时，Pod只会“饥饿”等待，而不会退出
- **不可压缩资源**，例如内存，当其不足时，Pod会被内核kill，OOM（Out Of Memory）

Kubernetes 里 Pod 的 CPU 和内存资源，实际上还要分为 limits 和 requests 两种情况，如下所示：

```shell
spec.containers[].resources.limits.cpu
spec.containers[].resources.limits.memory
spec.containers[].resources.requests.cpu
spec.containers[].resources.requests.memory
```

这里注意：

- **在调度的时候，kube-scheduler 只会按照 requests 的值进行计算。而在真正设置 Cgroups 限制的时候，kubelet 则会按照 limits 的值来进行设置。**

- 当你指定了 requests.cpu=250m 之后，**相当于将 Cgroups 的 cpu.shares 的值设置为 (250/1000)*1024。而当你没有设置 requests.cpu 的时候，cpu.shares 默认则是 1024。这样，Kubernetes 就通过 cpu.shares 完成了对 CPU 时间的按比例分配。**

- 如果你指定了 limits.cpu=500m 之后，**则相当于将 Cgroups 的 cpu.cfs_quota_us 的值设置为 (500/1000)*100ms，而 cpu.cfs_period_us 的值始终是 100ms。这样，Kubernetes 就为你设置了这个容器只能用到 CPU 的 50%。**

- **对于内存来说，当你指定了 limits.memory=128Mi 之后，相当于将 Cgroups 的 memory.limit_in_bytes 设置为 128 * 1024 * 1024。而需要注意的是，在调度的时候，调度器只会使用 requests.memory=64Mi 来进行判断。**

这里为什么使用了 requests + limits 的设计呢？

<u>用户在提交 Pod 时，可以声明一个相对较小的 requests 值供调度器使用，而 Kubernetes 真正设置给容器 Cgroups 的，则是相对较大的 limits 值。</u>当 Pod 启动后，会主动减少其的资源配额，以便可以容纳更多的作业，提高利用率。**简而言之，requests 就是说明 pod 最小需要多少资源，调度时，根据此指标；而 limits 则设置了 pod 的最大资源利用，也就是通过 cgroup 的限制其阈值。**

### 2. QoS 模型

在 Kubernetes 中，**不同的 requests 和 limits 的设置方式，其实会将这个 Pod 划分到不同的 QoS 级别当中。**

QoS 模型分为三种类型：

- **Guaranteed**

- **Burstable**

- **BestEffort**
1. **Guaranteed**
   
   - 当 Pod 里的每一个 Container 都<u>同时设置了 requests 和 limits，并且 requests 和 limits 值相等的时候</u>，这个 Pod 就属于 Guaranteed 类别
   
   - 当 Pod<u> 仅设置了 limits 没有设置 requests 的时候</u>，Kubernetes 会自动为它设置与 limits 相同的 requests 值，所以，这也属于 Guaranteed 情况
   
   - 例如：
     
     ```yaml
     apiVersion: v1
     kind: Pod
     metadata:
       name: qos-demo
     spec:
       containers:
       - name: qos-demo-ctr
         image: nginx
         resources:
           requests:
             memory: "200Mi"
             cpu: "700m"
           limits:
             memory: "200Mi"
             cpu: "700m"
     ```

2. **Burstable**
   
   - 当 Pod 不满足 Guaranteed 的条件（也就是<u> request 和 limits 设置不同），但至少有一个 Container 设置了 requests</u>。那么这个 Pod 就会被划分到 Burstable 类别。
   
   - 例如：
     
     ```yaml
     apiVersion: v1
     kind: Pod
     metadata:
       name: qos-demo
     spec:
       containers:
       - name: qos-demo-ctr
         image: nginx
         resources:
           requests:
             memory: "200Mi"
           limits:
             memory: "100Mi"
     ```

3. **BestEffort**
   
   - 如果一个 <u>Pod 既没有设置 requests，也没有设置 limits</u>，那么它的 QoS 类别就是 BestEffort。
   
   - 例如：
     
     ```yaml
     apiVersion: v1
     kind: Pod
     metadata:
       name: qos-demo
     spec:
       containers:
       - name: qos-demo-ctr
         image: nginx
     ```

**QoS 模型的作用：**

**QoS 划分的主要应用场景，是当宿主机资源紧张的时候，kubelet 对 Pod 进行 Eviction（即资源回收）时需要用到的。**

### 3.  Kubelet Eviction（资源回收）

对于不可压缩的资源，紧缺就相当于不稳定。比如，可用内存（memory.available）、可用的宿主机磁盘空间（nodefs.available），以及容器运行时镜像存储空间（imagefs.available）等等

Kubernetes 的 Eviction 的默认阈值为（这里也可以通过指定 kubelet 的启动参数修改）：

```shell
memory.available<100Mi
nodefs.available<10%
nodefs.inodesFree<5%
imagefs.available<15%
```

kubelet 支持两种文件系统分区。

1. `nodefs`：保存 kubelet 的卷和守护进程日志等。
2. `imagefs`：在容器运行时，用于保存镜像以及可写入层。

imagefs 是可选的。Kubelet 能够利用 cAdvisor 自动发现这些文件系统。Kubelet 不关注其他的文件系统。所有其他类型的配置，例如保存在独立文件系统的卷和日志，都不被支持。

**Eviction 在 Kubernetes 里分为 Soft 和 Hard 两种模式**。

- Soft Eviction 允许你为 Eviction 过程设置一段“优雅时间”。例如 imagefs.available=2m，就意味着当 imagefs 不足的阈值达到 2 分钟之后，kubelet 才会开始 Eviction 的过程。

- Hard Eviction 模式下，Eviction 过程就会在阈值达到之后立刻开始。

**Kubernetes 计算 Eviction 阈值的数据来源，主要依赖于从 Cgroups 读取到的值，以及使用 cAdvisor 监控到的数据。**

**当宿主机的 Eviction 阈值达到后，就会进入 MemoryPressure 或者 DiskPressure 状态，从而避免新的 Pod 被调度到这台宿主机上。**

**当 Eviction 发生的时候，kubelet 具体会挑选哪些 Pod 进行删除操作**，就需要参考这些 Pod 的 QoS 类别了。

- 首当其冲的，自然是 BestEffort 类别的 Pod。
- 其次，是属于 Burstable 类别、**并且**发生“**饥饿”的资源使用量已经超出了 requests 的 Pod。**
- 最后，才是 Guaranteed 类别。并且，Kubernetes 会保证只有当 Guaranteed 类别的 Pod 的资源使用量超过了其 limits 的限制，或者**宿主机本身正处于 Memory Pressure** 状态时，Guaranteed 的 Pod 才可能被选中进行 Eviction 操作。

### 4. CpuSet 设置

CpuSet：**在使用容器的时候，你可以通过设置 cpuset 把容器绑定到某个 CPU 的核上**，而不是像 cpushare 那样共享 CPU 的计算能力。

**由于操作系统在 CPU 之间进行上下文切换的次数大大减少，容器里应用的性能会得到大幅提升。**

设置 CpuSet：

- 首先，你的 Pod 必须是 Guaranteed 的 QoS 类型
- 然后，你只需要将 Pod 的 CPU 资源的 requests 和 limits 设置为同一个相等的**整数**值即可。

```yaml
spec:
  containers:
  - name: qos-demo-ctr
    image: nginx
    resources:
      requests:
        memory: "200Mi"
        cpu: "2"
      limits:
        memory: "200Mi"
        cpu: "2"
```

**该 Pod 就会被绑定在 2 个独占的 CPU 核上。当然，具体是哪两个 CPU 核，是由 kubelet 为你分配的。**

## Kubernetes 默认调度器

### 1. 默认调度器流程

在 Kubernetes 项目中，默认调度器的主要职责，就是为一个新创建出来的 Pod，寻找一个**最合适**的节点（Node）。

而这里“最合适”的含义，包括两层：

1. 从集群所有的节点中，**根据调度算法**挑选出所有**可以运行该 Pod 的节点。**（Predicate）
2. **从第一步的结果中**，再**根据调度算法**挑选一个**最符合条件的节点作为最终结果**。（Priority）

所以在具体的调度流程中，默认调度器

- Predicate 的调度算法，来检查每个 Node。

- 再调用一组叫作 Priority 的调度算法，来给上一步得到的结果里的每个 Node 打分。最终的调度结果，就是得分最高的那个 Node。 

**调度器对一个 Pod 调度成功，实际上就是将它的 spec.nodeName 字段填上调度结果的节点名字。**

在 Kubernetes 中，上述调度机制的工作原理如下图：

![sch_1](./../pic/k8s原理/sch_1.png)

**Kubernetes 的调度器的核心，实际上就是两个相互独立的控制循环。** 

- **第一个控制循环  Informer Path 待调度 Pod 添加进调度队列**
  
  - Informer Path。它的主要目的，<u>是启动一系列 Informer，用来监听（Watch）Etcd 中 Pod、Node、Service 等与调度相关的 API 对象的变化</u>。比如，当一个待调度 Pod（即：它的 nodeName 字段是空的）被创建出来之后，调度器就会通过 Pod Informer 的 Handler，将这个待调度 Pod 添加进调度队列。 
  
  - 在默认情况下，**Kubernetes 的调度队列是一个 PriorityQueue（优先级队列）**，并且当某些集群信息发生变化的时候，调度器还会对调度队列进行调度优先级和抢占的考虑。
  
  - Kubernetes 的默认调度器还要**负责对调度器缓存（即：scheduler cache）进行更新**。Kubernetes 调度部分进行性能优化的一个最根本原则，就是<u>尽最大可能将集群信息 Cache 化，以便从根本上提高 Predicate 和 Priority 调度算法的执行效率</u>。

- **第二个控制循环  Scheduling Path  Predicates 算法进行“过滤” 调用 Priorities 算法为Node 打分**
  
  - Scheduling Path 的主要逻辑是<u>不断地从调度队列里出队一个 Pod。然后，调用 Predicates 算法进行“过滤”</u>。这一步“过滤”得到的一组 Node，就是所有可以运行这个 Pod 的宿主机列表。Predicates 算法需要的 Node 信息，*都是从 Scheduler Cache 里直接拿到的*，这是调度器保证算法执行效率的主要手段之一。
  
  - 接下来，调度器就会<u>再调用 Priorities 算法为上述列表里的 Node 打分，分数从 0 到 10</u>。得分最高的 Node，就会作为这次调度的结果。
  
  - <u>调度算法执行完成后，调度器就需要将 Pod 对象的 nodeName 字段的值，修改为上述 Node 的名字。这个步骤在 Kubernetes 里面被称作 Bind。</u>

### 2. 默认调度器调度策略

上面介绍了调度器的两个步骤：

- Predicates（预选）

- Priorities（优选）

#### Predicates（预选） 策略

Predicates 在调度过程中的作用，可以理解为 Filter，**即：它按照调度策略，从当前集群的所有节点中，“过滤”出一系列符合条件的节点。这些节点，都是可以运行待调度 Pod 的宿主机。**

##### 第一种类型 GeneralPredicates

顾名思义，这一组过滤规则，**负责的是最基础的调度策略**。比如，**PodFitsResources 计算的就是宿主机的 CPU 和内存资源等是否够用。**

前面也提到，PodFitsResources 检查的只是 Pod 的 requests 字段，注意，Kubernetes 的调度器并没有为 GPU 等硬件资源定义具体的资源类型，而是统一用一种名叫 Extended Resource 的、Key-Value 格式的扩展字段来描述的。

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: extended-resource-demo
spec:
  containers:
  - name: extended-resource-demo-ctr
    image: nginx
    resources:
      requests:
        alpha.kubernetes.io/nvidia-gpu: 2
      limits:
        alpha.kubernetes.io/nvidia-gpu: 2
```

通过 `alpha.kubernetes.io/nvidia-gpu=2` 这样的定义方式，声明使用了两个 NVIDIA 类型的 GPU。

一系列 GeneralPredicates 过滤有：

- **PodFitsHost** 检查的是，<u>宿主机的名字是否跟 Pod 的 spec.nodeName 一致。</u>

- **PodFitsHostPorts** 检查的是，<u>Pod 申请的宿主机端口（spec.nodePort）是不是跟已经被使用的端口有冲突</u>。

- **PodMatchNodeSelector** 检查的是，<u>Pod 的 nodeSelector 或者 nodeAffinity 指定的节点，是否与待考察节点匹配</u>

- ...

可以看到，**像上面这样一组 GeneralPredicates，正是 Kubernetes 考察一个 Pod 能不能运行在一个 Node 上最基本的过滤条件**.所以，GeneralPredicates 也会被其他组件（比如 kubelet）直接调用。

##### 第二种类型，与 Volume 相关的过滤规则

这一组过滤规则，负责的是跟容器持久化 Volume 相关的调度策略。

- **NoDiskConflict** 检查的条件，是<u>多个 Pod 声明挂载的持久化 Volume 是否有冲突</u>。比如，AWS EBS 类型的 Volume，是不允许被两个 Pod 同时使用的。

- **MaxPDVolumeCountPredicate** 检查的条件，是<u>一个节点上某种类型的持久化 Volume 是不是已经超过了一定数目</u>，如果是的话，那么声明使用该类型持久化 Volume 的 Pod 就不能再调度到这个节点了。

- **VolumeZonePredicate**，则是<u>检查持久化 Volume 的 Zone（高可用域）标签，是否与待考察节点的 Zone 标签相匹配</u>。

- 此外，还有一个叫作 **VolumeBindingPredicate** 的规则。它负责检查的，是<u>该 Pod 对应的 PV 的 nodeAffinity 字段，是否跟某个节点的标签相匹配</u>。****

##### 第三种类型，是宿主机相关的过滤规则

这一组规则，主要考察待调度 Pod 是否满足 Node 本身的某些条件。

- **PodToleratesNodeTaints**，负责**检查的就是 Node 的“污点”机制**。只有当 Pod 的 Toleration 字段与 Node 的 Taint 字段能够匹配的时候，这个 Pod 才能被调度到该节点上。

- **NodeMemoryPressurePredicate**，检查的是<u>当前节点的内存是不是已经不够充足</u>，如果是的话，那么待调度 Pod 就不能被调度到该节点上。

##### 第四种类型，是 Pod 相关的过滤规则

这一组规则，跟 GeneralPredicates 大多数是重合的。而比较特殊的，是 PodAffinityPredicate。这个规则的作用，**是检查待调度 Pod 与 Node 上的已有 Pod 之间的亲密（affinity）和反亲密（anti-affinity）关系****。比如下面这个例子：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: with-pod-affinity
spec:
  affinity:
    podAffinity: 
      requiredDuringSchedulingIgnoredDuringExecution: 
      - labelSelector:
          matchExpressions:
          - key: security 
            operator: In 
            values:
            - S1 
        topologyKey: failure-domain.beta.kubernetes.io/zone
  containers:
  - name: with-pod-affinity
    image: docker.io/ocpqe/hello-pod
```

注意：

- 该 Pod 只会被调度到已经有携带了 security=S1 标签的 Pod 运行的 Node 上。

- PodAffinityPredicate 是由作用域的，这条规则的**作用域**，则<u>是所有携带 Key 是failure-domain.beta.kubernetes.io/zone标签的 Node</u>。

-  requiredDuringSchedulingIgnoredDuringExecution 字段的含义是：**这条规则必须在 Pod 调度时进行检查（requiredDuringScheduling）**；但是如果是已经在运行的 Pod 发生变化，比如 Label 被修改，造成了该 Pod 不再适合运行在这个 Node 上的时候，**Kubernetes 不会进行主动修正（IgnoredDuringExecution）。**

#### Priorities（优选）策略

 在 Predicates 阶段完成了节点的“过滤”之后，Priorities 阶段的工作就是为这些节点打分。这里打分的范围是 0-10 分，得分最高的节点就是最后被 Pod 绑定的最佳节点。

Priorities 里最常用到的一个打分规则，是 LeastRequestedPriority。它的计算方法，可以简单地总结为如下所示的公式：

```shell
score = (cpu((capacity-sum(requested))10/capacity) + memory((capacity-sum(requested))10/capacity))/2
```

这个算法实际上就是在选择空闲资源（CPU 和 Memory）最多的宿主机。

而与 LeastRequestedPriority 一起发挥作用的，还有 BalancedResourceAllocation。它的计算公式如下所示：

```shell
score = 10 - variance(cpuFraction,memoryFraction,volumeFraction)*10
```

因此，BalancedResourceAllocation 选择的，其实是<u>调度完成后，所有节点里各种资源分配最均衡的那个节点，从而避免一个节点上 CPU 被大量分配、而 Memory 大量剩余的情况</u>。

此外，还有 **NodeAffinityPriority**、**TaintTolerationPriority** 和 **InterPodAffinityPriority** 这三种 Priority。顾名思义，它们与前面的 PodMatchNodeSelector、PodToleratesNodeTaints 和 PodAffinityPredicate 这三个 Predicate 的含义和计算方法是类似的。

但是作为 Priority，一个 Node 满足上述规则的字段数目越多，它的得分就会越高。

在默认 Priorities 里，还有一个叫作 **ImageLocalityPriority** 的策略。它是在 Kubernetes v1.12 里新开启的调度规则，即：<u>如果待调度 Pod 需要使用的镜像很大，并且已经存在于某些 Node 上，那么这些 Node 的得分就会比较高</u>。

当然，为了避免这个算法引发调度堆叠，调度器在<u>计算得分的时候还会根据镜像的分布进行优化，即：如果大镜像分布的节点数目很少，那么这些节点的权重就会被调低，从而“对冲”掉引起调度堆叠的风险</u>。

## Kubernetes 默认调度器的优先级与抢占机制

**优先级和抢占机制，解决的是 Pod 调度失败时该怎么办的问题。**

- 正常情况下，当一个 Pod 调度失败后，它就会被<u>暂时“搁置”</u>起来，直到 Pod 被更新，或者集群状态发生变化，调度器才会对这个 Pod 进行重新调度。

- 但在有时候，我们希望的是这样一个场景。<u>当一个高优先级的 Pod 调度失败后，该 Pod 并不会被“搁置”，而是会“挤走”某个 Node 上的一些低优先级的 Pod 。这样就可以保证这个高优先级 Pod 的调度成功</u>。

要想使用优先级和抢占机制，必须定义一个 PriorityClas 对象。

```yaml
apiVersion: scheduling.k8s.io/v1beta1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000
globalDefault: false
description: "This priority class should be used for high priority service pods only."
```

- 定义的是一个名叫 high-priority 的 PriorityClass，其中 value 的值是 1000000（优先级数值）

- Kubernetes 规定，优先级是一个 32 bit 的整数，最大值不超过 1000000000（10 亿，1 billion），并且值越大代表优先级越高。

- **超出 10 亿的值，其实是被 Kubernetes 保留下来分配给系统 Pod 使用的。显然，这样做的目的，就是保证系统 Pod 不会被用户抢占掉。**

- **globalDefault**被设置为 true 的话，那就意味着这个 PriorityClass 的值会成为系统的默认值。而如果这个值是 false，就表示我们只希望声明使用该 PriorityClass 的 Pod 拥有值为 1000000 的优先级，**而对于没有声明 PriorityClass 的 Pod 来说，它们的优先级就是 0。**

在创建了 PriorityClass 对象之后，Pod 就可以声明使用它了，如下所示：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  labels:
    env: test
spec:
  containers:
  - name: nginx
    image: nginx
    imagePullPolicy: IfNotPresent
  priorityClassName: high-priority
```

- Pod 通过 priorityClassName 字段，声明了要使用名叫 high-priority 的 PriorityClass。

- 当这个 Pod 被提交给 Kubernetes 之后，Kubernetes 的 PriorityAdmissionController 就会自动将这个 Pod 的 spec.priority 字段设置为 1000000。

**调度队列**

**调度器里维护着一个调度队列**。

当 Pod 拥有了优先级之后，<u>高优先级的 Pod 就可能会比低优先级的 Pod 提前出队，从而尽早完成调度过程</u>。这个过程，就是“优先级”这个概念在 Kubernetes 里的主要体现。 

**Pod 调度失败的时候** 

<u>当一个高优先级的 Pod 调度失败的时候，调度器的抢占能力就会被触发</u>。

这时，*调度器就会试图从当前集群里寻找一个节点，使得当这个节点上的一个或者多个低优先级 Pod 被删除后，待调度的高优先级 Pod 就可以被调度到这个节点上*。这个过程，就是“**抢占**”这个概念在 Kubernetes 里的主要体现。

为了方便叙述，接下来会把待调度的高优先级 Pod 称为“抢占者”（Preemptor）。

**抢占过程**

当上述抢占过程发生时，**抢占者并不会立刻被调度到被抢占的 Node 上**。事实上，<u>调度器只会将抢占者的 spec.nominatedNodeName 字段，设置为被抢占的 Node 的名字。然后，抢占者会重新进入下一个调度周期</u>，然后在新的调度周期里来决定是不是要运行在被抢占的节点上。这当然也就意味着，**即使在下一个调度周期，调度器也不会保证抢占者一定会运行在被抢占的节点上。**

这样设计的重要原因是：

1. 调度器只会通过标准的 DELETE API 来删除被抢占的 Pod，所以，这些 Pod 必然是有一定的“优雅退出”时间（默认是 30s）的。

2. 在这段时间里，其他的节点也是有可能变成可调度的，或者直接有新的节点被添加到这个集群中来。

3. 所以，鉴于优雅退出期间，集群的可调度性可能会发生的变化，把抢占者交给下一个调度周期再处理，是一个非常合理的选择。 

4. 而在抢占者等待被调度的过程中，如果有其他更高优先级的 Pod 也要抢占同一个节点，那么调度器就会**清空原抢占者的 spec.nominatedNodeName 字段**，从而允许更高优先级的抢占者执行抢占，并且，这也就使得原抢占者本身，也有机会去重新抢占其他节点。这些，都是设置 nominatedNodeName 字段的主要目的。

### Kubernetes 调度器里的抢占机制

**抢占发生的原因，一定是一个高优先级的 Pod 调度失败**。还是称这个 Pod 为“抢占者”，称被抢占的 Pod 为“牺牲者”（victims）。

而 Kubernetes 调度器实现抢占算法的一个最重要的设计，就是在调度队列的实现里，使用了**两个不同的队列**。

- 第一个队列，叫作 **activeQ**。
  
  - 凡是在 activeQ 里的 Pod，都是下一个调度周期需要调度的对象。
  
  - <u>当你在 Kubernetes 集群里新创建一个 Pod 的时候，调度器会将这个 Pod 入队到 activeQ 里面</u>。
  
  - 调度器不断从队列里出队（Pop）一个 Pod 进行调度，实际上都是从 activeQ 里出队的。 

- 第二个队列，叫作 **unschedulableQ**，专门用来存放调度失败的 Pod
  
  - 当一个 unschedulableQ 里的 Pod 被更新之后，调度器会自动把这个 Pod 移动到 activeQ 里，从而给这些调度失败的 Pod “重新做人”的机会。

调度失败之后，抢占者就会被放进 unschedulableQ 里面。然后，这次失败事件就会**触发调度器为抢占者寻找牺牲者的流程。**

- 第一步，**调度器会检查这次失败事件的原因**，来确认抢占是不是可以帮助抢占者找到一个新节点。
  
  - 因为有很多 Predicates 的失败是不能通过抢占来解决的。比如，PodFitsHost 算法（负责的是，检查 Pod 的 nodeSelector 与 Node 的名字是否匹配），这种情况下，除非 Node 的名字发生变化，否则你即使删除再多的 Pod，抢占者也不可能调度成功。

- 第二步，当遍历完所有的节点之后，调度器会在上述模拟产生的所有抢占结果里做一个选择，找出最佳结果。
  
  - 这一步的判断原则，**就是尽量减少抢占对整个系统的影响**。比如，需要抢占的 Pod 越少越好，需要抢占的 Pod 的优先级越低越好，等等。 

在得到了最佳的抢占结果之后，这个结果里的 Node，就是即将被抢占的 Node；被删除的 Pod 列表，就是牺牲者。所以接下来，调度器就可以真正开始抢占的操作了，这个过程，可以分为三步。

1. 第一步，调度器会检查牺牲者列表，**清理**这些 Pod 所携带的 nominatedNodeName 字段。
2. 第二步，调度器会把抢占者的 nominatedNodeName，**设置为**被抢占的 Node 的名字。
   - 对抢占者 Pod 的更新操作，就会触发到我前面提到的“重新做人”的流程，从而让抢占者在下一个调度周期重新进入调度流程。
3. 第三步，调度器会开启一个 Goroutine，同步地**删除牺牲者**。 
   - 调度器并不保证抢占的结果：在这个正常的调度流程里，是一切皆有可能的。

不过，对于任意一个待调度 Pod 来说，因为有上述抢占者的存在，它的调度过程，其实是有一些特殊情况需要特殊处理的。

具体来说，在为某一对 Pod 和 Node 执行 Predicates 算法的时候，如果待检查的 Node 是一个即将被抢占的节点，即：调度队列里有 nominatedNodeName 字段值是该 Node 名字的 Pod 存在（可以称之为：“潜在的抢占者”）。那么，调度器就会对这个 Node ，将同样的 Predicates 算法运行两遍。

- 第一遍， 调度器会假设上述“潜在的抢占者”已经运行在这个节点上，然后执行 Predicates 算法；
  
  - 这里需要执行第一遍 Predicates 算法的原因，是由于 InterPodAntiAffinity 规则的存在。
  
  - 由于 InterPodAntiAffinity 规则关心待考察节点上所有 Pod 之间的互斥关系，所以我们在执行调度算法时必须考虑，如果抢占者已经存在于待考察 Node 上时，待调度 Pod 还能不能调度成功。
  
  - 当然，这也就意味着，我们在这一步只需要考虑那些优先级等于或者大于待调度 Pod 的抢占者。毕竟对于其他较低优先级 Pod 来说，待调度 Pod 总是可以通过抢占运行在待考察 Node 上。

- 第二遍， 调度器会正常执行 Predicates 算法，即：不考虑任何“潜在的抢占者”。
  
  - 而需要执行第二遍 Predicates 算法的原因，则是因为“潜在的抢占者”最后不一定会运行在待考察的 Node 上。关于这一点，我在前面已经讲解过了：Kubernetes 调度器并不保证抢占者一定会运行在当初选定的被抢占的 Node 上。

而只有这两遍 Predicates 算法都能通过时，这个 Pod 和 Node 才会被认为是可以绑定（bind）的。
