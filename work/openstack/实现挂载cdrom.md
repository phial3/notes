# OpenStack 实现添加 CdROM 设备

[toc]





## 方案一

1. 在 horizon 界面，通过 ISO image 创建出一个 Volume
2. 在 horizon 界面可以给一个 vm attach 通过 iso 创建出的 volume
3. 但是通过第二部创建出来的还是一个 disk 类型，不是 cdrom，需要修改 nova 的 reserve_block_device_name 方法中创建 bdm 时，根据不同类型创建出一个 `device_type = cdrom` 设备





## 方案二



1. 为 vm 添加 cdrom 设备
    - vm 创建时，根据 flavor，是否直接创建出带有 CDROM 设备的 vm
    - vm 已经创建，手动添加 cdrom 设备，需要硬重启
2. 为 vm 添加 CDROM 设备，相当于只是有了光驱设备，但是没有插光盘：
    - https://blog.csdn.net/zhongbeida_xue/article/details/80498175
    - nova 在 `nova.virt.libvirt.driver._get_guest_storage_config` 先创建 `source_type = cdrom` 的 cdrom 设备
    - 这里的 cdrom 设备，是以 bdm 的 `destination_tyep = volume` 形式添加的，但 source 为空，也就是没有光盘
3. 添加镜像时，相当于插入光盘
    - 将 镜像 替换到 source 中
    - 将 volume 中 image 擦除，再写入新的 image，需要volume的挂载/卸载
    - 







在 Libvirt 中，您可以使用 `virsh` 命令行工具将虚拟机的 CD-ROM 设备的 `source` 属性更改为 Ceph 后端存储的 RBD 镜像。请按照以下步骤进行操作：

1. **上传 ISO 镜像到 Ceph 集群**：首先，将您希望用作 CD-ROM 镜像的 ISO 文件上传到 Ceph 集群中。您可以使用 `rbd import` 命令或 Ceph Dashboard 来完成上传。假设您上传了一个名为 `cdrom-image.iso` 的 ISO 镜像，并创建了一个名为 `cdrom-image` 的 RBD 镜像。
2. **为虚拟机更新 CD-ROM 设备的 `source` 属性**：通过 `virsh` 命令行工具来更新 CD-ROM 设备的 `source` 属性。

```
bashCopy codevirsh change-media vm_name hdc --eject
virsh attach-disk vm_name rbd:pool_name/cdrom-image --type cdrom --mode readonly --config
```

其中，`vm_name` 是虚拟机的名称，`hdc` 是 CD-ROM 设备的目标设备名称。`pool_name` 是 Ceph 集群中的存储池名称，`cdrom-image` 是 RBD 镜像的名称。

请确保使用 `rbd:` 作为 RBD 镜像的前缀，以告诉 Libvirt 使用 RBD 协议来访问镜像。

1. **在虚拟机内部挂载 CD-ROM 设备**：在虚拟机内部执行以下命令以挂载 CD-ROM 设备：

```
bashCopy codesudo mkdir /mnt/cdrom
sudo mount /dev/cdrom /mnt/cdrom
```

完成以上步骤后，虚拟机的 CD-ROM 设备将使用 Ceph 后端存储的 RBD 镜像作为其源。请确保虚拟机内部的操作系统正确识别和使用新的 CD-ROM 镜像。