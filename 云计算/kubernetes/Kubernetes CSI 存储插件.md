[TOC]

# Kubernetes CSI 存储插件

在 Kubernetes 中，开发存储插件有两种方式：

- **FlexVolume** （弃用）

- **CSI**

## CSI 插件的设计原理

CSI 的设计思路如下图所示：

![](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/k8s/csi/CSI%E8%AE%BE%E8%AE%A1%E6%80%9D%E8%B7%AF.PNG?raw=true)

这套存储插件体系多了 3 个独立的外部组件，即：

- DriverRegistrar

- ExternalProvisioner

- ExternalAttacher

需要注意的是，虽然叫外部组件，但依然由Kubemetes社区开发和维护。

上图中右侧部分就是需要我们编写代码来实现的CSI插件。一个 CSI 插件只有一个二进制文件，但它会以 gRPC 的方式对外提供 3 个服务(gRPCService):

- CSIIdentity

- CSIController

- CSINode。

下面讲解这**3个外部组件**。其中，

1. **DriverRegistrar 组件**：<u>负责将插件注册到 kubelet 中（可以类比为将可执行文件放在插件目录下）</u>。
   
   - 而在具体实现上，DriverRegistrar 需要请求 CSI 插件的 Identity 服务来<u>获取插件信息</u>。

2. **ExternalProvisioner 组件**：<u>负责 Provision 阶段</u>。
   
   - 在具体实现上，<u>ExternalProvisioner 监听(Watch) APIServer 里的 PVC 对象</u>。
   
   - 当一个 PVC 被创建时，它就会<u>调用 CSIController 的 CreateVolume 方法，为你创建对应 PV</u>。
   
   - 此外，如果你使用的存储是公有云提供的磁盘（或者块设备），这一步就需要调用公有云（或者块设备服务）的API来创建这个 PV 所描述的磁盘（或者块设备）了。
   
   - <u>由于 CSI 插件是独立于 Kubernetes 的，因此在 CSI 的 API 里不会直接使用 Kubernetes 定义的 PV 类型，而会自己定义一个单独的 Volume 类型。</u>

3. **ExternalAttacher 组件**：负责 Attach 阶段。
   
   - 在具体实现上，它<u>监听 APIServer 里 VolumeAttachment 对象的变化</u>。
   
   - <u>VolumeAttachment 对象是 Kubernetes 确认一个 Volume 可以进入 Attach 阶段的重要标志</u>。
   
   - <u>一旦出现 VolumeAttachment 对象，ExternalAttacher 就会调用 CSIController 服务的 ControllerPublish 方法，完成它对应的 Volume 的 Attach 阶段</u>。

注意：

**Volume 的 Mount 阶段并不属于外部组件的职责**。

- 当 kubelet 的 VolumeManagerReconciler 控制循环检查到它需要执行 Mount 操作时，会通过 pkg/volume/csi 包直接调用 CSINode 服务完成 Volume 的 Mount 阶段。

- 在实际使用 CSI 插件时，我们会将这 3 个外部组件作为 sidecar 容器和 CSI 插件放置在同一个 Pod 中。由于外部组件对 CSI 插件的调用非常频繁，因此这种 sidecar 的部署方式非常高效

下面讲解 CSI 插件里的 3 个服务：CSIIdentity、CSIController 和 CSINode。

- **CSI Identity 服务**：<u>负责对外暴露这个插件本身的信息</u>

```protobuf
service Identity {
  rpc GetPluginInfo(GetPluginInfoRequest)
    returns (GetPluginInfoResponse) {}

  rpc GetPluginCapabilities(GetPluginCapabilitiesRequest)
    returns (GetPluginCapabilitiesResponse) {}

  rpc Probe (ProbeRequest)
    returns (ProbeResponse) {}
}
```

- **CSI Controller 服务**：定义的是对 CSI Volume (对应Kubemetes里的PV)的管理接口，比如创建和删除 CSI Volume、对 CSI Volume 进行 Attach、Detach(在 CSI 里，这个操作叫作 Publish/Unpublish).以及对 CSI Volume 进行快照等， 其实就是对 PV 的操作，创建 Volume 、删除 Volume 等等，接口如下：

