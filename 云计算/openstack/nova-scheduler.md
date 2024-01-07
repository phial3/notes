# Nova-Scheduler 源码分析

[toc]





## Nova Scheduler 概述



从Ocata开始，社区也在<u>致力于剥离 nova-scheduler 为独立的 Placement</u>，从而提供一个通用的调度服务来被多个项目使用。目前 Placement 已经成为一个独立的项目，但是不能完全取代 nova-scheduler，因此 nova-scheduler 仍然存在，可以与 Placement 协同工作。



在 openstack 中，scheduler 负责从宿主机（运行 nova-compute 的节点）中根据一系列的算法和参数（CPU 核数，可用 RAM，镜像类型等 ）选择出来一个，来部署虚拟机（instance）。Nova scheduler 的两个步骤：

- 过滤（filter）
- 权重计算（weighting）

![nova scheduler架构](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/OpenStack/nova-scheduler_architecture.png?raw=true)





首先要了解，整个 Nova 的流向：

1. nova-api 收到创建虚拟机的请求
2. 通过 rpc 调用 nova-conductor 修改数据库，并且 nova-conductor 通过 rpc 调用 nova-scheduler 选择一个最佳的主机调度
3. 选择好后，通过 rpc 调用 nova-compute 创建虚拟机



但实际情况要比这个过程复杂的多。



Nova Scheduler 的配置在：
```shell
[scheduler]
driver = filter_scheduler

[filter_scheduler]
available_filters = nova.scheduler.filters.all_filters
enabled_filters = RetryFilter, AvailabilityZoneFilter, ComputeFilter, ComputeCapabilitiesFilter, ImagePropertiesFilter, ServerGroupAntiAffinityFilter, ServerGroupAffinityFilter
```



在最新的 Zed 版本中，已经把 driver 的配置取消了，默认就是 filter_scheduler。在之前较早的版本中，可以有多个 driver，比如：

- FilterScheduler（过滤调度器）：默认载入的调度器，可以根据指定的过滤条件及权重挑选最佳节点。
- CachingScheduler：与FilterScheduler 功能相同，可以在其基础上将主机资源信息缓存在本地内存中，然后通过后台的定时任务定时从数据库中获取最新的主机资源信息。
- ChanceScheduler（随机调度器）：从所有nova-compute服务正常运行的节点中随机选择的调度器。
- FakeScheduler（伪调度器）：用于单元测试，没有任何实际功能的调度器。

这些配置可以在 setup.cfg 中看到，但是新版本已经把这些 driver 同意为 filter_scheduler

**后续源代码分析都是基于 Victoria 版本**，此版本还是有 filter driver的（在 `setup.py` 文件中）：

```python
[entry_points]
...
nova.scheduler.driver =
    filter_scheduler = nova.scheduler.filter_scheduler:FilterScheduler
```





## Nova Scheduler 项目结构

Nova-Scheduler 没有对外的 restful-api，只提供内部调用 rpc 接口。



在 nova 项目中，有一个 scheduler 的目录，就是存放 nova-scheduler 的项目代码：

```shell
[root@controller nova]# tree scheduler/
scheduler/
├── client
│   ├── __init__.py
│   ├── query.py
│   └── report.py
├── driver.py
├── filters
│   ├── affinity_filter.py
│   ├── aggregate_image_properties_isolation.py
│   ├── aggregate_instance_extra_specs.py
│   ├── aggregate_multitenancy_isolation.py
│   ├── all_hosts_filter.py
│   ├── availability_zone_filter.py
│   ├── compute_capabilities_filter.py
│   ├── compute_filter.py
│   ├── extra_specs_ops.py
│   ├── image_props_filter.py
│   ├── __init__.py
│   ├── io_ops_filter.py
│   ├── isolated_hosts_filter.py
│   ├── json_filter.py
│   ├── metrics_filter.py
│   ├── numa_topology_filter.py
│   ├── num_instances_filter.py
│   ├── pci_passthrough_filter.py
│   ├── type_filter.py
│   └── utils.py
├── filter_scheduler.py
├── host_manager.py
├── __init__.py
├── manager.py
├── request_filter.py
├── rpcapi.py
├── utils.py
└── weights
    ├── affinity.py
    ├── compute.py
    ├── cpu.py
    ├── cross_cell.py
    ├── disk.py
    ├── __init__.py
    ├── io_ops.py
    ├── metrics.py
    ├── pci.py
    └── ram.py

```



目录结构分析：

- **`client` 目录**：客户端调用程序的入口，也就是 rpc client
- **`filters` 目录**：提供了多种内置的过滤器
- **`weights` 目录**：上面介绍了通过第一步过滤后，第二部就是权重计算
- **`manager.py` 文件**：rpc server，也就是远程调用真正的处理入口，实际注册 rpc endpoint 的地方
- **`host_manager.py` 文件**：管理 zone 里面宿主机资源的，里面有两个类：
    - **类 HostState** 在内存中维护了一份最新的 Host 资源数据。封装了一台宿主机的资源情况，比如可用的内存，已用的内存，已用的硬盘，可用的硬盘，运行的 instance 个数，宿主机 ip，宿主机类型等等信息，还包含了一些方法来更新这些值。
    - **类 HostManager** 描述了调度器相关的操作函数，主要功能有，调用 filter 和 weight 的 handler 和配置里定义的对应的类来实现调度
- **`rpcapi.py` 文件**：是 rpc client 的实现，client 目录其实就是对 rpcapi 的进一步封装
- **`request_filter.py` 文件**：是对 rpc 调用请求中的请求体做转换，
- **`utils.py` 文件**：就是 nova scheduler 用到一些工具函数
- **`driver.py` 文件**：是所有调度器实现都要继承的基类，包含了调度器必须要实现的所有接口。





## Nova Scheduler 启动流程（RPC Server）



### 启动文件

在 nova 的 `setup.cfg` 启动配置中，定义了 nova-scheduler 的启动文件：

```python
console_scripts =
    ...
    nova-scheduler = nova.cmd.scheduler:main
	...
```



