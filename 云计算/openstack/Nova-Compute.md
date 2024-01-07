# Nova-Compute

[toc]

**nova-compute：**负责虚拟机的生命周期管理，创建并终止虚拟机实例的工作后台程序 hypervisor api

## 启动流程



### 1. 入口



在 setup.cfg 中指定了 nova-compute 的入口：

```python
console_scripts =
	...
    nova-compute = nova.cmd.compute:main
```



下面就是 nova-compute 的入口 main 函数()：

```python
def main():
    # 同  nova-scheduler
    config.parse_args(sys.argv)
    logging.setup(CONF, 'nova')
    # 初始化 oslo_privsep context
    priv_context.init(root_helper=shlex.split(utils.get_root_helper()))
    # 同 nova-scheduler，所有对象的加载
    objects.register_all()
    gmr_opts.set_defaults(CONF)
    
    # os_vif 初始化，虚拟接口操作
    os_vif.initialize()

    gmr.TextGuruMeditation.setup_autorun(version, conf=CONF)

    # 组织 nova-compute 访问 database
    cmd_common.block_db_access('nova-compute')
    # nova-compute 需要通过 rpc 调用 nova-conductor
    objects_base.NovaObject.indirection_api = conductor_rpcapi.ConductorAPI()
    objects.Service.enable_min_version_cache()
    
    # 其他同 nova-scheduler
    server = service.Service.create(binary='nova-compute',
                                    topic=compute_rpcapi.RPC_TOPIC)
    service.serve(server)
    service.wait()
```

下面介绍与 nova-scheduler 不同的几个步骤。



### 2. oslo_privsep 初始化

```python
priv_context.init(root_helper=shlex.split(utils.get_root_helper()))
```



oslo_privsep 是 Openstack 的一个标准库，**允许在预定义特权上下文中运行特定函数**。

上面启动时用到 shlex 包，其实就是将一串命令转成 python list。

- `shlex.split(s[, comments[, posix]])`使用类似shell的语法分割字符串。例如：

```
shlex.split("python -u a.py -a A -b B -o test")
['python', '-u', 'a.py', '-a', 'A', '-b', 'B', '-o', 'test']
```



#### sudo 与 su 的区别

**sudo 命令：**

`sudo` **命令允许非 root 用户暂时地获得更高权限**，来执行一些特权命令，例如添加和删除用户、删除属于其他用户的文件、安装新软件等。

- `sudo` 命令允许非 root 用户访问一两个 **需要更高权限** 的常用命令，这样可以帮助系统管理员节省来自用户的许多请求，并减少等待时间。
- `sudo` 命令**不会将用户帐户切换为 root 用户**，因为大多数非 root 用户永远不应该拥有完全的 root 访问权限。
- 在大多数情况下，`sudo` 允许用户执行一两个命令，然后提权就会过期。在这个通常为 5 分钟的短暂的提权时间内，用户可以执行任何需要提权的管理命令。
- 需要继续使用提权的用户可以运行 `sudo -v` 命令来重新验证 root 访问权限，并将提权时间再延长 5 分钟。
- sudo 不需要直到 root 密码，只需要直到当前用户的密码。
- sudo 执行命令的流程是当前用户切换到 root（或其它指定切换到的用户），然后以 root（或其它指定的切换到的用户）身份执行命令，执行完成后，直接退回到当前用户，而这些的前提是要通过 sudo 的配置文件 `/etc/sudoers` 来进行授权，该文件默认属性0411
- sudo 最常用的命令：`sudo -l`，列出当前用户的权限



**su 命令：**

`su` **命令能够将非 root 用户提权到 root 权限**

- 事实上，能让非 root 用户成为 root 用户。唯一的要求是用户知道 root 密码。因为用户已经以 root 权限登录，所以之后的操作就没有限制了。
- `su` 命令所提供的提权没有时间限制。用户可以作为 root 执行命令，不需要进行重新验证是否有 root 权限。完成任务后，用户可以执行退出命令 `exit`，从 root 用户恢复到自己原来的非 root 帐户。