```protobuf
service Controller {
  rpc CreateVolume (CreateVolumeRequest)
    returns (CreateVolumeResponse) {}

  rpc DeleteVolume (DeleteVolumeRequest)
    returns (DeleteVolumeResponse) {}

  rpc ControllerPublishVolume (ControllerPublishVolumeRequest)
    returns (ControllerPublishVolumeResponse) {}

  rpc ControllerUnpublishVolume (ControllerUnpublishVolumeRequest)
    returns (ControllerUnpublishVolumeResponse) {}

  rpc ValidateVolumeCapabilities (ValidateVolumeCapabilitiesRequest)
    returns (ValidateVolumeCapabilitiesResponse) {}

  rpc ListVolumes (ListVolumesRequest)
    returns (ListVolumesResponse) {}

  rpc GetCapacity (GetCapacityRequest)
    returns (GetCapacityResponse) {}

  rpc ControllerGetCapabilities (ControllerGetCapabilitiesRequest)
    returns (ControllerGetCapabilitiesResponse) {}

  rpc CreateSnapshot (CreateSnapshotRequest)
    returns (CreateSnapshotResponse) {}

  rpc DeleteSnapshot (DeleteSnapshotRequest)
    returns (DeleteSnapshotResponse) {}

  rpc ListSnapshots (ListSnapshotsRequest)
    returns (ListSnapshotsResponse) {}

  rpc ControllerExpandVolume (ControllerExpandVolumeRequest)
    returns (ControllerExpandVolumeResponse) {}

  rpc ControllerGetVolume (ControllerGetVolumeRequest)
    returns (ControllerGetVolumeResponse) {
        option (alpha_method) = true;
    }
}
```

- **CSI Node服务**：CSI  Volume 需要在宿主机上执行的操作都定义在了 CSI Node服务中。比如挂载到某一个目录下，解除挂载等等。
  
  - Mount 阶段在 CSI Node 里的接口是由 NodeStageVolume 和 NodePublishVolume 这两个接口共同实现的。

```protobuf
service Node {
  rpc NodeStageVolume (NodeStageVolumeRequest)
    returns (NodeStageVolumeResponse) {}

  rpc NodeUnstageVolume (NodeUnstageVolumeRequest)
    returns (NodeUnstageVolumeResponse) {}

  rpc NodePublishVolume (NodePublishVolumeRequest)
    returns (NodePublishVolumeResponse) {}

  rpc NodeUnpublishVolume (NodeUnpublishVolumeRequest)
    returns (NodeUnpublishVolumeResponse) {}

  rpc NodeGetVolumeStats (NodeGetVolumeStatsRequest)
    returns (NodeGetVolumeStatsResponse) {}


  rpc NodeExpandVolume(NodeExpandVolumeRequest)
    returns (NodeExpandVolumeResponse) {}


  rpc NodeGetCapabilities (NodeGetCapabilitiesRequest)
    returns (NodeGetCapabilitiesResponse) {}

  rpc NodeGetInfo (NodeGetInfoRequest)
    returns (NodeGetInfoResponse) {}
}
```

## CSI 插件编写实例

下面以 [csi-digitalocean](https://github.com/digitalocean/csi-digitalocean) 为例：

DigitalOcean 是业界知名的“最简“公有云服务：只提供虚拟机、存储、网络等几个基础功能，再无其他。而这恰恰使得DigitalOcean 成了我们在公有云上实践 Kubemetes 的最佳选择。

### 1. CSI 插件的使用

有了CSI插件之后，持久化存储的用法就非常简单了，只需要创建一个如下所示的 storage­Class 对象即可：

```yaml
kind: StorageClass
apiVersion: storage.k8s.io/vl
metadata: 
  name: do-block-storage
  namespace: kube-system
  annotations:
    Storageclass.kubernetes.io/is-default-class: "true"
provisioner: com.digitalocean.csi.dobs
```

**有了这个 storageClass，ExternalProvisoner 就会为集群中新出现的 PVC 自动创建 PV，然后调用 CSI 插件创建这个 PV 对应的 Volume，这正是 CSI 体系中 Dynamic Provisioning 的实现方式**。

注意：

唯一引人注意的是 `provisioner=com.digitalocean.csi.dobs` 这个字段。显然，这个字段告诉 Kubenretes 请使用名为`com.digitalocean.csi.dobs` 的 CSI 插件来为我处理这个 StorageClass 相关的所有操作。

下面就以 csi-digitalocean 插件为例，可以看到该插件源码目录下的 driver 目录下定义了上面介绍的几个服务：

```shell
$ cd driver/
$ ls
controller.go  controller_test.go  driver.go  driver_test.go  health.go  health_test.go  identity.go  mounter.go  node.go  paging.go
```

### 2. 启动 GRPC Server

前面也说到过，CSI Identity，CSI Controller，CSI Node 服务，都是需要通过 RPC 方式对外暴露接口，那么需要启动一个 GRPC Server 来对外暴露服务。

为了能让 Kubernetes 访问到 CSI 插件服务，我们需要先在 driver.go 文件里定义一个标准的 gRPCServer，代码（`driver/driver.go`)如下：