nova-scheduler 的启动文件位于：`nova.cmd.scheduler:main`

`nova/cmd/scheduler.py` 文件如下：

```python
def main():
    # 这一步相当于 init 函数，函数功能有，初始化 log、初始化 CONF、初始化 RPC、初始化 DB
    config.parse_args(sys.argv)
    # oslo_log 的初始化
    logging.setup(CONF, "nova")
    
    # 所有对象的加载，这里使用了 oslo_versionedobjects 来控制版本，和实现 远程调用
    # nova-scheduler 也是需要查询数据库的   
    objects.register_all()
    
    # 设置 oslo_reports 配置参数 的默认值
    gmr_opts.set_defaults(CONF)
    
    # 清除 Service 对象的本地缓存 _MIN_VERSION_CACHE
    objects.Service.enable_min_version_cache()

    # 设置 oslo_reports，用于在运行时捕获某些异常、统计信息，并生成报告
    gmr.TextGuruMeditation.setup_autorun(version, conf=CONF)

    # 创建 service.Service 对象，用于启动 rpc server
    # 这里的 topic 是 RPC_TOPIC = "scheduler"
    server = service.Service.create(binary='nova-scheduler',
                                    topic=scheduler_rpcapi.RPC_TOPIC)

    
    # 如果配置了 workers 数目就采用，否则，使用系统的CPU数量。
    workers = CONF.scheduler.workers
    if not workers:
        workers = (processutils.get_worker_count()
                   if CONF.scheduler.driver == 'filter_scheduler' else 1)
    
    # 启动 rpc server
    service.serve(server, workers=workers)
    service.wait()
```

上面介绍了每一个步骤，下面详细分析几个重要的步骤。



### 1. 初始化 `parse_args`



`parse_args` 函数位于 `nova/config.py`。主要作用就是：

1. 加载日志配置
2. 初始化日志级别，根据不同的要求设置不同的日志级别
3. 配置 cors 中间件
4. 初始化 rpc server
5. 初始化 db

```python
profiler = importutils.try_import('osprofiler.opts')

def parse_args(argv, default_config_files=None, configure_db=True,
               init_rpc=True):
    # 加载日志配置（oslo_config）
    log.register_options(CONF)

    # 配置日志级别
    if CONF.glance.debug:
        extra_default_log_levels = ['glanceclient=DEBUG']
    else:
        extra_default_log_levels = ['glanceclient=WARN']

	# eventlet 猴子补丁破坏了 uWSGI 上的 AMQP 心跳
    rabbit_logger = logging.getLogger('oslo.messaging._drivers.impl_rabbit')
    rabbit_logger.addFilter(rabbit_heartbeat_filter)

    # 在 privsep 中调试日志记录将导致记录一些大型且可能敏感的内容，因此设置为 INFO 级别
    extra_default_log_levels.append('oslo.privsep.daemon=INFO')

    # 设置 oslo_log 的日志级别
    log.set_defaults(default_log_levels=log.get_default_log_levels() +
                     extra_default_log_levels)
    
    # rpc 配置初始化，openstack rpc 是通过 rabbitmq 来实现的，oslo_messaging
    # 其实调用就是 oslo_messaging.set_transport_defaults 根据配置文件修改默认 transport 配置
    rpc.set_defaults(control_exchange='nova')
    
    # 如果 profiler 模块可以加载，那么就初始化 profiler 的配置
    if profiler:
        profiler.set_defaults(CONF)
    
    # oslo_middleware 中间件 cors 覆盖配置
    middleware.set_defaults()

    # 配置文件加载
    CONF(argv[1:],
         project='nova',
         version=version.version_string(),
         default_config_files=default_config_files)

    # 初始化 rpc server
    if init_rpc:
        rpc.init(CONF)

    # 初始化 db （oslo_db）
    if configure_db:
        sqlalchemy_api.configure(CONF)
```



比较重要的两个初始化步骤就是 ：rpc 和 db

首先是 rpc 初始化(`nova/rpc.py`)：

```python
# 从配置文件中 解析 rabbitmq 的 transport url
def get_transport_url(url_str=None):
    return messaging.TransportURL.parse(CONF, url_str)

# 根据 rabbitmq 配置的 transport url 创建 oslo_messaging 的 Transport 对象
def create_transport(url):
    exmods = get_allowed_exmods()
    return messaging.get_rpc_transport(CONF,
                                       url=url,
                                       allowed_remote_exmods=exmods)

def init(conf):
    # 全局变量，主要功能就是要初始化这几个全局变量
    global TRANSPORT, NOTIFICATION_TRANSPORT, LEGACY_NOTIFIER, NOTIFIER
    
    # 所有允许的封装过的异常
    exmods = get_allowed_exmods()
    
    # 创建 rabbitmq 的 Transport （oslo_messaging）
    TRANSPORT = create_transport(get_transport_url())
    
    # 创建 notification 的 Transport 对象，这里分为 unversioned 与 versioned 
    # versioned 是后来规范后的
    # 创建好 Transport 后，创建 Notifier 对象，用来发送 notification 消息到 rabbitmq
    # 根据 versioned 、unversioned 、both 创建不同 driver 的 notifier 对象
    NOTIFICATION_TRANSPORT = messaging.get_notification_transport(
        conf, allowed_remote_exmods=exmods)
    serializer = RequestContextSerializer(JsonPayloadSerializer())
    if conf.notifications.notification_format == 'unversioned':
        LEGACY_NOTIFIER = messaging.Notifier(NOTIFICATION_TRANSPORT,
                                             serializer=serializer)
        NOTIFIER = messaging.Notifier(NOTIFICATION_TRANSPORT,
                                      serializer=serializer, driver='noop')
    elif conf.notifications.notification_format == 'both':
        LEGACY_NOTIFIER = messaging.Notifier(NOTIFICATION_TRANSPORT,
                                             serializer=serializer)
        NOTIFIER = messaging.Notifier(
            NOTIFICATION_TRANSPORT,
            serializer=serializer,
            topics=conf.notifications.versioned_notifications_topics)
    else:
        LEGACY_NOTIFIER = messaging.Notifier(NOTIFICATION_TRANSPORT,
                                             serializer=serializer,
                                             driver='noop')
        NOTIFIER = messaging.Notifier(
            NOTIFICATION_TRANSPORT,
            serializer=serializer,
            topics=conf.notifications.versioned_notifications_topics)
```