**sudo在OpenStack中使用: **

OpenStack 中的组件在运行底层命令时，不可避免的要运行一些管理员权限的命令，在早期，就是通过 sudo 来实现。但这种方式存在一些问题：

- 随着需要运行的命令越来越多，造成 sudoers 配置文件越来越臃肿，维护越来越困难
- 毕竟对于 sudoers 文件的管理和操作，属于操作系统打包机制，不应该与 OpenStack 联系过于紧密
- 作为权限管理的控制，sudo 本身的机制并不能严格控制到命令的参数，做不到更为精细化的控制

于是，社区开发了 rootwrap 机制来解决上述的问题。



#### rootwrap

rootwrap 的使用很简单，如果之前你需要运行 `sudo ls -l`，那么现在你需要执行 `sudo nova-rootwrap /etc/nova/rootwrap.conf ls -l`

也就是在 sudo 后面多加了一句 `nova-rootwrap /etc/nova/rootwrap.conf`



该命令运行时的流程是这样的：

- nova 用户（这里以 Nova 为例）以 root 权限执行 `nova-rootwrap /etc/nova/rootwrap.conf ls -l`
- 找到 `/etc/nova/rootwrap.conf` 文件中定义的 filters_path 配置目录，加载该目录中的 filter 文件
- 根据 filter 文件的定义，判断是否能够执行 ls -l





需要的配置：

```python
[DEFAULT]
rootwrap_config=/etc/nova/rootwrap.conf
```

`rootwrap_config`: 配置 rootwrap 配置文件的目录, 该配置文件中，主要的配置就是 filters_path , filters_path 配置的目录，必须是 root 用户写入。也就是 rootwrap.conf 文件，以及 filters_path 目录（及包含的文件）的属主是 root



例如下面的 `rootwrap_config` 配置文件：

```shell
[DEFAULT]
# List of directories to load filter definitions from (separated by ',').
# These directories MUST all be only writeable by root !
filters_path=/etc/nova/rootwrap.d,/usr/share/nova/rootwrap

# List of directories to search executables in, in case filters do not
# explicitly specify a full path (separated by ',')
# If not specified, defaults to system PATH environment variable.
# These directories MUST all be only writeable by root !
exec_dirs=/sbin,/usr/sbin,/bin,/usr/bin,/usr/local/sbin,/usr/local/bin

# Enable logging to syslog
# Default value is False
use_syslog=False

# Which syslog facility to use.
# Valid values include auth, authpriv, syslog, local0, local1...
# Default value is 'syslog'
syslog_log_facility=syslog

# Which messages to log.
# INFO means log all usage
# ERROR means only log unsuccessful attempts
syslog_log_level=ERROR
```





filters_path 配置的文件内容格式，应该与 suoers 文件内容格式一致，如下：

```shell
nova ALL = (root) NOPASSWD: /usr/bin/nova-rootwrap /etc/nova/rootwrap.conf *
```

- 允许 nova 用户（这里以Nova为例）执行 `nova-rootwrap` 命令



#### rootwrap 与 oslo_privsep 

**rootwrap: **

rootwrap 的实现入口在：

```python
console_scripts =
    nova-rootwrap = oslo_rootwrap.cmd:main
    nova-rootwrap-daemon = oslo_rootwrap.cmd:daemon
```

也就是说，rootwrap 是 openstack 在标准库 oslo_rootwrap 中实现的，编译后会生成 nova-rootwrap 与 nova-rootwrap-daemon 命令。

然后，就可以通过 `sudo nova-rootwrap /etc/nova/rootwrap.conf xxx` 来执行命令。



**oslo_privsep:**  

oslo_privsep 是一个用于权限分离的 OpenStack 库。

oslo_privsep 其实是对 rootwrap 的进一步封装，本质还是通过 `sudo nova-rootwrap /etc/nova/rootwrap.conf xxxx` 来调用系统命令。



#### nova oslo_privsep 的初始化

回到 nova oslo_privsep 的初始化：