```go
// 在指定端点上，启动 GRPC Server
func (d *Driver) Run(ctx context.Context) error {
    ...
    // 启动监听 socket
    grpcListener, err := net.Listen(u.Scheme, grpcAddr)

    ...

    // 创建 GRPC Server
    d.srv = grpc.NewServer(grpc.UnaryInterceptor(errHandler))
    // 注册了三个服务，分别是 CSI Identity，CSI Controller，CSI Node
    csi.RegisterIdentityServer(d.srv, d)
    csi.RegisterControllerServer(d.srv, d)
    csi.RegisterNodeServer(d.srv, d)

    d.ready = true // 准备就绪

    ...

    // 启动 GRPC server
    return d.srv.Serve(grpcListener)
}
```

启动了 GRPC Server 后，那么什么时候调用呢？在 `cmd/do-csi-plugin/main.go` 文件中， 调用了 Run 函数来启动 Grpc Server，如下：

```go
func main() {
    ...

    // 创建一个 driver 对象
    drv, err := driver.NewDriver(driver.NewDriverParams{
        Endpoint:               *endpoint,
        Token:                  *token,
        URL:                    *url,
        Region:                 *region,
        DOTag:                  *doTag,
        DriverName:             *driverName,
        DebugAddr:              *debugAddr,
        DefaultVolumesPageSize: *defaultVolumesPageSize,
        DOAPIRateLimitQPS:      *doAPIRateLimitQPS,
    })

    ...

    // 调用 Driver.Run 函数开启 GrpcServer
    if err := drv.Run(ctx); err != nil {
        log.Fatalln(err)
    }
}
```

### 3. CSI Identity 服务

第一步使用 CSI 时，指定了使用 CSI 插件的名称，那么，Kubernetes 是如何知道一个 CSI 插件的名字的呢？这就需要从 CSI 插件的第一个服务**CSI Identity** 说起。

CSI Identity RPC 服务允许 Kubernetes 查询插件的功能、运行状况和其他元数据。一般需要如下三个方法：

- 查询插件元数据：`GetPluginInfo`

```yaml
# CO --(GetPluginInfo)--> Plugin
request:
response:
  name: org.foo.whizbang.super-plugin
  vendor_version: blue-green
  manifest:
    baz: qazz: qaz
```

- 查询插件的可用功能：`GetPluginCapabilities`

```yaml
# CO --(GetPluginCapabilities)--> Plugin
request:
response:
  capabilities:
    - service:
        type: CONTROLLER_SERVICE
```

- 查询插件是否就绪：`Probe`

```yaml
# CO --(Probe)--> Plugin
request:
response: {}
```

CSI Identity 服务的实现定义在 driver 目录下的 `identity.go` 文件里。

CSI  Identity 服务中最重要的接口是 `GetPlugininfo` ，它**返回的就是这个插件的名字和版本号**，如下所示：

```go
func (d *Driver) GetPluginInfo(ctx context.Context, req *csi.GetPluginInfoRequest) (*csi.GetPluginInfoResponse, error) {
    resp := &csi.GetPluginInfoResponse{
        Name:          d.name,       // 名字
        VendorVersion: version,      // 版本号
    }

    d.log.WithFields(logrus.Fields{
        "response": resp,
        "method":   "get_plugin_info",
    }).Info("get plugin info called")
    return resp, nil
}
```

其中，name 的值是 `com.digitalocean.csi.dobs`。所以，Kubernetes 正是通过 `GetPlugininfo` 的返回值来找到你在 StorageClass 里声明要使用的 CSI 插件的。

`GetPluginCapabiilities` 接口也很重要，它**返回的是这个 CSI 插件的“能力”**。

例如，当你编写的 CSI 插件不准备实现 "Provision阶段” 和 "Attach阶段”（比如一个最简单的NFS存储插件就不需要这两个阶段）时，就可以通过这个接口返回：本插件不提供 CSIController 服务，即没有`csi.PluginCapability_Service_CONTROLLER_SERVICE`这个“能力＂。这样Kubernetes就知道这项信息了。