其次是 db 的初始化(`nova/db/sqlalchemy/api.py`):

```python
# 上下文
main_context_manager = enginefacade.transaction_context()
api_context_manager = enginefacade.transaction_context()


def configure(conf):
    # 配置数据库连接
    main_context_manager.configure(**_get_db_conf(conf.database))
    api_context_manager.configure(**_get_db_conf(conf.api_database))

    # 如果配置了 profiler ，则开启
    if profiler_sqlalchemy and CONF.profiler.enabled \
            and CONF.profiler.trace_sqlalchemy:

        main_context_manager.append_on_engine_create(
            lambda eng: profiler_sqlalchemy.add_tracing(sa, eng, "db"))
        api_context_manager.append_on_engine_create(
            lambda eng: profiler_sqlalchemy.add_tracing(sa, eng, "db"))
```





### 2. 加载操作资源对象 `register_all`

`register_all` 函数功能：确保在此函数中导入对象，以便可以远程 RPC 调用其他服务。函数位于:`nova/objects/__init__.py`

```python
def register_all():
    __import__('nova.objects.agent')
    __import__('nova.objects.aggregate')
    __import__('nova.objects.bandwidth_usage')
    ...
```



`objects/*` 目录下定义了所有的远程/本地操作数据库的操作，如果需要远程调用，需要在启动时，添加 indirection_api 属性



nova-scheduler 也会直接操作数据库，因此某些本地操作的方法可以执行。



上面的机制使用了 `oslo_versionedobjects` 基础库。`oslo_versionedobjects` 使用分为几步：

- 创建 objects 目录，并且在目录下创建 `objects/base.py`
- 在 `base.py` 中创建基础类（命名空间为当前 project），抽象化所有可以被 RPC 远程访问或实例化的对象。远程化基于 `oslo_versionedobjects` 中提供的基类。
    - 基础类需要继承自 `oslo_versionedobjects.base.VersionedObject`
    - 基础类必须添加 `OBJ_PROJECT_NAMESPACE` 属性和 `OBJ_SERIAL_NAMESPACE` 属性 
- 创建其他资源类。实现对象并将它们放在 `objects/*.py` 中
    - 为了确保所有对象在任何时候都可以访问，您应该将它们导入 `objects/` 目录中的`__init__.py` 中
    - 在 `obj_make_compatible` 方法中处理所有的版本问题
    - 传递标有版本的对象而不是字典
- 创建的自定义资源类，可以使用新的字段类型，通过继承 `oslo_versionedobjects.field.Field` 并覆盖 `from_primitive`和 `to_primitive` 方法来实现。并且新创建的类型，放在 `objects/fields.py` 文件
- 创建对象注册表并注册所有对象，注册表对象需要继承自 `oslo_versionedobjects.base.VersionedObjectRegistry`  。该注册表就是注册所有自定义对象的地方。
    - 这里需要注意，所有自定义资源对象，应由 `oslo_versionedobjects.base.ObjectRegistry.register` 类装饰器注册。

- 创建并添加对象序列化器（serializer）。要对 RPC 传输对象，序列化的程序。需要与 oslo_messaging 配合使用：
- 实现 `indirection API` （重要）。`oslo.versionedobjects` 支持远程/本地方法调用。这些是对象方法和类方法的调用。
    - 可以根据配置在本地或远程执行。在类方法或者对象方法添加装饰器，带有 `remote` 的装饰器即为 rpc 调用
    - 将 `indirection_api` 设置为 rpc 远程调用对象，通过定义的 RPC API 中对被装饰方法的调用。 例如 `@base.remotable` 装饰器，其实就是调用 `self.indirection_api.object_action`



### 3. 创建 Service 对象

下面比较重要的步骤是：

```python
    server = service.Service.create(binary='nova-scheduler',
                                    topic=scheduler_rpcapi.RPC_TOPIC)
```



`service.Service.create` 其实是类方法，返回了 Service 对象（`nova/service.py`）

```python
# 主机上运行的二进制文件的服务对象。
# 服务采用 manager 管理器,并通过监听基于topic的队列来启用 rpc。
# 它还定期在管理器上运行任务，并将其状态报告给数据库 services 表。
class Service(service.Service):


    def __init__(self, host, binary, topic, manager, report_interval=None,
                 periodic_enable=None, periodic_fuzzy_delay=None,
                 periodic_interval_max=None, *args, **kwargs):
        super(Service, self).__init__()
        self.host = host
        self.binary = binary
        self.topic = topic
        # 这里的 manager 默认为 nova.scheduler.manager.SchedulerManager
        self.manager_class_name = manager
        
        # 添加了 servicegroup API 对象
        # 当有新的 compute 节点启动时，会调用 servicegroup API 来加入服务组，最终落库到 Service 表中
        self.servicegroup_api = servicegroup.API()
        # 导入 manager
        manager_class = importutils.import_class(self.manager_class_name)
        if objects_base.NovaObject.indirection_api:
            conductor_api = conductor.API()
            conductor_api.wait_until_ready(context.get_admin_context())
        # 实例化 manager
        self.manager = manager_class(host=self.host, *args, **kwargs)
        self.rpcserver = None
        self.report_interval = report_interval
        self.periodic_enable = periodic_enable
        self.periodic_fuzzy_delay = periodic_fuzzy_delay
        self.periodic_interval_max = periodic_interval_max
        self.saved_args, self.saved_kwargs = args, kwargs
        self.backdoor_port = None
        setup_profiler(binary, self.host)
       
    @classmethod
    def create(cls, host=None, binary=None, topic=None, manager=None,
               report_interval=None, periodic_enable=None,
               periodic_fuzzy_delay=None, periodic_interval_max=None):

        # host 默认 是 nova.conf 中 host 配置
        if not host:
            host = CONF.host
        # host 是 nova-scheduler
        if not binary:
            binary = os.path.basename(sys.argv[0])
        # 如果没有配置 topic，那么九八 binary 的 nova- 去掉，也就是 scheduer
        if not topic:
            topic = binary.rpartition('nova-')[2]
        # 默认 manager 为 nova.scheduler.manager.SchedulerManager
        if not manager:
            manager = SERVICE_MANAGERS.get(binary)
        # report_interval 为 nova.conf report_interval 配置 
        if report_interval is None:
            report_interval = CONF.report_interval
            
        # 是否开启周期任务，默认开启
        if periodic_enable is None:
            periodic_enable = CONF.periodic_enable
        if periodic_fuzzy_delay is None:
            periodic_fuzzy_delay = CONF.periodic_fuzzy_delay

        debugger.init()

        # 创建 Service 对象
        service_obj = cls(host, binary, topic, manager,
                          report_interval=report_interval,
                          periodic_enable=periodic_enable,
                          periodic_fuzzy_delay=periodic_fuzzy_delay,
                          periodic_interval_max=periodic_interval_max)

        try:
            utils.raise_if_old_compute()
        except exception.TooOldComputeService as e:
            LOG.warning(str(e))

        return service_obj
    
```