```python
priv_context.init(root_helper=shlex.split(utils.get_root_helper()))
```

`oslo_privsep.priv_context.init` 函数，其实就是配置了 oslo_privsep 执行任何命令的前缀入口点。例如：`root_helper='sudo'`，那么在执行每条命令前都会加上 `sudo`



`utils.get_root_helper` 函数源码如下(`nova/utils.py`)：

- 如果配置文件中 disable_rootwrap 为 true，直接通过 sudo 执行命令
- 否则，通过 `sudo nova-rootwrap /xx/xx/rootwrap.conf` 执行命令 

```python
def get_root_helper():
    if CONF.workarounds.disable_rootwrap:
        cmd = 'sudo'
    else:
        cmd = 'sudo nova-rootwrap %s' % CONF.rootwrap_config
    return cmd
```



### 3. os_vif 初始化

os-vif 是一个用于在 OpenStack 中插入和拔出虚拟接口 (VIF) 的库。提供了：

- 表示各种类型的虚拟接口及其组件的版本化对象
- 提供 `plug()` 和 `unplug()` 接口的基本 VIF 插件类
- 两个网络后端的插件 —— **Open vSwitch** 和 **Linux Bridge**。除了包含的两个插件外，其他网络后端的所有插件都在单独的代码存储库中维护。



#### 4. 阻止 nova-compute 对 db 的访问

```python
cmd_common.block_db_access('nova-compute')
```



`block_db_access` 源码如下(`nova/cmd/common.py`):

```python
# 组织 对 db 的访问
def block_db_access(service_name):

    class NoDB(object):
        # 调用任何属性，都返回 类对象本身，那么调用属性方法，其实就是执行 对象本身，进入 __call__ 方法
        def __getattr__(self, attr):
            return self

        def __call__(self, *args, **kwargs):
            stacktrace = "".join(traceback.format_stack())
            LOG.error('No db access allowed in %(service_name)s: '
                      '%(stacktrace)s',
                      dict(service_name=service_name, stacktrace=stacktrace))
            raise exception.DBNotAllowed(binary=service_name)

    # 将 nova.db.api 设置成 NoNB 无权访问
    nova.db.api.IMPL = NoDB()
```

直接把 nova.db.api.IMPL 修改成 NoDB 类，原本为：

```python
# nova/db/api.py
_BACKEND_MAPPING = {'sqlalchemy': 'nova.db.sqlalchemy.api'}

IMPL = concurrency.TpoolDbapiWrapper(CONF, backend_mapping=_BACKEND_MAPPING)
```



#### 5. indirection_api 初始化

```python
objects_base.NovaObject.indirection_api = conductor_rpcapi.ConductorAPI()
```



因为 nova-compute 需要通过 rpc 远程调用 nova-conductor，因此这里注册了 indirection_api 属性，在通过 oslo_versionedobjects 注册的资源对象，有远程调用 `@base.remotable` 装饰的函数，都可以直接通过 nova-conductor 调用。





## Nova-Compute Resource Tracker

**Resource Tracker**

nova-compute需要在数据库中更新主机的资源使用情况，包括内存、CPU、磁盘等，以便nova-scheduler获取选择主机的依据，这就要求**在每次创建、迁移、删除一台虚拟机时，都需要更新数据库中的相关的内容**。



Nova使用 `ComputeNode` 对象保存计算节点的配置信息及资源使用状况。nova-compute 服务在启动时会为当前主机创建一个 ResourceTracker 对象，其主要任务就是监视本机资源变化，并更新 ComputeNode 对象在数据库中对应的 compute_nodes 表。

```python
class ComputeManager(manager.Manager):
    """Manages the running instances from creation to destruction."""

    target = messaging.Target(version='5.12')

    def __init__(self, compute_driver=None, *args, **kwargs):
        ....
        self.rt = resource_tracker.ResourceTracker(
            self.host, self.driver, reportclient=self.reportclient)
        ....
```



nova-compute 服务通过两种途径来更新当前主机对应的 ComputeNode 数据库记录：