```go
func (d *Driver) GetPluginCapabilities(ctx context.Context, req *csi.GetPluginCapabilitiesRequest) (*csi.GetPluginCapabilitiesResponse, error) {
    resp := &csi.GetPluginCapabilitiesResponse{
        Capabilities: []*csi.PluginCapability{
            {
                Type: &csi.PluginCapability_Service_{
                    Service: &csi.PluginCapability_Service{
                        Type: csi.PluginCapability_Service_CONTROLLER_SERVICE,
                    },
                },
            },
            {
                Type: &csi.PluginCapability_Service_{
                    Service: &csi.PluginCapability_Service{
                        Type: csi.PluginCapability_Service_VOLUME_ACCESSIBILITY_CONSTRAINTS,
                    },
                },
            },
            {
                Type: &csi.PluginCapability_VolumeExpansion_{
                    VolumeExpansion: &csi.PluginCapability_VolumeExpansion{
                        Type: csi.PluginCapability_VolumeExpansion_ONLINE,
                    },
                },
            },
        },
    }

    d.log.WithFields(logrus.Fields{
        "response": resp,
        "method":   "get_plugin_capabilities",
    }).Info("get plugin capabitilies called")
    return resp, nil
}
```

CSI-DigitalOcean 这里设置了三个能力：

- `csi.PluginCapability_Service_CONTROLLER_SERVICE` 
  
  - 此功能指示驱动程序实现 CSI 控制器服务中的一个或多个方法

- `csi.PluginCapability_Service_VOLUME_ACCESSIBILITY_CONSTRAINTS`
  
  - 此功能表明此驱动程序的卷可能无法从集群中的所有节点均等地访问
  
  - 并且驱动程序将返回额外的拓扑相关信息，Kubernetes 可以使用这些信息更智能地调度工作负载或影响将在何处配置卷。

- `csi.PluginCapability_VolumeExpansion_ONLINE`
  
  - 此功能表示 PV 可否在线扩展

最后，CSI Identity 服务还提供了一个 Probe 接口，**Kubernetes 会调用它来检查这个 CSI 插件是否正常工作**。

一般情况下，建议在编写插件时给它设置一个 Ready 标志，当插件的 gRPCServer 停止时，把这个 Ready 标志设置为 false。或者，你可以在这里访问插件的端口，类似千健康检查的做法。

```go
func (d *Driver) Probe(ctx context.Context, req *csi.ProbeRequest) (*csi.ProbeResponse, error) {
    d.log.WithField("method", "probe").Info("probe called")    
    // 对于 ready 字段的访问，是需要加锁的
    d.readyMu.Lock()
    defer d.readyMu.Unlock()

    return &csi.ProbeResponse{
        Ready: &wrappers.BoolValue{
            Value: d.ready,
        },
    }, nil
}
```

### 4. CSI Controller 服务

CSI 插件的第二个服务，即 CSI Controller 服务。它的代码实现在 `driver/controller.go` 文件里。

服务主要实现的是 Volume 管理流程中的 "Provision阶段” 和 "Attach阶段” 。

- **"Provision阶段”** 对应的接口是 `CreateVolume` 和 `DeleteVolume`，它们的调用者是 `ExternalProvisoner`。
  
  - CreateVolume 其实就是在通过 DigitalOcean 去创建一块 volume 存储（磁盘）。
  
  - 对于 DigitalOcean 这样的公有云来说，**CreateVolume 需要做的就是调用 DigitalOcean 块存储服务的 API，创建出一个存储卷**( d.doClient.Storage.CreateVolume)。
  
  - 如果你使用的是其他类型的块存储（比如 Cinder、CephRBD 等），对应的操作也是类似地调用创建存储卷的 API。

```go
func (d *Driver) CreateVolume(ctx context.Context, req *csi.CreateVolumeRequest) (*csi.CreateVolumeResponse, error) {
    ....

    // godo 就是 digitalocean 自己实现的 块存储服务
    volumeReq := &godo.VolumeCreateRequest{
        Region:        d.region,
        Name:          volumeName,
        Description:   createdByDO,
        SizeGigaBytes: size / giB,
    }

    ....

    // 创建 volume
       vol, _, err := d.storage.CreateVolume(ctx, volumeReq)

    ... 

    // 返回 response
    resp := &csi.CreateVolumeResponse{
        Volume: &csi.Volume{
            VolumeId:      vol.ID,
            CapacityBytes: size,
            AccessibleTopology: []*csi.Topology{
                {
                    Segments: map[string]string{
                        "region": d.region,
                    },
                },
            },
        },
    }

    ...

    log.WithField("response", resp).Info("volume was created")
    return resp, nil


}
```

- **"Attach阶段”** 对应的接口是 `ControllerPublishVolurne` 和 `ControllerUnpublishVolurne` ，它们的调用者是`ExternalAttacher`。
  
  - 对于 DigitalOcean 来说，`ControllerPublishVolume` 在 "Attach阶段＂ **需要做的是调用 DigitalOcean 的 API，将前面创建的存储卷挂载到指定虚拟机(`d.doClient.StorageActions.Attach`)上**。
  
  - 存储卷由请求中的 VolumeId 来指定。而虚拟机，也就是将要运行 Pod 的宿主机，由请求中的 Nodeid 来指定。这些参数都是 `ExternalAttacher` 在发起请求时需要设置的
  
  - 以 `ControllerPublishVolurne`为例，它的逻辑如下所示：