### 4. 启动服务

最后一步：

```python
    # 启动 rpc server
    service.serve(server, workers=workers)
    service.wait()
```



调用 `service.serve` 来启动服务，接下来看是如何启动的，`nova/service.py`:

```python
def serve(server, workers=None):
    global _launcher
    if _launcher:
        raise RuntimeError(_('serve() can only be called once'))
	
    # 调用 oslo_service.launch 方法启动，最终调用的就是 Service.start() 的方法
    _launcher = service.launch(CONF, server, workers=workers,
                               restart_method='mutate')
    

class Service(service.Service):
    ....

    # 启动 rpc 服务，并且初始化周期任务
    def start(self):
        context.CELL_CACHE = {}

        verstr = version.version_string_with_package()
        LOG.info('Starting %(topic)s node (version %(version)s)',
                  {'topic': self.topic, 'version': verstr})
        
        self.basic_config_check()
        self.manager.init_host()
        self.model_disconnected = False
        ctxt = context.get_admin_context()
        self.service_ref = objects.Service.get_by_host_and_binary(
            ctxt, self.host, self.binary)
        if self.service_ref:
            _update_service_ref(self.service_ref)

        else:
            try:
                self.service_ref = _create_service_ref(self, ctxt)
            except (exception.ServiceTopicExists,
                    exception.ServiceBinaryExists):
                # NOTE(danms): If we race to create a record with a sibling
                # worker, don't fail here.
                self.service_ref = objects.Service.get_by_host_and_binary(
                    ctxt, self.host, self.binary)
		# 在 service 启动前做的操作，此处没有任何操作
        self.manager.pre_start_hook()

        if self.backdoor_port is not None:
            self.manager.backdoor_port = self.backdoor_port

        LOG.debug("Creating RPC server for service %s", self.topic)

        target = messaging.Target(topic=self.topic, server=self.host)

        # rpc endpoint 注册，就是 nova.scheduler.manager.
        # 所有可以被远程 rpc 调用的方法就是 nova.scheduler.manager.SchedulerManager 的对象方法
        endpoints = [
            self.manager,
            baserpc.BaseRPCAPI(self.manager.service_name, self.backdoor_port)
        ]
        endpoints.extend(self.manager.additional_endpoints)
		
        # 实例化 序列对象
        serializer = objects_base.NovaObjectSerializer()
		# 获取 rpc server，也就是 rabbitmq 的 server
        # 在 init 函数中，已经创建了 rabbitmq 的 Transport 对象，此处使用 Transport 对象调用 oslo_messaging.get_rpc_server 获取 rpc server
        self.rpcserver = rpc.get_server(target, endpoints, serializer)
        # 启动 rpc server，其实就是监听 rabbitmq 具体 topic 的消息
        self.rpcserver.start()
		# 在 service 启动后做的操作，此处没有任何操作
        self.manager.post_start_hook()

        LOG.debug("Join ServiceGroup membership for this service %s",
                  self.topic)
        # 调用 servicegroup join 函数，将 self.service_ref 入库，存入 Service 表
        self.servicegroup_api.join(self.host, self.topic, self)

        # 是否启动周期型任务，conductor 和 scheduler 没有周期性任务
        # nova-compute 具有很多周期任务，通过装饰器 @periodic_task.periodic_task 标注
        if self.periodic_enable:
            if self.periodic_fuzzy_delay:
                initial_delay = random.randint(0, self.periodic_fuzzy_delay)
            else:
                initial_delay = None

            self.tg.add_dynamic_timer(self.periodic_tasks,
                                     initial_delay=initial_delay,
                                     periodic_interval_max=
                                        self.periodic_interval_max)

    
```





## Nova-Scheduler Manager 

上面介绍了 rpc server 的注册启动过程，所有 nova-scheduler rpc 方法都写在 SchedulerManager(nova/scheduler/manager.py)