- 一种是使用 Resource Tracker 的 **Claim 机制**
- 另一种是使用周期性任务（**Periodic Task**）



### 1. Claim 机制

【场景】：

当一台主机收到多个并发创建 vm 的请求时，这台主机并不一定有足够的资源来满足这些虚拟机的创建要求。

【动作】：

**Claim 机制**就是<u>在创建虚拟机之前预先测试一下主机的可用资源能否满足新建虚拟机的需要</u>

- 如果能够满足，则更新数据库，并将虚拟机申请的资源从主机可用的资源中减掉，如果在后来创建时失败，则会通过 Claim 机制还原之前减掉的部分
- 如果不满足，则告知 nova-conductor，继续进行下一次调度



在查看代码时发现，使用到 claim 机制，一共有几处：

- **instance_claim**：包括创建(create)、解归档(unshelve) vm
- **rebuild_claim**：vm 的重建(rebuild)
- **resize_claim**：调整 vm 的 flavor
- **live_migration_claim**：热迁移
- **abort_instance_claim**：从给定实例中删除使用情况
- **drop_move_claim**：删除迁移状态为 incoming/outgoing 的使用情况



下面以 instance_claim (`nova/compute/resource_tracker.py`)为例：

```python
    # 计算实例生成操作需要一些资源
    @utils.synchronized(COMPUTE_RESOURCE_SEMAPHORE, fair=True)
    def instance_claim(self, context, instance, nodename, allocations,
                       limits=None):
		......

        # 初始化 Cliam 对象
        claim = claims.Claim(context, instance, nodename, self, cn,
                             pci_requests, limits=limits)

		# 通过 nova-conductor 更新 Instance 的 host、node 与 launched_on 属性
        instance_numa_topology = claim.claimed_numa_topology
        instance.numa_topology = instance_numa_topology
        self._set_instance_host_and_node(instance, nodename)

		......
        

        # 根据新建 vm 的需求，计算主机的可用资源，并更新到 self.compute_nodes[nodename] 中
        self._update_usage_from_instance(context, instance, nodename)

        elevated = context.elevated()
        
        # 根据 self.compute_nodes[nodename] 计算的结果，通过 nova-conductor 更新到数据库 compute_nodes 中。并上报给 placement
        self._update(elevated, cn)

        return claim
```

注意：

- 如果 `claim.Cliam()` 返回 None，即主机的可用资源满足不了新建的虚拟机的需求，则 Resource Tracker 不会减去 Instance 占用的资源并抛出 `ComputeResourceUnavailable `异常
- 如果 `claim.Cliam()` 成功后，虚拟机在创建过程中失败（检测到任何异常），则会调用 `__exit__()` 方法将占用的资源返还到主机的可用资源中



### 2. Periodic Task

在 `nova.compute.manager.ComputeManager` 类中有一个周期性任务，该周期性任务最终会调用位于 Resource Tracker 中的 `update_available_resource()`函数（用于更新主机的资源数据），计算所有可用的资源和消耗的资源，更新数据库，同时上报给 Placement：



在 nova-scheduler 中提到了，在启动 rpc server 时，同时会注册很多定时任务，并启动，这些定时任务都是定义在 ComputeManager(`nova/compute/manager.py`) 中的 带有 `@periodic_task.periodic_task` 装饰器的 Periodic Task.



例如，更新资源的周期任务定义如下(`nova/compute/manager.py`)：