```go
func (d *Driver) ControllerPublishVolume(ctx context.Context, req *csi.ControllerPublishVolumeRequest) (*csi.ControllerPublishVolumeResponse, error) {
    ...
    // 拿到 nodeID
    dropletID, err := strconv.Atoi(req.NodeId)

    ...

    // 根据 VolumeId 获取 Volume ，如果没有找到，则报错
    vol, resp, err := d.storage.GetVolume(ctx, req.VolumeId)

    ...

    // 检查 NodeId 是否存在
    _, resp, err = d.droplets.Get(ctx, dropletID)

    ...

    // 将 volume attach 到 指定的 Node 节点上
    action, resp, err := d.storageActions.Attach(ctx, req.VolumeId, dropletID)

    if action != nil {
        log = logWithAction(log, action)
        log.Info("waiting until volume is attached")
        if err := d.waitAction(ctx, log, req.VolumeId, action.ID); err != nil {
            return nil, status.Errorf(codes.Internal, "failed waiting on action ID %d for volume ID %s to get attached: %s", action.ID, req.VolumeId, err)
        }
    }

    log.Info("volume was attached")
    return &csi.ControllerPublishVolumeResponse{
        PublishContext: map[string]string{
            d.publishInfoVolumeName: vol.Name,
        },
    }, nil
}
```

这里着重介绍一下  **"Attach阶段”**，之前介绍过，External Attacher 的工作原理是监听(Watch)一种名为 `VolumeAttachment` 的API对象。这种API对象的主要字段如下所示：

```go
type VolumeAttachmentSpec struct {
    Attacher    string
    Source      VolumeAttachmentSource
    NodeName    string
}
```

这个对象的生命周期正是由 AttachDetachController 负责管理的。

这个控制循环负责不断检查 Pod 对应的 PV 在它所绑定的宿主机上的挂载清况，从而决定是否需要对这个 PV 进行 Attach (或者 Detach )操作。

在 CSI  体系里，这个 Attach 操作就是创建出上面这样一个 VolumeAttachment 对象。可以看到，**Attach 操作所需的 PV 的名字(Source)、宿主机的名字(NodeName)、存储插件的名字(Attacher)都是这个 VolumeAttachmet 对象的一部分**。

\<u>当 ExternalAttacher 监听到这样的一个对象出现之后，就可以立即使用 VolumeAttachment 里的这些字段，封装出一个 gRPC 请求调用 CSIController 的 ControllerPublishVolume 方法</u>。

### 5. CSI Node 服务

接下来就可以编写  CSI Node 服务了。**CSI Node 服务对应 Volume 管理流程里的 Mount 阶段**。<u>它的代码实现在 `/driver/node.go` 文件里</u>。

上一节提到，kubelet 的 VolumeManagerReconciler 控制循环会直接调用 CSI Node 服务来完成 Volume 的 Mount 阶段。不过，在具体的实现中，这个Mount阶段的处理其实被细分成两个接口：

- NodeStageVolume ：格式化等操作

- NodePublishVolurne ：挂载到对应的宿主机目录

在kubelet的 VolumeManagerReconciler 控制循环中，这两步操作分别叫作

- MountDevice

- SetUp

**MountDevice 操作就是直接调用 CSI Node 服务里的 NodeStageVolume 接口**。