```python
class SchedulerManager(manager.Manager):
    """Chooses a host to run instances on."""

    target = messaging.Target(version='4.5')

    _sentinel = object()

    def __init__(self, *args, **kwargs):
        self.placement_client = report.SchedulerReportClient()
        # 加载 driver，默认 FilterScheduler（nova/scheduler/filter_scheduler.py）
        self.driver = driver.DriverManager(
            'nova.scheduler.driver',
            CONF.scheduler.driver,
            invoke_on_load=True
        ).driver

        super(SchedulerManager, self).__init__(
            service_name='scheduler', *args, **kwargs
        )

    def reset(self):
        self.driver.host_manager.refresh_cells_caches()

    @messaging.expected_exceptions(exception.NoValidHost)
    def select_destinations(self, ctxt, request_spec=None,
		....
        selections = self.driver.select_destinations(ctxt, spec_obj,
                instance_uuids, alloc_reqs_by_rp_uuid, provider_summaries,
                allocation_request_version, return_alternates)
        ....

    def update_aggregates(self, ctxt, aggregates):
        self.driver.host_manager.update_aggregates(aggregates)

    def delete_aggregate(self, ctxt, aggregate):
        self.driver.host_manager.delete_aggregate(aggregate)

    def update_instance_info(self, context, host_name, instance_info):
        self.driver.host_manager.update_instance_info(context, host_name,
                                                      instance_info)

    def delete_instance_info(self, context, host_name, instance_uuid):
        self.driver.host_manager.delete_instance_info(context, host_name,
                                                      instance_uuid)

    def sync_instance_info(self, context, host_name, instance_uuids):
        self.driver.host_manager.sync_instance_info(context, host_name,
                                                    instance_uuids)
```



nova-scheduler 定义了上述这些 rpc 方法，其中最重要的就是 select_destinations ，也就是调度程序。可以发现，最终的具体实现都是在 `self.driver` 中，那么 `self.driver` 又是什么呢？

`self.driver` 就是 CONF.scheduler.driver 配置的内容，默认是 FilterScheduler。FilterScheduler 定义在 `nova/scheduler/filter_scheduler.py` 文件中，作用就是通过 HostManager 和 HostState 的封装，实现了调度程序

- **类 HostState** 在内存中维护了一份最新的 Host 资源数据。
- **类 HostManager** 描述了调度器相关的操作函数。



下面介绍 FilterScheduler、HostState、HostManager 的关系

- FilterScheduler 是最顶层的封装，其基类 Scheduler 对 HostManager 进行了二次封装，是调度程序的业务逻辑组装
- HostManager 是跟 Host 的调度操作相关，并且内部调用了 HostState 来维护内存的 Compute host 数据。







## Nova Scheduler Filtering

### 1. Filter 如何被调用的

在 `FilterScheduler`(`nova/scheduler/filter_scheduler.py`) 中调用 filter 的地方如下：

```python
class FilterScheduler(driver.Scheduler):
    ...
    def _get_sorted_hosts(self, spec_obj, host_states, index):
        """Returns a list of HostState objects that match the required
        scheduling constraints for the request spec object and have been sorted
        according to the weighers.
        """
        filtered_hosts = self.host_manager.get_filtered_hosts(host_states,
            spec_obj, index)
    ....
```



在 `HostManager`(`nova/scheduler/host_manager.py`) 具体调用如下

```python
class HostManager(object):
    def __init__(self):
        self.filter_handler = filters.HostFilterHandler()
        ....
    ...
    def get_filtered_hosts(self, hosts, spec_obj, index=0):
        ....
        return self.filter_handler.get_filtered_objects(self.enabled_filters,
            	hosts, spec_obj, index)
        
    ...
```

通过调用 `HostFilterHandler.get_filtered_objects` 方法来调用所有 enable 的 调度器。

`HostFilterHander` 没有此方法，但是继承了 `BaseFilterHandler` (`nova/filters.py`) 实现了此方法，如下：

```python
class BaseFilterHandler(loadables.BaseLoader):
    
    def get_filtered_objects(self, filters, objs, spec_obj, index=0):
        ...
        # 遍历所有的 过滤器 filter
        for filter_ in filters:
            if filter_.run_filter_for_index(index):
                cls_name = filter_.__class__.__name__
                start_count = len(list_objs)
                # 调用过滤器的 filter_all 方法。
                objs = filter_.filter_all(list_objs, spec_obj)
                if objs is None:
                    LOG.debug("Filter %s says to stop filtering", cls_name)
                    return
                list_objs = list(objs)
                .......
        return list_objs
```



通过遍历所有的 filter 过滤器，调用 filter 的 `filter_all` 函数。





### 2. Filtering

Filtering就是使用配置文件指定的Filter来过滤掉不符合条件的主机。

这个阶段首先要做的一件事情是，根据各台主机当前可用的资源情况，如内存的容量等，过滤掉那些不能满足虚拟机要求的主机。

Nova 支持的 Filter 共有30个，能够处理各类信息。
· **主机可用资源**：内存、磁盘、CPU、PCI设备、NUMA拓扑等。
· **主机类型**：虚拟机类型及版本、CPU类型及指令集等。
· 主机状态：主机是否处于活动状态、CPU使用率、虚拟机启动数量、繁忙程度、是否可信等。
· **主机分组情况**：Available Zone、Host Aggregates信息。
· **启动请求的参数**：请求的虚拟机类型（flavor）、镜像信息（image）、请求重试次数、启动提示信息（hint）等。
· **虚拟机亲合性（affinity）及反亲合性（anti-affinity）**：与其他虚拟机是否在同一主机上。
· **元数据处理**：主机元数据、镜像元数据、虚拟机类型元数据、主机聚合（Host Aggregates）元数据。



所有的Filter实现都位于 `nova/scheduler/filters` 目录下，每个 Filter 都继承自 `nova.scheduler.filters.BaseHostFilter`（位于 `nova/scheduler/filters/__init__.py`）：

```python
class BaseHostFilter(filters.BaseFilter):
    """Base class for host filters."""
    RUN_ON_REBUILD = False

    # 如果被过滤的对象通过，返回 True，否则返回 False
    def _filter_one(self, obj, spec):
        from nova.scheduler import utils
        # 如果是 rebuild 请求，例如 重建虚拟机，过滤器直接返回 True，因为已经调度过了
        if not self.RUN_ON_REBUILD and utils.request_is_rebuild(spec):
            return True
        else:
            # 否则，执行 host_passes 函数进行真正的过滤操作
            return self.host_passes(obj, spec)

    # 自定义的 过滤器，只需要重写 此方法即可
    def host_passes(self, host_state, filter_properties):
        """Return True if the HostState passes the filter, otherwise False.
        Override this in a subclass.
        """
        raise NotImplementedError()

```