```python
class ComputeManager(manager.Manager):
    ...
    # 周期任务，固定间隔执行
    @periodic_task.periodic_task(spacing=CONF.update_resources_interval)
    def update_available_resource(self, context, startup=False):
        try:
            # 通过 virt.driver（例如 libvirt driver）获取可用节点信息
            nodenames = set(self.driver.get_available_nodes())
        except exception.VirtDriverNotReady:
            LOG.warning("Virt driver is not ready.")
            return

        # 通过 nova-conductor 获取对应节点的数据库信息
        compute_nodes_in_db = self._get_compute_nodes_in_db(context,
                                                            nodenames,
                                                            use_slave=True,
                                                            startup=startup)

        # 删除驱动程序未报告但仍在数据库中的孤立计算节点
        for cn in compute_nodes_in_db:
            if cn.hypervisor_hostname not in nodenames:
                LOG.info("Deleting orphan compute node %(id)s "
                         "hypervisor host is %(hh)s, "
                         "nodes are %(nodes)s",
                         {'id': cn.id, 'hh': cn.hypervisor_hostname,
                          'nodes': nodenames})
                cn.destroy()
                self.rt.remove_node(cn.hypervisor_hostname)
                # Delete the corresponding resource provider in placement,
                # along with any associated allocations.
                try:
                    self.reportclient.delete_resource_provider(context, cn,
                                                               cascade=True)
                except keystone_exception.ClientException as e:
                    LOG.error(
                        "Failed to delete compute node resource provider "
                        "for compute node %s: %s", cn.uuid, six.text_type(e))
		# 调用 Resource Tracker 上报信息
        for nodename in nodenames:
            self._update_available_resource_for_node(context, nodename,
                                                     startup=startup)
```



下面时 Resource Tracker 中 update_available_resource 周期任务的执行逻辑(`nova/compute/resource_tracker.py`)：

```python
class ResourceTracker(object):
    ....
    	# 从 hypervisor 获取节点资源用量，并更新
        def update_available_resource(self, context, nodename, startup=False):

            LOG.debug("Auditing locally available compute resources for "
                      "%(host)s (node: %(node)s)",
                     {'node': nodename,
                      'host': self.host})
            # 通过 virt driver（libvirt driver）获取对应节点的 资源
            resources = self.driver.get_available_resource(nodename)

            resources['host_ip'] = CONF.my_ip

            # We want the 'cpu_info' to be None from the POV of the
            # virt driver, but the DB requires it to be non-null so
            # just force it to empty string
            if "cpu_info" not in resources or resources["cpu_info"] is None:
                resources["cpu_info"] = ''

            self._verify_resources(resources)

            self._report_hypervisor_resource_view(resources)
            # 更新数据库，上报 placement
            self._update_available_resource(context, resources, startup=startup)
```



### 二者关系

两种更新途径并不冲突：

- Claim 机制会在每次主机资源消耗发生变化时更新，能够保证数据库里的可用资源被及时更新，以便为nova-
    scheduler提供最新的数据；
- 周期性任务则是为了保证数据库内信息的准确性，它每次都会通过Hypervisor重新获取主机的资源信息，并将这些信息更新到数据库中



## Nova-Compute Virt Driver



### virt driver



Nova-Compute 的最重要的功能就是管理 vm 的生命周期，那么是如何管理的呢？

答案就是通过 Virt Driver 调用下层的 hypervisors 管理器，来操作具体的虚拟设备。



Nova 目前支持：

- **KVM** - 基于内核的虚拟机。
    - 支持的虚拟磁盘格式是从 QEMU 继承的，因为它使用修改后的 QEMU 程序来启动虚拟机。
    - 支持的格式包括原始图像、qcow2 和 VMware 格式。 
- **LXC** - Linux 容器（通过 libvirt），用于运行基于 Linux 的虚拟机。 
- **QEMU** - Quick EMUlator，通常仅用于开发目的。 
- **VMware vSphere 5.1.0 及更新版本** - 通过与 vCenter 服务器的连接运行基于 VMware 的 Linux 和 Windows 映像。 
- **Hyper-V** - 使用 Microsoft Hyper-V 的服务器虚拟化，用于运行 Windows、Linux 和 FreeBSD 虚拟机。在 Windows 虚拟化平台上本地运行 nova-compute。 
- **Virtuozzo 7.0.0 及更新版本** - 支持操作系统容器和基于内核的虚拟机。支持的格式包括 ploop 和 qcow2 图像。 
- **zVM** - z Systems 和 IBM LinuxONE 上的服务器虚拟化，它可以运行 Linux、z/OS 等。 Ironic - 提供裸机（相对于虚拟机）机器的 OpenStack 项目。