顾名思义，这个接口的作用就是格式化 Volume 在宿主机上对应的存储设备，然后挂载到一个临时目录(Staging目录）上。对于 DigitalOcean 来说，它对 NodeStageVolume接口的实现如下所示：（过程如下）

- 获取到 Volume Name

- 后求到这个 Volume Name 对应到宿主机上的绝对路径

- 然后把这个设备格式化为指定格式(d.mounter.Format)

- 最后把格式化后的设备挂载到了一个临时的 Staging 目录( stagingTargetPath）下。

```go
func (d *Driver) NodeStageVolume(ctx context.Context, req *csi.NodeStageVolumeRequest) (*csi.NodeStageVolumeResponse, error) {
    ...

    //  获取 volume name
    volumeName := ""
    if volName, ok := req.GetPublishContext()[d.publishInfoVolumeName]; !ok {
        return nil, status.Error(codes.InvalidArgument, "Could not find the volume by name")
    } else {
        volumeName = volName
    }

    ...

    // 获取 volumeName 对应的绝对路径
    source := getDeviceByIDPath(volumeName)
    target := req.StagingTargetPath

    ...

    // 格式化为 ext4 格式的磁盘
    fsType := "ext4"
    if mnt.FsType != "" {
        fsType = mnt.FsType
    }

    ...

    if noFormat {
        log.Info("skipping formatting the source device")
    } else {
        formatted, err := d.mounter.IsFormatted(source)
        if err != nil {
            return nil, err
        }
        //  如果没有格式化磁盘，那么调用 Format 函数格式化磁盘
        if !formatted {
            log.Info("formatting the volume for staging")
            if err := d.mounter.Format(source, fsType); err != nil {
                return nil, status.Error(codes.Internal, err.Error())
            }
        } else {
            log.Info("source device is already formatted")
        }
    }

    ...

    log.Info("mounting the volume for staging")

    // 判断是否已经 Mount 过
    mounted, err := d.mounter.IsMounted(target)
    if err != nil {
        return nil, err
    }

    // 如果没有 mount 过，那么就调用 Mounmt 函数进行挂载
    if !mounted {
        if err := d.mounter.Mount(source, target, fsType, options...); err != nil {
            return nil, status.Error(codes.Internal, err.Error())
        }
    } else {
        log.Info("source device is already mounted to the target path")
    }

    log.Info("formatting and mounting stage volume is finished")
    return &csi.NodeStageVolumeResponse{}, nil
}
```

**SetUp 操作会调用 CSI Node 服务的 NodePublishVolume 接口**。

经过以上对设备的预处理后，它的实现就非常简单了，如下所示:（过程如下）

- 将 Staging 目录绑定挂载到 Volume 对应的宿主机目录上

```go
func (d *Driver) NodePublishVolume(ctx context.Context, req *csi.NodePublishVolumeRequest) (*csi.NodePublishVolumeResponse, error) {
    ...
    // 根据不同的类型调用不同的 挂载函数
    switch req.GetVolumeCapability().GetAccessType().(type) {
    case *csi.VolumeCapability_Block:
        err = d.nodePublishVolumeForBlock(req, options, log)
    case *csi.VolumeCapability_Mount:
        err = d.nodePublishVolumeForFileSystem(req, options, log)
    default:
        return nil, status.Error(codes.InvalidArgument, "Unknown access type")
    }

    ...
}


//  具体的挂载函数，块存储挂载
func (d *Driver) nodePublishVolumeForBlock(req *csi.NodePublishVolumeRequest, mountOptions []string, log *logrus.Entry) error {
    volumeName, ok := req.GetPublishContext()[d.publishInfoVolumeName]
    if !ok {
        return status.Error(codes.InvalidArgument, fmt.Sprintf("Could not find the volume name from the publish context %q", d.publishInfoVolumeName))
    }

    // 获取 volumeName 对应的路径，也就是 NodeStageVolume 挂载的临时路径
    source, err := findAbsoluteDeviceByIDPath(volumeName)
    if err != nil {
        return status.Errorf(codes.Internal, "Failed to find device path for volume %s. %v", volumeName, err)
    }

    // 挂载到宿主机的指定的路径
    target := req.TargetPath

    // 判断是否已经挂载
    mounted, err := d.mounter.IsMounted(target)
    if err != nil {
        return err
    }

    log = log.WithFields(logrus.Fields{
        "source_path":   source,
        "volume_mode":   volumeModeBlock,
        "mount_options": mountOptions,
    })

    // 如果没有挂载，调用 Mount 函数进行挂载
    if !mounted {
        log.Info("mounting the volume")
        if err := d.mounter.Mount(source, target, "", mountOptions...); err != nil {
            return status.Errorf(codes.Internal, err.Error())
        }
    } else {
        log.Info("volume is already mounted")
    }

    return nil
}
```

## CSI 的部署

首先，需要创建一个 DigitalOceanclient 授权需要使用的Secret对象，如下所示：

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: digitalocean
  namespace: kube-system
  stringData: 
    access-token: "a05dd2f26b9b9ac2asdas_REPLACE_ME_123cb5dlec17513e06da"
```

然后，就可以一键部署 CSI 插件了例如：

```shell
kubectl apply -fhttps://raw.githubusercontent.com/digitalocean/csi-digitalocean/master/deploy/kubernetes/releases/csi-digitalocean-vX.Y.Z/{crds.yaml,driver.yaml,snapshot-controller.yaml}
```

在 csi-digitalocean 的源码中，deploy 目录下就是所有不同 release 版本的部署文件。下面就是部署服务的主要部分：(deploy/kubernetes/releases/csi-digitalocean-v4.0.0/driver.yaml)

```yaml
##############################################
###########                       ############
###########   Controller plugin   ############
###########                       ############
##############################################

kind: StatefulSet
apiVersion: apps/v1
metadata:
  name: csi-do-controller
  namespace: kube-system
spec:
  serviceName: "csi-do"
  selector:
    matchLabels:
      app: csi-do-controller
  replicas: 1
  template:
    metadata:
      annotations:
        kubectl.kubernetes.io/default-container: csi-do-plugin
      labels:
        app: csi-do-controller
        role: csi-do
    spec:
      priorityClassName: system-cluster-critical
      serviceAccount: csi-do-controller-sa
      containers:
        - name: csi-provisioner
          image: k8s.gcr.io/sig-storage/csi-provisioner:v3.0.0
          args:
            - "--csi-address=$(ADDRESS)"
            - "--default-fstype=ext4"
            - "--v=5"
          env:
            - name: ADDRESS
              value: /var/lib/csi/sockets/pluginproxy/csi.sock
          imagePullPolicy: "IfNotPresent"
          volumeMounts:
            - name: socket-dir
              mountPath: /var/lib/csi/sockets/pluginproxy/
        - name: csi-attacher
          image: k8s.gcr.io/sig-storage/csi-attacher:v3.3.0
          args:
            - "--csi-address=$(ADDRESS)"
            - "--v=5"
          env:
            - name: ADDRESS
              value: /var/lib/csi/sockets/pluginproxy/csi.sock
          imagePullPolicy: "IfNotPresent"
          volumeMounts:
            - name: socket-dir
              mountPath: /var/lib/csi/sockets/pluginproxy/
        - name: csi-snapshotter
          image: k8s.gcr.io/sig-storage/csi-snapshotter:v5.0.0
          args:
            - "--csi-address=$(ADDRESS)"
            - "--v=5"
          env:
            - name: ADDRESS
              value: /var/lib/csi/sockets/pluginproxy/csi.sock
          imagePullPolicy: IfNotPresent
          volumeMounts:
            - name: socket-dir
              mountPath: /var/lib/csi/sockets/pluginproxy/
        - name: csi-resizer
          image: k8s.gcr.io/sig-storage/csi-resizer:v1.3.0
          args:
            - "--csi-address=$(ADDRESS)"
            - "--timeout=30s"
            - "--v=5"
            # DO volumes support online resize.
            - "--handle-volume-inuse-error=false"
          env:
            - name: ADDRESS
              value: /var/lib/csi/sockets/pluginproxy/csi.sock
          imagePullPolicy: "IfNotPresent"
          volumeMounts:
            - name: socket-dir
              mountPath: /var/lib/csi/sockets/pluginproxy/
        - name: csi-do-plugin
          image: digitalocean/do-csi-plugin:v4.0.0
          args :
            - "--endpoint=$(CSI_ENDPOINT)"
            - "--token=$(DIGITALOCEAN_ACCESS_TOKEN)"
            - "--url=$(DIGITALOCEAN_API_URL)"
          env:
            - name: CSI_ENDPOINT
              value: unix:///var/lib/csi/sockets/pluginproxy/csi.sock
            - name: DIGITALOCEAN_API_URL
              value: https://api.digitalocean.com/
            - name: DIGITALOCEAN_ACCESS_TOKEN
              valueFrom:
                secretKeyRef:
                  name: digitalocean
                  key: access-token
          imagePullPolicy: "Always"
          volumeMounts:
            - name: socket-dir
              mountPath: /var/lib/csi/sockets/pluginproxy/
      volumes:
        - name: socket-dir
          emptyDir: {}

-------

########################################
###########                 ############
###########   Node plugin   ############
###########                 ############
########################################

kind: DaemonSet
apiVersion: apps/v1
metadata:
  name: csi-do-node
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: csi-do-node
  template:
    metadata:
      annotations:
        kubectl.kubernetes.io/default-container: csi-do-plugin
      labels:
        app: csi-do-node
        role: csi-do
    spec:
      priorityClassName: system-node-critical
      serviceAccount: csi-do-node-sa
      hostNetwork: true
      initContainers:
        # Delete automount udev rule running on all DO droplets. The rule mounts
        # devices briefly and may conflict with CSI-managed droplets (leading to
        # "resource busy" errors). We can safely delete it in DOKS.
        - name: automount-udev-deleter
          image: alpine:3
          args:
            - "rm"
            - "-f"
            - "/etc/udev/rules.d/99-digitalocean-automount.rules"
          volumeMounts:
            - name: udev-rules-dir
              mountPath: /etc/udev/rules.d/
      containers:
        - name: csi-node-driver-registrar
          image: k8s.gcr.io/sig-storage/csi-node-driver-registrar:v2.4.0
          args:
            - "--v=5"
            - "--csi-address=$(ADDRESS)"
            - "--kubelet-registration-path=$(DRIVER_REG_SOCK_PATH)"
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "rm -rf /registration/dobs.csi.digitalocean.com /registration/dobs.csi.digitalocean.com-reg.sock"]
          env:
            - name: ADDRESS
              value: /csi/csi.sock
            - name: DRIVER_REG_SOCK_PATH
              value: /var/lib/kubelet/plugins/dobs.csi.digitalocean.com/csi.sock
            - name: KUBE_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: plugin-dir
              mountPath: /csi/
            - name: registration-dir
              mountPath: /registration/
        - name: csi-do-plugin
          image: digitalocean/do-csi-plugin:v4.0.0
          args :
            - "--endpoint=$(CSI_ENDPOINT)"
            - "--url=$(DIGITALOCEAN_API_URL)"
          env:
            - name: CSI_ENDPOINT
              value: unix:///csi/csi.sock
            - name: DIGITALOCEAN_API_URL
              value: https://api.digitalocean.com/
          imagePullPolicy: "Always"
          securityContext:
            privileged: true
            capabilities:
              add: ["SYS_ADMIN"]
            allowPrivilegeEscalation: true
          volumeMounts:
            - name: plugin-dir
              mountPath: /csi
            - name: pods-mount-dir
              mountPath: /var/lib/kubelet
              # needed so that any mounts setup inside this container are
              # propagated back to the host machine.
              mountPropagation: "Bidirectional"
            - name: device-dir
              mountPath: /dev
      volumes:
        - name: registration-dir
          hostPath:
            path: /var/lib/kubelet/plugins_registry/
            type: DirectoryOrCreate
        - name: plugin-dir
          hostPath:
            path: /var/lib/kubelet/plugins/dobs.csi.digitalocean.com
            type: DirectoryOrCreate
        - name: pods-mount-dir
          hostPath:
            path: /var/lib/kubelet
            type: Directory
        - name: device-dir
          hostPath:
            path: /dev
        - name: udev-rules-dir
          hostPath:
            path: /etc/udev/rules.d/
```

注意：

1. 可以看到，我们编写的 CSI 插件只有一个二进制文件，它的镜像是 `digitalocean/do-csi-plugin:v4.0.0`。

2. 我们部署 CSI 插件的常用原则有以下两个。
   
   - 第一，**通过 DaemonSet 在每个节点上启动一个 CSI 插件，来为 kubelet 提供 CSI Node 服务**。
     
     - 这是因为 CSI Node 服务需要被 kubelet 直接调用，所以它要和 kubelet "一对一“ 地部署起来。
     
     - 此外，在上述 DaemonSet 的定义中，除了 CSI 插件，我们还以 sidecar 的方式运行着 driver-registrar 这个外部组件。它的作用是向 kubelet 注册这个 CSI 插件。这个注册过程使用的插件信息是通过访问同一个 Pod 里的 CSI 插件容器的 Identity 服务获取的。
     
     - 需要注意的是，由于 CSI 插件在一个容器里运行，因此<u> CSI Node 服务在 Mount 阶段执行的挂载操作实际上发生在这个容器的 Mount Namespace 里</u>。可是，我们真正希望执行挂载操作的对象都是宿主机 /var/Iib/kubelet 目录下的文件和目录。所以，在**定义 DaemonSet Pod 时，我们需要把宿主机的 /var/lib/kubelet 以 Volume 的方式挂载在 CSI 插件容摇的同名目录下，然后设置这个 Volume `mountPropagation=Bidirectional`，即开启双向挂载传播，从而将容器在这个目录下进行的挂载操作“传播＂给宿主机，反之亦然**。
   
   - 第二通过 StatefulSet 在任意一个节点上再启动一个 CSI 插件，为外部组件提供 CSI Controller 服务。
     
     - 作为 CSI Controller 服务的调用者，ExternalProvisioner 和 ExternalAttacher 这两个外部组件就需要以 sidecar 的方式和这次部署的 CSI 插件定义在同一个 Pod 里。
     
     - 为何用 StatefulSet 而不是 Deployment 来运行这个CSI插件呢？这是因为，**由于 StatefulSet 需要确保应用拓扑状态的稳定性，因此它严格按照顺序更新 Pod，即只有在前一个 Pod 停止并删除之后，它才会创建并启动下一个 Pod**。像上面这样将 StatefulSet 的 replicas 设置为 1 的话，StatefulSet 就会确保 Pod 被删除重建时，永远有且只有一个 CSI 插件的 Pod 在集群中运行。这对 CSI 插件的正确性来说至关重要。