可以很方便地通过继承类 `BaseHostFilter` 来创建一个新的 Filter，并且新建的 Filter 只需实现一个函数 `host_passes()`，返回结果只有两种：若满足条件，则返回True，否则返回 False

`host_passes()` 函数有两个参数，分别是：

- host_state：内存中最新的被前置过滤器过滤后的 host 
- filter_properties：过滤的条件，request_spec 对象

可能有疑问，上面调用的是 filter 的 `filter_all` 函数。这里的 `BaseHostFilter` 并没有该函数，其实其父类中有此方法(`nova/filters.py`)：

```python
class BaseFilter(object):
	....
	# filter_obj_list 是所有的 host_state 
    def filter_all(self, filter_obj_list, spec_obj):
        # 其实就是遍历，执行 _filter_one 函数，而上面 _filter_one 又调用了 host_passes ，因此自定义 filter 只需要实现 host_passes 即可
        # 遍历所有的 host 进行过滤
        for obj in filter_obj_list:
            if self._filter_one(obj, spec_obj):
                yield obj
```





具体使用哪些Filter需要在配置文件中指定：

```shell
[scheduler]
driver = filter_scheduler

[filter_scheduler]
available_filters = nova.scheduler.filters.all_filters
available_filters = myfilter.MyFilter
enabled_filters = RetryFilter, AvailabilityZoneFilter, ComputeFilter, ComputeCapabilitiesFilter, ImagePropertiesFilter, ServerGroupAntiAffinityFilter, ServerGroupAffinityFilter
```



其中，`available_filters` 用于指定所有可用的 Filter，`enable_filters` 则表示针对可用的 Filter

nova-scheduler默认会使用:

```python
    cfg.ListOpt("enabled_filters",
        default=[
          "AvailabilityZoneFilter",
          "ComputeFilter",
          "ComputeCapabilitiesFilter",
          "ImagePropertiesFilter",
          "ServerGroupAntiAffinityFilter",
          "ServerGroupAffinityFilter",
          ],
        deprecated_name="scheduler_default_filters",
        deprecated_group="DEFAULT",
        help="""
        ....
        """
   )
```





### 3. 各个 Filter 功能介绍



#### 亲和性类 Filter

##### DifferentHostFilter

将 vm 调度到与一组 vm 不同的主机上。源码如下(`nova/scheduler/filters/affinity_filter.py`)：

```python
class DifferentHostFilter(filters.BaseHostFilter):
    # The hosts the instances are running on doesn't change within a request
    run_filter_once_per_request = True
	
    # 重建的请求不执行此 filter
    RUN_ON_REBUILD = False

    
    def host_passes(self, host_state, spec_obj):
        # 获取 different_host 请求参数
        affinity_uuids = spec_obj.get_scheduler_hint('different_host')
        # 如果有提供 一组 vm uuid
        if affinity_uuids:
            # 主要的过滤逻辑，逻辑很简单：找到 host_state 这台主机上的所有 uuid ，与 different_host 求交集
            # 如果有结果，说明此节点上有 不亲和的 vm，返回 false 过滤掉
            overlap = utils.instance_uuids_overlap(host_state, affinity_uuids)
            return not overlap
        # 如果没有提供，直接不进行任何过滤
        return True

```



要利用此过滤器，必须提供一组 vm 实例 uuid，使用 different_host 作为键并使用实例 UUID 列表作为值。此过滤器与 SameHostFilter 相反。使用 openstack server create 命令，使用 --hint 标志。或者使用 json 格式发送请求。

```shell
# 命令行模型
$ openstack server create --image cedef40a-ed67-4d10-800e-17455edce175 \
  --flavor 1 --hint different_host=a0cf03a5-d921-4877-bb5c-86d26cf818e1 \
  --hint different_host=8c19174f-4220-44f0-824a-cd1eeef10287 server-1

# request body
{
    "server": {
        "name": "server-1",
        "imageRef": "cedef40a-ed67-4d10-800e-17455edce175",
        "flavorRef": "1"
    },
    "os:scheduler_hints": {
        "different_host": [
            "a0cf03a5-d921-4877-bb5c-86d26cf818e1",
            "8c19174f-4220-44f0-824a-cd1eeef10287"
        ]
    }
}
```



##### SameHostFilter

与 DifferentHostFilter 相反，将 vm 调度到与一组 vm 实例相同的主机上。

同样利用此过滤器，必须传递 `same_host` 作为键并使用实例 UUID 列表作为的参数。



源码实现也与 DifferentHostFilter 相同，只不过 `return overlap`，即有交集就返回 True



##### SimpleCIDRAffinityFilter

在具有特定 cidr 的主机上调度 vm 实例。

源码如下(`nova/scheduler/filters/affinity_filter.py`)：

```python
class SimpleCIDRAffinityFilter(filters.BaseHostFilter):
    run_filter_once_per_request = True

    RUN_ON_REBUILD = False

    def host_passes(self, host_state, spec_obj):
        # 获取两个请求 参数
        affinity_cidr = spec_obj.get_scheduler_hint('cidr', '/24')
        affinity_host_addr = spec_obj.get_scheduler_hint('build_near_host_ip')
        # 获取当前主机 host 的 ip
        host_ip = host_state.host_ip
        if affinity_host_addr:
            affinity_net = netaddr.IPNetwork(str.join('', (affinity_host_addr,
                                                           affinity_cidr)))
			# 如果当前待判断主机的 ip 在 cidr 范围内，返回 True
            return netaddr.IPAddress(host_ip) in affinity_net

        # We don't have an affinity host address.
        return True
```





根据主机 IP 子网范围调度实例。要使用此过滤器，必须传递两个参数来指定 CIDR 格式的有效 IP 地址范围：

- build_near_host_ip：子网中的第一个 IP 地址（例如 192.168.1.1）
- cidr：子网对应的 CIDR（例如 /24）

可以通过命令行或者 request 请求：