Nova 通过 virt 驱动程序支持管理程序。 Nova 在 virt 目录(`nova/virt/`)有以下内容：

- [`compute_driver`](https://docs.openstack.org/nova/latest/configuration/config.html#DEFAULT.compute_driver) = `libvirt.LibvirtDriver`
    - LibvirtDriver 驱动程序在 Linux 上运行并支持多个管理程序后端，可以通过 libvirt.virt_type 配置选项进行配置。默认是 kvm，可选项有：kvm, lxc, qemu, parallels
- [`compute_driver`](https://docs.openstack.org/nova/latest/configuration/config.html#DEFAULT.compute_driver) = `ironic.IronicDriver`
- [`compute_driver`](https://docs.openstack.org/nova/latest/configuration/config.html#DEFAULT.compute_driver) = `vmwareapi.VMwareVCDriver`
- [`compute_driver`](https://docs.openstack.org/nova/latest/configuration/config.html#DEFAULT.compute_driver) = `hyperv.HyperVDriver`
- [`compute_driver`](https://docs.openstack.org/nova/latest/configuration/config.html#DEFAULT.compute_driver) = `zvm.ZVMDriver`
- [`compute_driver`](https://docs.openstack.org/nova/latest/configuration/config.html#DEFAULT.compute_driver) = `fake.FakeDriver`



### libvirt driver 示例



下面就以 libvirt driver 来查看 nova 是如何与 libvirt 交互来对 vm 进行生命周期的管理。

这里以 `ComputeManager`(`nova/compute/manager.py`) 的一个定时任务为引：

```python
# nova/compute/manager.py
class ComputeManager(manager.Manager):
    def __init__(self, compute_driver=None, *args, **kwargs):
        ......
        self.virtapi = ComputeVirtAPI(self)
		......
        # 加载 virt driver
        self.driver = driver.load_compute_driver(self.virtapi, compute_driver)
    # 定时更新节点的使用情况
    @periodic_task.periodic_task(spacing=CONF.update_resources_interval)
    def update_available_resource(self, context, startup=False):\
        try:
        	# 调用 virt driver 接口，获取当前可用的节点
            nodenames = set(self.driver.get_available_nodes())
        except exception.VirtDriverNotReady:
            LOG.warning("Virt driver is not ready.")
            return
	......
    
    
# nova/virt/driver.py
def load_compute_driver(virtapi, compute_driver=None):
    # 如果不传 compute_driver 参数，使用配置文件中的配置
    if not compute_driver:
        compute_driver = CONF.compute_driver

    # 如果 配置文件中也没有相关配置，报错
    if not compute_driver:
        LOG.error("Compute driver option required, but not specified")
        sys.exit(1)

    LOG.info("Loading compute driver '%s'", compute_driver)
    try:
        # 导入路径，nova.virt.xxx
        driver = importutils.import_object(
            'nova.virt.%s' % compute_driver,
            virtapi)
        if isinstance(driver, ComputeDriver):
            return driver
        raise ValueError()
    except ImportError:
        LOG.exception("Unable to load the virtualization driver")
        sys.exit(1)
    except ValueError:
        LOG.exception("Compute driver '%s' from 'nova.virt' is not of type "
                      "'%s'", compute_driver, str(ComputeDriver))
        sys.exit(1)
```



- `update_available_resource` 任务内部，调用了 `self.driver.get_available_nodes` 方法获取当前可用的节点
- 这里的 `self.driver` 又是 `load_compute_driver` 方法导入的
- 导入路径为：`nova.virt.xxx`，例如 libvirt 应配置为 `compute_driver = libvirt.LibvirtDriver` ,最终路径为 `nova.virt.libvirt.LibvirtDriver`
- 最后其实调用的就是 `nova.virt.libvirt.LibvirtDriver.get_available_nodes` 方法



libvirt 在内核中其实是 C 库，但也支持了 python 的 api 调用，官方 libvirt python 库为：
```shell
pip install libvirt-python
```



而 Nova 的 LibvirtDriver(`nova/virt/libvirt/driver.py`) 其实又是对 libvirt-python 标准库的进一步封装。

```python
class LibvirtDriver(driver.ComputeDriver):
    def __init__(self, virtapi, read_only=False):
        ....
        # Host 类 管理有关主机操作系统和管理程序的信息。此类封装与 libvirt 守护进程的连接等操作
        self._host = host.Host(self._uri(), read_only,
                           lifecycle_event_handler=self.emit_event,
                           conn_event_handler=self._handle_conn_event)
	....
    # libvirtDriver 对 get_hostname 的进一步封装
    def get_available_nodes(self, refresh=False):
        return [self._host.get_hostname()]
```





### kvm、qemu、libvirtd和nova组件之间的区别和联系，

**一：QEMU**

QEMU是一个模拟器，通过动态二进制转换来模拟cpu以及其他一系列硬件，使guest os认为自己就是在和真正的硬件打交道，其实是和qemu模拟的硬件交互。这种模式下，guest os可以和主机上的硬件进行交互，但是所有的指令都需要qemu来进行翻译，性能会比较差。

 

**二：KVM**

KVM是Linux内核提供的虚拟化架构，它需要硬件硬件CPU支持，比如采用硬件辅助虚拟化的Intel-VT，AMD-V。

KVM通过一个内核模块kvm.ko来实现核心虚拟化功能，以及一个和处理器相关的模块，如kvm-intel.ko或者kvm-amd.ko。kvm本身不实现模拟，仅暴露一个接口/dev/kvm,用户态程序可以通过访问这个接口的ioctl函数来实现vcpu的创建，和虚拟内存的地址空间分配。

有了kvm之后，guest-os的CPU指令不用再经过qemu翻译就可以运行，大大提升了运行速度。

但是kvm只能模拟cpu和内存，不能模拟其他设备，于是就有了下面这个两者合一的技术qemu-kvm。

 

**三：QEMU-KVM**

qemu-kvm，是qemu一个特定于kvm加速模块的分支。

qemu将kvm整合进来，通过ioctl调用/dev/kvm，将cpu相关的指令交给内核模块来做，kvm只实现了cpu和内存虚拟化，但不能模拟其它设备，因此qemu还需要模拟其它设备(如：硬盘、网卡等)，qemu加上kvm就是完整意义上的服务器虚拟化

综上所述，QEMU-KVM具有两大作用：

1. 提供对cpu，内存（KVM负责），IO设备（QEMU负责）的虚拟
2. 对各种虚拟设备的创建，调用进行管理（QEMU负责）



**四：libvirtd**

Libvirtd是目前使用最广泛的对kvm虚拟机进行管理的工具和api。Libvirtd是一个Domain进程可以被本地virsh调用，也可以被远端的virsh调用，libvirtd调用kvm-qemu控制虚拟机。

libvirtd由几个不同的部分组成，其中包括应用程序编程接口（API）库，一个守护进程（libvirtd）和一个默认的命令行工具(virsh)，libvirtd守护进程负责对虚拟机的管理，因此要确保这个进程的运行。



**五：openstack(nova)、kvm、qemu-kvm和libvirtd之间的关系。**

kvm是最底层的VMM，它可以模拟cpu和内存，但是缺少对网络、I/O及周边设备的支持，因此不能直接使用。

qemu-kvm是构建与kvm之上的，它提供了完整的虚拟化方案

openstack(nova)的核心功能就是管理一大堆虚拟机，虚拟机可以是各种各样（kvm, qemu, xen, vmware...），而且管理的方法也可以是各种各样（libvirt, xenapi, vmwareapi...）。而nova中默认使用的管理虚拟机的API就是libvirtd。

简单说就是，openstack不会去直接控制qemu-kvm，而是通过libvirtd库去间接控制qemu-kvm。

另外，libvirt还提供了跨VM平台的功能，它可以控制除了QEMU之外的模拟器，包括vmware, virtualbox， xen等等。所以为了openstack的跨VM性，所以openstack只会用libvirt而不直接用qemu-kvm