```shell
$ openstack server create --image cedef40a-ed67-4d10-800e-17455edce175 \
  --flavor 1 --hint build_near_host_ip=192.168.1.1 --hint cidr=/24 server-1
  
  {
    "server": {
        "name": "server-1",
        "imageRef": "cedef40a-ed67-4d10-800e-17455edce175",
        "flavorRef": "1"
    },
    "os:scheduler_hints": {
        "build_near_host_ip": "192.168.1.1",
        "cidr": "24"
    }
}
```



##### ServerGroupAffinityFilter

ServerGroupAffinityFilter 将一个 vm 实例调度到一组主机组中的主机上。

源码如下(`nova/scheduler/filters/affinity_filter.py`)：

```python
class _GroupAffinityFilter(filters.BaseHostFilter):
    RUN_ON_REBUILD = False

    def host_passes(self, host_state, spec_obj):
        policies = (spec_obj.instance_group.policies
                    if spec_obj.instance_group else [])
        if self.policy_name not in policies:
            return True
		
        # 主机组列表
        group_hosts = (spec_obj.instance_group.hosts
                       if spec_obj.instance_group else [])
        LOG.debug("Group affinity: check if %(host)s in "
                  "%(configured)s", {'host': host_state.host,
                                     'configured': group_hosts})
        if group_hosts:
            # 如果当前被判断的主机 host_state 在其中，返回 True
            return host_state.host in group_hosts

        # 主机组为空，返回 True
        return True


class ServerGroupAffinityFilter(_GroupAffinityFilter):
    def __init__(self):
        self.policy_name = 'affinity'
        super(ServerGroupAffinityFilter, self).__init__()
```





要利用此过滤器，必须提供一个具有关联策略的主机组。使用 openstack server create 命令，使用 --hint 标志。使用 openstack server create 命令，使用 --hint 标志。

```shell
$ openstack server group create --policy anti-affinity group-1
$ openstack server create --image IMAGE_ID --flavor 1 \
  --hint group=SERVER_GROUP_UUID server-1
```



##### ServerGroupAntiAffinityFilter

与上面相反。



#### 主机聚合类 Filter

##### AggregateImagePropertiesIsolation

将 vm 调度到 Image Properties 与 主机聚合（如果该主机属于一个 Host Aggregate）Metadata 匹配的主机上。

通俗来说：

- 如果主机属于一个 Host Aggregate ，并且该主机聚合定义了一个或多个 Metadata，并且与 Image Properties 匹配，则该主机是调度 vm 实例的候选者。 

- 如果主机不属于任何聚合，则它可以从所有 Image 启动实例。 

源码如下(`nova/scheduler/filters/aggregate_image_properties_isolation.py`)：

```python
class AggregateImagePropertiesIsolation(filters.BaseHostFilter):

    run_filter_once_per_request = True

    RUN_ON_REBUILD = True

    def host_passes(self, host_state, spec_obj):

        # host aggregate 分割的命名空间，默认 DEFAULT
        cfg_namespace = (CONF.filter_scheduler.
            aggregate_image_properties_isolation_namespace)
        # host aggregate 分割字符，默认 .
        cfg_separator = (CONF.filter_scheduler.
            aggregate_image_properties_isolation_separator)
		
        # 获取请求 request_spec 中 image properties
        image_props = spec_obj.image.properties if spec_obj.image else {}
        # 获取 被判断主机所属 主机聚合的 metadata dict
        metadata = utils.aggregate_metadata_get_by_host(host_state)

        # 遍历所有的 host aggregate metadata，与 image properties 匹配，必须所有属性都匹配，有一个不匹配即返回 False
        for key, options in metadata.items():
            # 判断是否是 DEFAULT.前缀
            if (cfg_namespace and
                    not key.startswith(cfg_namespace + cfg_separator)):
                continue
            prop = None
            try:
                # 获取 image 对应 key 的 property
                prop = image_props.get(key)
            except AttributeError:
                LOG.warning("Host '%(host)s' has a metadata key '%(key)s' "
                            "that is not present in the image metadata.",
                            {"host": host_state.host, "key": key})
                continue
			# 如果不匹配，返回 False
            if prop and str(prop) not in options:
                LOG.debug("%(host_state)s fails image aggregate properties "
                            "requirements. Property %(prop)s does not "
                            "match %(options)s.",
                          {'host_state': host_state,
                           'prop': prop,
                           'options': options})
                return False
        return True
```



##### AggregateMultiTenancyIsolation

当前主机所在的 Host Aggregate 的 Metadata 是否有 filter_tenant_id 属性，如果有，那么只允许特定租户（project）创建



#### 其他 filter

-  `AllHostsFilter`：不进行任何过滤
- `ComputeFilter`：挑选出所有处于激活状态（active）的主机。
- `NUMATopologyFilter`：挑选出符合虚拟机NUMA拓扑请求的主机。
- `PciPassthroughFilter`：挑选出提供PCI SR-IOV支持的主机。
- `AvailabilityZoneFilter`: 挑选出符合 Availability Zone 的主机
- `ImagePropertiesFilter`: 挑选出满足 Image Properties 的主机
- `IoOpsFilter`：挑选出并发 I/O 操作较少的主机，参数 **max_io_ops_per_host** 设置了 最大的并发 I/O 限制，如果超出了此限制的虚拟机正在build、resize、snapshot、migrate、rescue、unshelve 操作则忽略此主机
- `IsolatedHostsFilter`: 允许 admin 定义一组特殊（隔离）的镜像和一组特殊（隔离）的主机，这样隔离镜像只能在隔离主机上运行









## Nova Scheduler Weighting

**Weighting 是指对所有符合条件的主机计算权重（Weight）并排序，从而得出最佳的主机**。

经过各种过滤器过滤之后，会得到一个最终的主机列表。该列表保存了所有通过指定过滤器的主机，由于列表中可能存在多台主机，因此调度器需要在它们当中选择最优的一个。

类似于Filtering，这个过程需要调用指定的各种 Weigher 模块，得出每台主机的总权重值。

如下图说是

![nova-scheduler weighting](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/OpenStack/nova-scheduler-weighting.PNG?raw=true)

### 1. Weigher 如何被调用的

在 FilterScheduler(`nova/scheduler/filter_scheduler.py`) 中，对 Weigher 调用如下：

```python
class FilterScheduler(driver.Scheduler):
    ....
    def _get_sorted_hosts(self, spec_obj, host_states, index):
        ....
        weighed_hosts = self.host_manager.get_weighed_hosts(filtered_hosts, spec_obj)
        
```

在 `HostManager`(`nova/scheduler/host_manager.py`) 具体调用如下

```python
class HostManager(object):
    def __init__(self):
    	....
    	self.weight_handler = weights.HostWeightHandler()
        weigher_classes = self.weight_handler.get_matching_classes(
                CONF.filter_scheduler.weight_classes)
        self.weighers = [cls() for cls in weigher_classes]
    	....
    ...
    def get_weighed_hosts(self, hosts, spec_obj):
        """Weigh the hosts."""
        return self.weight_handler.get_weighed_objects(self.weighers,
                hosts, spec_obj)
```

调用了 `HostWeightHandler.get_weighed_objects` 方法来调用所有 配置的的 调度器。

`HostWeightHandler` 没有此方法，但是继承了 `BaseWeightHandler` (`nova/weights.py`) 实现了此方法，如下：

```python
class WeighedObject(object):
    """Object with weight information."""
    def __init__(self, obj, weight):
        self.obj = obj
        self.weight = weight

    def __repr__(self):
        return "<WeighedObject '%s': %s>" % (self.obj, self.weight)

class BaseWeightHandler(loadables.BaseLoader):
    object_class = WeighedObject

    # 返回所有计算权重，并排序后的host结果
    def get_weighed_objects(self, weighers, obj_list, weighing_properties):
        # 返回 WeighedObject 对象（每一个主机对应一个 WeighedObject 对象），就是 权重和 Weigher 代理，最终返回的对象
        weighed_objs = [self.object_class(obj, 0.0) for obj in obj_list]

        # 如果只有一个主机， 直接返回
        if len(weighed_objs) <= 1:
            return weighed_objs

        # 遍历所有的 Weigher
        for weigher in weighers:
            
            # 关键：调用 Weigther 的 weigh_objects 方法进行加权计算
            weights = weigher.weigh_objects(weighed_objs, weighing_properties)

            # Normalize the weights，将权重归一化成 0-1 之间
            weights = normalize(weights,
                                minval=weigher.minval,
                                maxval=weigher.maxval)

            # 遍历每一个计算结果，结果*加权系数
            for i, weight in enumerate(weights):
                obj = weighed_objs[i]
                # 这里注意，weight_multiplier 方法返回的就是加权系数
                # 将所有 Weigher 的计算结果加起来，就是最终的加权结果
                obj.weight += weigher.weight_multiplier(obj.obj) * weight

        # 根据 weight 排序后返回
        return sorted(weighed_objs, key=lambda x: x.weight, reverse=True)
```



这里注意两个函数：

- `Weigher.weigh_objects`: 对所有主机进行计算，返回 weights 计算结果数组
    - `weigh_objects` 方法，最终遍历所有主机，调用的是 `_weigh_object` 方法对每一个主机进行计算
    - 因此自定义的 Weigher 需要实现 `_weigh_object` 方法
- `Weigher.weight_multiplier`: 返回的是当前 Weigher 的加权系数
    - 自定义的 Weigher 需要实现 `weight_multiplier` 方法

### 2. 自定义 Weigher

上面提到了。自定义 Weigher 需要实现的两个方法：

- `_weigh_object` 方法：计算 Weight
- `weight_multiplier` 方法：返回加权系数，也就是最终 Weight * 系数



例如，`RAMWeigher` 内存权重计算，源码如下（`nova/scheduler/weights/ram.py`）：

```python
class RAMWeigher(weights.BaseHostWeigher):
    minval = 0
	
    # 返回加权系数
    def weight_multiplier(self, host_state):
        
        # 最终返回的系数，由 get_weight_multiplier 提供
        # 实际返回：如果 host aggregate 的元数据中有配置当前 Weigher 的加权系数，那么优先返回 Host aggregate的配置
        # 否则，返回配置文件中的配置内容
        return utils.get_weight_multiplier(
            host_state, 'ram_weight_multiplier',
            CONF.filter_scheduler.ram_weight_multiplier)

    
    # 返回当前被判断 host_state 的 Weight
    def _weigh_object(self, host_state, weight_properties):
        # 权重越高，获胜
        return host_state.free_ram_mb
```



下面主要看一下如何计算加权系数，也就是 `get_weight_multiplier` 函数(`nova/scheduler/utils.py`)：

- 给定一个 HostState 对象（ multplier_type 名称和 multiplier_config ）返回权重乘数。
- 从 host_state 的 "聚合元数据" 中读取 multiplier_name 以覆盖 multiplier_config
- 如果聚合元数据不包含 multiplier_name，则将直接返回 multiplier_config
- 一句话，如果 Host Aggregate 元数据中配置了 multiplier_name 的值，例如：`cpu_weight_multiplier=xxx`，那么就替换 multiplier_config ，否则直接返回 multiplier_config 

```python

def get_weight_multiplier(host_state, multiplier_name, multiplier_config):
    """
    :param host_state: 具有 Host Aggregate 元数据的 Host_State
    :param multiplier_name: 加权系数名称  例如 "cpu_weight_multiplier".
    :param multiplier_config: 加权系数配置 value
    """
    
    # 从 aggregate 元数据中获取 key 为 multiplier_name 内容
    aggregate_vals = filters_utils.aggregate_values_from_key(host_state,
                                                             multiplier_name)
    try:
        value = filters_utils.validate_num_values(
            aggregate_vals, multiplier_config, cast_to=float)
    except ValueError as e:
        LOG.warning("Could not decode '%(name)s' weight multiplier: %(exce)s",
                    {'exce': e, 'name': multiplier_name})
        # 如果 元数据中不存在，直接返回 multiplier_config
        value = multiplier_config

    return value
```









