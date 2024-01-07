# Nova-Scheduler 调度过程



[toc]



## 调度流程

整个调度子系统主要由Nova的四大子服务组成，即 **nova-api**、**nova-conductor**、**nova-scheduler** 和 **nova-compute** 服务

1. 当用户发起一个新的请求时，该请求会先在 nova-api 中处理。
    - nova-api 会对请求进行一系列检查，包括请求是否合法，配额是否足够，是否有符合要求的网络、镜像及虚拟机类型等。
2. 检查通过后，nova-api 就会为该请求分配一个<u>唯一的虚拟机ID</u>，并在数据库中<u>新建对应的项来记录虚拟机的状态</u>。然后，nova-api 会将请求发送给 nova-conductor 处理。
3. nova-conductor 主要管理<u>服务之间的通信并进行任务处理</u>。
    - 在接收到请求之后，会为 nova-scheduler 创建一个 RequestSpec 对象用来包装与调度相关的所有请求资料
    - 然后远程调用 nova-scheduler 服务的 <u>`select_destination`</u> 接口。
4. nova-scheduler 则会通过接收到的 RequestSpec 对象
    - 首先将 RequestSpec 对象转换成 `ResourceRequest` 对象，并将该对象<u>发送给 Placement 进行一次预筛选</u>（nova-scheduler 负责与 Placement 通信）
    - 然后会<u>根据数据库中最新的系统状态做出调度决定</u>，并告诉 nova-conductor 把该请求调度到合适的计算节点上。
    - nova-conductor 在得知调度器的决定后，会把请求发送给对应的 nova-compute 服务。
5. 每个 nova-compute 服务都有<u>独立的资源监视器（`ResourceTracker`）用来监视本地主机的资源使用情况</u>。
    - 当计算节点接收到请求时，资源监视器(`ResourceTracker`)能够检查主机是否有足够的对应资源。
    - 如果对应资源足够，nova-compute 就会允许在当前主机中启动请求所要求的虚拟机，并<u>在数据库中更新虚拟机状态，同时将最新的主机资源情况更新到数据库中</u>。
    - 若当前主机不符合请求的资源要求时，则 nova-compute 会拒绝启动虚拟机，并将<u>请求重新发送给 nova-conductor 服务，从而重试整个调度过程</u>。

![nova 调度流程](https://github.com/Nevermore12321/LeetCode/blob/blog/%E4%BA%91%E8%AE%A1%E7%AE%97/OpenStack/nova-scheduler%E8%B0%83%E5%BA%A6%E6%B5%81%E7%A8%8B.jpg?raw=true)

归纳总结，整个调度过程可以分为3个主要阶段：

- **预调度阶段**，主要进行安全检查，并为将要进行的调度过程准备相应的数据项和请求对象；
- **调度决策阶段**，在此阶段Nova可能会进行超过一次的调度决策，最终将确定系统是否有能力创建相应的虚拟机，以及应当创建在哪台主机上；
- **调度结束阶段**，当调度决策完成后，nova-compute会在选择的主机上真正消耗资源，启动虚拟机和对应的网络存储设备。

在冷迁移、热迁移、Resize、Rebuild 和 Evacuate 过程中，各个子服务的功能和职责都是类似的



## 创建 vm 流程分析



### 1. nova-api

我通过 openstack 命令行创建 vm 开启调试：

```shell
openstack server create --image cirros --flavor Tiny --network NJ-LAN test
```



nova-api 收到创建 vm 的请求，nova 中创建 vm 对应的是 servers 资源的创建，Controller 代码如下(`nova/api/openstack/compute/servers.py`)：

```python
from nova.compute import api as compute


class ServersController(wsgi.Controller):
    def __init__(self):
        super(ServersController, self).__init__()
        self.compute_api = compute.API()
        self.network_api = neutron.API()
    
    # nova-api 不同版本对应了不同的 schema
    @wsgi.response(202)
    @wsgi.expected_errors((400, 403, 409))
    @validation.schema(schema_servers.base_create_v20, '2.0', '2.0')
    @validation.schema(schema_servers.base_create, '2.1', '2.18')
    @validation.schema(schema_servers.base_create_v219, '2.19', '2.31')
    @validation.schema(schema_servers.base_create_v232, '2.32', '2.32')
    @validation.schema(schema_servers.base_create_v233, '2.33', '2.36')
    @validation.schema(schema_servers.base_create_v237, '2.37', '2.41')
    @validation.schema(schema_servers.base_create_v242, '2.42', '2.51')
    @validation.schema(schema_servers.base_create_v252, '2.52', '2.56')
    @validation.schema(schema_servers.base_create_v257, '2.57', '2.62')
    @validation.schema(schema_servers.base_create_v263, '2.63', '2.66')
    @validation.schema(schema_servers.base_create_v267, '2.67', '2.73')
    @validation.schema(schema_servers.base_create_v274, '2.74')
    def create(self, req, body):
        """Creates a new server for a given user."""
        context = req.environ['nova.context']
        # request body 中的 server 字段
        server_dict = body['server']
        # 如果 request body 中有密码 adminPass 字段，返回
        # 如果 没有，则生成随机密码
        password = self._get_server_admin_password(server_dict)
        
        # server 名称 两边去空格
        name = common.normalize_name(server_dict['name'])
        
        # 获取 description 描述字段
        description = name
        if api_version_request.is_supported(req, min_version='2.19'):
            description = server_dict.get('description')

        # 实例创建函数的参数
        create_kwargs = {}
		
        # 用户信息
        create_kwargs['user_data'] = server_dict.get('user_data')
 
		# 密钥
        create_kwargs['key_name'] = server_dict.get('key_name')
        # 配置驱动
        create_kwargs['config_drive'] = server_dict.get('config_drive')
        # 安全组
        security_groups = server_dict.get('security_groups')
        if security_groups is not None:
            create_kwargs['security_groups'] = [
                sg['name'] for sg in security_groups if sg.get('name')]
            create_kwargs['security_groups'] = list(
                set(create_kwargs['security_groups']))
		
        # 用户添加的与调度相关的元数据
        scheduler_hints = {}
        if 'os:scheduler_hints' in body:
            scheduler_hints = body['os:scheduler_hints']
        elif 'OS-SCH-HNT:scheduler_hints' in body:
            scheduler_hints = body['OS-SCH-HNT:scheduler_hints']
        create_kwargs['scheduler_hints'] = scheduler_hints
		
        # 最小/最大数量，默认都是1 
        min_count = int(server_dict.get('min_count', 1))
        max_count = int(server_dict.get('max_count', min_count))
        if min_count > max_count:
            msg = _('min_count must be <= max_count')
            raise exc.HTTPBadRequest(explanation=msg)
        create_kwargs['min_count'] = min_count
        create_kwargs['max_count'] = max_count

        # 可用域 az
        availability_zone = server_dict.pop("availability_zone", None)

        # nova-api 版本大于 2.52 支持 tag 功能
        if api_version_request.is_supported(req, min_version='2.52'):
            create_kwargs['tags'] = server_dict.get('tags')

        # 此步骤是根据 request body 中传入的不同的参数，对 create_kwargs 添加不同的属性
        helpers.translate_attributes(helpers.CREATE,
                                     server_dict, create_kwargs)

        target = {
            'project_id': context.project_id,
            'user_id': context.user_id,
            'availability_zone': availability_zone}
        # 判断此用户在当前 project 下，有无 os_compute_api:servers:create 权限
        context.can(server_policies.SERVERS % 'create', target)

		# image 验证签名证书
        trusted_certs = server_dict.get('trusted_image_certificates', None)
        if trusted_certs:
            create_kwargs['trusted_certs'] = trusted_certs
            context.can(server_policies.SERVERS % 'create:trusted_certs',
                        target=target)
		
        # 根据传入的 availability_zone 字段，解析出 availability_zone 值
        # 如果 request body 中没有 availability_zone 字段，默认为配置文件中，即 nova
        parse_az = self.compute_api.parse_availability_zone
        try:
            availability_zone, host, node = parse_az(context,
                                                     availability_zone)
        except exception.InvalidInput as err:
            raise exc.HTTPBadRequest(explanation=six.text_type(err))
        if host or node:
            context.can(server_policies.SERVERS % 'create:forced_host',
                        target=target)
		
        # 如果 版本大于 2.74 ，支持 hypervisor_hostname 字段，即支持指定在哪台服务器上创建 vm
        if api_version_request.is_supported(req, min_version='2.74'):
            self._process_hosts_for_create(context, target, server_dict,
                                           create_kwargs, host, node)
		# 对 block_device_mapping(_v2) 参数的处理
        self._process_bdms_for_create(
            context, target, server_dict, create_kwargs)
		
        # request body 中有 image 就在 create_kwargs 中添加 image uuid
        # 否则添加 block_device_mapping
        image_uuid = self._image_from_req_data(server_dict, create_kwargs)
		
        # 在 create_kwargs 中添加 network 相关参数
        self._process_networks_for_create(
            context, target, server_dict, create_kwargs)
		# 从 request body 中获取 flavor id
        flavor_id = self._flavor_id_from_req_data(body)
        try:
            # 通过直接查找数据库，获取 flavor 信息
            inst_type = flavors.get_flavor_by_flavor_id(
                    flavor_id, ctxt=context, read_deleted="no")
			# request 版本 是否支持多个 volume 挂载
            supports_multiattach = common.supports_multiattach_volume(req)
            # request 版本 是否支持 port 资源
            supports_port_resource_request = \
                common.supports_port_resource_request(req)
            
            # 调用 compute_api.create 方法，真正的开始创建 vm 的业务逻辑
            (instances, resv_id) = self.compute_api.create(context,
                inst_type,
                image_uuid,
                display_name=name,
                display_description=description,
                availability_zone=availability_zone,
                forced_host=host, forced_node=node,
                metadata=server_dict.get('metadata', {}),
                admin_password=password,
                check_server_group_quota=True,
                supports_multiattach=supports_multiattach,
                supports_port_resource_request=supports_port_resource_request,
                **create_kwargs)
        except (exception.QuotaError,
                exception.PortLimitExceeded) as error:
            raise exc.HTTPForbidden(
                explanation=error.format_message())
        except exception.ImageNotFound:
            msg = _("Can not find requested image")
            raise exc.HTTPBadRequest(explanation=msg)
        except exception.KeypairNotFound:
            msg = _("Invalid key_name provided.")
            raise exc.HTTPBadRequest(explanation=msg)
        except exception.ConfigDriveInvalidValue:
            msg = _("Invalid config_drive provided.")
            raise exc.HTTPBadRequest(explanation=msg)
        except (exception.BootFromVolumeRequiredForZeroDiskFlavor,
                exception.ExternalNetworkAttachForbidden) as error:
            raise exc.HTTPForbidden(explanation=error.format_message())
        except messaging.RemoteError as err:
            msg = "%(err_type)s: %(err_msg)s" % {'err_type': err.exc_type,
                                                 'err_msg': err.value}
            raise exc.HTTPBadRequest(explanation=msg)
        except UnicodeDecodeError as error:
            msg = "UnicodeError: %s" % error
            raise exc.HTTPBadRequest(explanation=msg)
        except (exception.ImageNotActive,
                exception.ImageBadRequest,
                exception.ImageNotAuthorized,
                exception.ImageUnacceptable,
                exception.FixedIpNotFoundForAddress,
                exception.FlavorNotFound,
                exception.InvalidMetadata,
                exception.InvalidVolume,
                exception.MismatchVolumeAZException,
                exception.MultiplePortsNotApplicable,
                exception.InvalidFixedIpAndMaxCountRequest,
                exception.InstanceUserDataMalformed,
                exception.PortNotFound,
                exception.FixedIpAlreadyInUse,
                exception.SecurityGroupNotFound,
                exception.PortRequiresFixedIP,
                exception.NetworkRequiresSubnet,
                exception.NetworkNotFound,
                exception.InvalidBDM,
                exception.InvalidBDMSnapshot,
                exception.InvalidBDMVolume,
                exception.InvalidBDMImage,
                exception.InvalidBDMBootSequence,
                exception.InvalidBDMLocalsLimit,
                exception.InvalidBDMVolumeNotBootable,
                exception.InvalidBDMEphemeralSize,
                exception.InvalidBDMFormat,
                exception.InvalidBDMSwapSize,
                exception.InvalidBDMDiskBus,
                exception.VolumeTypeNotFound,
                exception.AutoDiskConfigDisabledByImage,
                exception.InstanceGroupNotFound,
                exception.SnapshotNotFound,
                exception.UnableToAutoAllocateNetwork,
                exception.MultiattachNotSupportedOldMicroversion,
                exception.CertificateValidationFailed,
                exception.CreateWithPortResourceRequestOldVersion,
                exception.DeviceProfileError,
                exception.ComputeHostNotFound) as error:
            raise exc.HTTPBadRequest(explanation=error.format_message())
        except INVALID_FLAVOR_IMAGE_EXCEPTIONS as error:
            raise exc.HTTPBadRequest(explanation=error.format_message())
        except (exception.PortInUse,
                exception.InstanceExists,
                exception.NetworkAmbiguous,
                exception.NoUniqueMatch,
                exception.MixedInstanceNotSupportByComputeService) as error:
            raise exc.HTTPConflict(explanation=error.format_message())

        # 上面是 rpc 异步调用，不会阻塞，因此直接返回结果
        if server_dict.get('return_reservation_id', False):
            return wsgi.ResponseObject({'reservation_id': resv_id})

        server = self._view_builder.create(req, instances[0])

        if CONF.api.enable_instance_password:
            server['server']['adminPass'] = password

        robj = wsgi.ResponseObject(server)

        return self._add_location(robj)

```



可以发现，nova-api 的 `ServersController `，这里只是对于创建 vm 请求的 参数封装，真正创建 vm 的业务逻辑，都是写在 `compute_api.create` 中。

在 `nova/compute/api.py` 文件中，封装了所有的关于 nova-compute 的业务功能逻辑。注意：这里不是调用 nova-compute，而只是 nova-api 对于此类 compute 功能的逻辑封装。



```python
@profiler.trace_cls("compute_api")
class API(base.Base):
    ......
    # 将实例信息发送到调度程序。
    # 调度程序将确定实例最终调度到哪台节点，并将结果存入数据库。
    # 返回 (instances, reservation_id) 的元组
    def create(self, context, instance_type,
               image_href, kernel_id=None, ramdisk_id=None,
               min_count=None, max_count=None,
               display_name=None, display_description=None,
               key_name=None, key_data=None, security_groups=None,
               availability_zone=None, forced_host=None, forced_node=None,
               user_data=None, metadata=None, injected_files=None,
               admin_password=None, block_device_mapping=None,
               access_ip_v4=None, access_ip_v6=None, requested_networks=None,
               config_drive=None, auto_disk_config=None, scheduler_hints=None,
               legacy_bdm=True, shutdown_terminate=False,
               check_server_group_quota=False, tags=None,
               supports_multiattach=False, trusted_certs=None,
               supports_port_resource_request=False,
               requested_host=None, requested_hypervisor_hostname=None):
		
        # 如果制定了多个 network，并且 max_count > 1
        if requested_networks and max_count is not None and max_count > 1:
            # 检查指定ip是否创建了多个实例
            self._check_multiple_instances_with_specified_ip(
                requested_networks)
            # 检查是否指定 port 创建了多个实例
            self._check_multiple_instances_with_neutron_ports(
                requested_networks)
		
        # 如果请求参数中有 az，那么就判断 az 是否存在
        if availability_zone:
            available_zones = availability_zones.\
                get_availability_zones(context.elevated(), self.host_api,
                                       get_only_available=True)
            if forced_host is None and availability_zone not in \
                    available_zones:
                msg = _('The requested availability zone is not available')
                raise exception.InvalidRequest(msg)
		# 生成 schedluer 使用的 filter_properties
        filter_properties = scheduler_utils.build_filter_properties(
                scheduler_hints, forced_host, forced_node, instance_type)
		
        # 创建逻辑
        return self._create_instance(
            context, instance_type,
            image_href, kernel_id, ramdisk_id,
            min_count, max_count,
            display_name, display_description,
            key_name, key_data, security_groups,
            availability_zone, user_data, metadata,
            injected_files, admin_password,
            access_ip_v4, access_ip_v6,
            requested_networks, config_drive,
            block_device_mapping, auto_disk_config,
            filter_properties=filter_properties,
            legacy_bdm=legacy_bdm,
            shutdown_terminate=shutdown_terminate,
            check_server_group_quota=check_server_group_quota,
            tags=tags, supports_multiattach=supports_multiattach,
            trusted_certs=trusted_certs,
            supports_port_resource_request=supports_port_resource_request,
            requested_host=requested_host,
            requested_hypervisor_hostname=requested_hypervisor_hostname)
```

总结：这部分主要进行了：

- 检查network是否合法
- 检查 az 是否存在
- 生成 scheduler 的 filter_properties



继续往下看 `self._create_instance`(`nova/compute/api.py`) 方法：

```python
@profiler.trace_cls("compute_api")
class API(base.Base):
    def __init__(self, image_api=None, network_api=None, volume_api=None,
                 **kwargs):
        ....
        self.compute_task_api = conductor.ComputeTaskAPI()
    	....
        
    .....
    # 验证所有输入参数，并开始创建实例
    def _create_instance(self, context, instance_type,
               image_href, kernel_id, ramdisk_id,
               min_count, max_count,
               display_name, display_description,
               key_name, key_data, security_groups,
               availability_zone, user_data, metadata, injected_files,
               admin_password, access_ip_v4, access_ip_v6,
               requested_networks, config_drive,
               block_device_mapping, auto_disk_config, filter_properties,
               reservation_id=None, legacy_bdm=True, shutdown_terminate=False,
               check_server_group_quota=False, tags=None,
               supports_multiattach=False, trusted_certs=None,
               supports_port_resource_request=False,
               requested_host=None, requested_hypervisor_hostname=None):


        # 参数标准化检查
        if reservation_id is None:
            reservation_id = utils.generate_uid('r')
        security_groups = security_groups or ['default']
        min_count = min_count or 1
        max_count = max_count or min_count
        block_device_mapping = block_device_mapping or []
        tags = tags or []

        # 如果通过 image 启动，那么从 glance 查找 image 信息
        if image_href:
            image_id, boot_meta = self._get_image(context, image_href)
        else:
            # 如果从 卷 启动，从 Cinder 获取卷的详细信息，并返回元数据
            # This is similar to the logic in _retrieve_trusted_certs_object.
            if (trusted_certs or
                (CONF.glance.verify_glance_signatures and
                 CONF.glance.enable_certificate_validation and
                 CONF.glance.default_trusted_certificate_ids)):
                msg = _("Image certificate validation is not supported "
                        "when booting from volume")
                raise exception.CertificateValidationFailed(message=msg)
            image_id = None
            boot_meta = block_device.get_bdm_image_metadata(
                context, self.image_api, self.volume_api, block_device_mapping,
                legacy_bdm)
		
        # 查看镜像的 auto_disk_config properties
        self._check_auto_disk_config(image=boot_meta,
                                     auto_disk_config=auto_disk_config)

        # 对所有输入参数进行检查
        base_options, max_net_count, key_pair, security_groups, \
            network_metadata = self._validate_and_build_base_options(
                    context, instance_type, boot_meta, image_href, image_id,
                    kernel_id, ramdisk_id, display_name, display_description,
                    key_name, key_data, security_groups, availability_zone,
                    user_data, metadata, access_ip_v4, access_ip_v6,
                    requested_networks, config_drive, auto_disk_config,
                    reservation_id, max_count, supports_port_resource_request)

		# 检查 nova-compute 的版本是否 超过 victoria ，可以支持 mixed cpu policy
        numa_topology = base_options.get('numa_topology')
        self._check_compute_service_for_mixed_instance(numa_topology)

		# 根据 quota 配置的实例最大可以请求的网络数量
        if max_net_count < min_count:
            raise exception.PortLimitExceeded()
        elif max_net_count < max_count:
            LOG.info("max count reduced from %(max_count)d to "
                     "%(max_net_count)d due to network port quota",
                     {'max_count': max_count,
                      'max_net_count': max_net_count})
            max_count = max_net_count

        block_device_mapping = self._check_and_transform_bdm(context,
            base_options, instance_type, boot_meta, min_count, max_count,
            block_device_mapping, legacy_bdm)

        # 检查 quota，检查 image 是否可以启动，检查 image 和 flavor
        self._checks_for_create_and_rebuild(context, image_id, boot_meta,
                instance_type, metadata, injected_files,
                block_device_mapping.root_bdm(), validate_numa=False)

        instance_group = self._get_requested_instance_group(context,
                                   filter_properties)

        tags = self._create_tag_list_obj(context, tags)

        # build instance request
        # RequestSpec, BuildRequest, InstanceMapping
        instances_to_build = self._provision_instances(
            context, instance_type, min_count, max_count, base_options,
            boot_meta, security_groups, block_device_mapping,
            shutdown_terminate, instance_group, check_server_group_quota,
            filter_properties, key_pair, tags, trusted_certs,
            supports_multiattach, network_metadata,
            requested_host, requested_hypervisor_hostname)

        instances = []
        request_specs = []
        build_requests = []
        for rs, build_request, im in instances_to_build:
            build_requests.append(build_request)
            instance = build_request.get_new_instance(context)
            instances.append(instance)
            request_specs.append(rs)

        # 调度，并且创建 vm
        self.compute_task_api.schedule_and_build_instances(
            context,
            build_requests=build_requests,
            request_spec=request_specs,
            image=boot_meta,
            admin_password=admin_password,
            injected_files=injected_files,
            requested_networks=requested_networks,
            block_device_mapping=block_device_mapping,
            tags=tags)

        return instances, reservation_id

```



总结：

- 参数标准化检查
- 获取 image(Glance)/卷(Cinder) 详细信息
- 对所有输入参数进行检查，并返回检查后的参数。包括：
    - 检查 flavor 状态
    - 对 user_data 进行 base64 编码
    - 检查 security_groups 的名称
    - 检查 Network 是否属于当前project，通过 Neutron Api 检查网络信息
    - 选择适合 vm 的内核和内存。可以通过以下两种方式之一选择：
        - 通过创建 vm 请求传入。 
        - 继承自 image 元数据
    - 检查是否开启了 config_drive
    - 查询 key pair(通过直接查询数据库获得)
    - 确定 `/dev/xxx` 设备
        - 名称为 image 属性中的 `properties.mappings.virtual` 为 root 时，`properties.mappings.device` 
        - 或者 image 属性中的 `properties.root_device_name`
    - 根据请求，获取 numa topology
    - 获取根据 pci 设备生成的 numa 亲和性策略，PCI 就是电脑中的总线，pci 设备就是插在总线上的设备，例如声卡、网卡等等。
    - 生成 PCIRequest 。PCI 请求来自两个来源：
        - instance flavor -> Flavor
        - requested_networks -> Neutron Api
- 检查 nova-compute 的版本是否 超过 victoria ，可以支持 mixed cpu policy
- 检查网络配额的instance最大可以请求的网络数
- (`_provision_instances`)build 出创建 vm 需要的请求对象 RequestSpec, BuildRequest, InstanceMapping，并且**将三个对象存入数据库**。
    - validate host
    - check quotas
    - check security group
    - 获取所有实例中已经存在的 volume（cinder api）
    - 




可以看到最后调用了 `compute_task_api.schedule_and_build_instances`。

compute_task_api 就是 nova-conductor 相关接口，也就是 nova-conductor 的rpc client。

源码如下：

```python
# nova/conductor/api.py
class ComputeTaskAPI(object):
    def __init__(self):
        # nova-conductor 的 rpc client
        self.conductor_compute_rpcapi = rpcapi.ComputeTaskAPI()
        self.image_api = glance.API()
    
    ......
    def schedule_and_build_instances(self, context, build_requests,
                                     request_spec, image,
                                     admin_password, injected_files,
                                     requested_networks, block_device_mapping,
                                     tags=None):
        # 调用 nova-conductor rpc client 接口
        self.conductor_compute_rpcapi.schedule_and_build_instances(
            context, build_requests, request_spec, image,
            admin_password, injected_files, requested_networks,
            block_device_mapping, tags)
 

# nova/conductor/rpcapi.py
@profiler.trace_cls("rpc")
class ComputeTaskAPI(object):
    ....
    
    def schedule_and_build_instances(self, context, build_requests,
                                     request_specs,
                                     image, admin_password, injected_files,
                                     requested_networks,
                                     block_device_mapping,
                                     tags=None):
        version = '1.17'
        kw = {'build_requests': build_requests,
              'request_specs': request_specs,
              'image': jsonutils.to_primitive(image),
              'admin_password': admin_password,
              'injected_files': injected_files,
              'requested_networks': requested_networks,
              'block_device_mapping': block_device_mapping,
              'tags': tags}

        if not self.client.can_send_version(version):
            version = '1.16'
            del kw['tags']
		
        # cast 异步rpc调用 schedule_and_build_instances 方法
        cctxt = self.client.prepare(version=version)
        cctxt.cast(context, 'schedule_and_build_instances', **kw)

```



到此，nova-api 调用结束



### 2. nova-conductor



之前也介绍过，rpc server 启动的入口在对应的 manager 中。Nova-conductor 的 入口点就在 `nova/conductor/manager.py` 文件中的 `ComputeTaskManager`

```python
@profiler.trace_cls("rpc")
class ComputeTaskManager(base.Base):
    
    
    def schedule_and_build_instances(self, context, build_requests,
                                     request_specs, image,
                                     admin_password, injected_files,
                                     requested_networks, block_device_mapping,
                                     tags=None):
        # 获取 request_specs 列表中的所有 vm uuid
        instance_uuids = [spec.instance_uuid for spec in request_specs]
        try:
            # 执行调度程序，获取一个最终可以调度的节点列表，分别对应 request_specs 列表的每一个 instance 可以调度的节点
            # 返回的是 [[Selection, ...], [Selection, ...]], Selection对象
            host_lists = self._schedule_instances(context, request_specs[0],
                    instance_uuids, return_alternates=True)
        except Exception as exc:
            LOG.exception('Failed to schedule instances')
            self._bury_in_cell0(context, request_specs[0], exc,
                                build_requests=build_requests,
                                block_device_mapping=block_device_mapping,
                                tags=tags)
            return
		# 主机信息本地缓存
        host_mapping_cache = {}
		# cell 信息的本地缓存
        cell_mapping_cache = {}
        # 最终创建的 vm 信息
        instances = []
        # 主机 az 的本地缓存
        host_az = {}  # host=az cache to optimize multi-create

        # 遍历对应的一组 build_request,request_spec,host_list
        for (build_request, request_spec, host_list) in six.moves.zip(
                build_requests, request_specs, host_lists):
            
            # 通过 context 生成一个新的 objects.Instance 对象，用于存入数据库
            instance = build_request.get_new_instance(context)
            
            # host_list 是一个或多个 Selection 对象的列表，其中第一个已被选中并声明了其资源
            host = host_list[0]
            # 将主机从 Selection 对象 转换为 cell 记录
            if host.service_host not in host_mapping_cache:
                try:
                    # 获取第一个调度主机在数据库 host_mapping 中的记录, 也就是计算节点 与 cell 的映射
                    host_mapping = objects.HostMapping.get_by_host(
                        context, host.service_host)
                    # 存入 host_mapping_cache 本地缓存
                    host_mapping_cache[host.service_host] = host_mapping
                except exception.HostMappingNotFound as exc:
                    LOG.error('No host-to-cell mapping found for selected '
                              'host %(host)s. Setup is incomplete.',
                              {'host': host.service_host})
                    self._bury_in_cell0(
                        context, request_spec, exc,
                        build_requests=[build_request], instances=[instance],
                        block_device_mapping=block_device_mapping,
                        tags=tags)
                    # This is a placeholder in case the quota recheck fails.
                    instances.append(None)
                    continue
            else:
                host_mapping = host_mapping_cache[host.service_host]
			
            # 获取 cell 的信息
            cell = host_mapping.cell_mapping

 
            # 在创建 vm 之前，做最后一次检查构建请求 BuildRequest 是否仍然存在并且没有被用户删除。
            try:
                objects.BuildRequest.get_by_instance_uuid(
                    context, instance.uuid)
            except exception.BuildRequestNotFound:
                # 如果没有找到 构建请求，说明被删除
                LOG.debug('While scheduling instance, the build request '
                          'was already deleted.', instance=instance)
                # 添加一个占位符
                instances.append(None)
				
                # 如果构建请求 BuildRequest 不存在，那么也需要删除 InstanceMapping，因为这是在 nova-api 一开始就添加到数据库中的
                try:
                    im = objects.InstanceMapping.get_by_instance_uuid(
                        context, instance.uuid)
                    im.destroy()
                except exception.InstanceMappingNotFound:
                    pass
               	
                # 注意：这里需要通知　nova-scheduler, scheduler 会调用 placement api 去删掉该 vm 的用量
                self.report_client.delete_allocation_for_instance(
                    context, instance.uuid)
                continue
            else:		# 如果找到了 构建请求
                
                # 查找当前 host 的 az 信息
                if host.service_host not in host_az:
                    # 查找 host 的 az，就是查找 host 所在 主机聚合 host aggregates 中的 availability_zone 元数据信息
                    host_az[host.service_host] = (
                        availability_zones.get_host_availability_zone(
                            context, host.service_host))
                instance.availability_zone = host_az[host.service_host]
                # Instance 对象入库
                # obj_target_cell 是保证 instance 存入对应的 cell 下的 database 中
                with obj_target_cell(instance, cell):
                    instance.create()
                    instances.append(instance)
                    cell_mapping_cache[instance.uuid] = cell

        # 在创建对象后重新检查配额，以防止用户在发生竞争时分配超过其允许配额的资源。这是可配置的
        if CONF.quota.recheck_quota:
            try:
                # 通过 project_user_quotas 表
                # 检查 quota 有没有超出配额
                compute_utils.check_num_instances_quota(
                    context, instance.flavor, 0, 0,
                    orig_num_req=len(build_requests))
            except exception.TooManyInstances as exc:
                with excutils.save_and_reraise_exception():
                    self._cleanup_build_artifacts(context, exc, instances,
                                                  build_requests,
                                                  request_specs,
                                                  block_device_mapping, tags,
                                                  cell_mapping_cache)
		# 四元组
        zipped = six.moves.zip(build_requests, request_specs, host_lists,
                              instances)
        # 遍历四元组
        for (build_request, request_spec, host_list, instance) in zipped:
            # 之前当 BuildRequest 被删除后，添加了 None 的占位符，直接跳过
            if instance is None:
                continue
            cell = cell_mapping_cache[instance.uuid]
            # host_list 是可调度的 Selection 对象列表，第一个已经声明了资源
            # 这里 pop 是为了重试
            host = host_list.pop(0)
            # 除了第一个剩下的 host 信息
            alts = [(alt.service_host, alt.nodename) for alt in host_list]
            LOG.debug("Selected host: %s; Selected node: %s; Alternates: %s",
                    host.service_host, host.nodename, alts, instance=instance)
            # 向后兼容
            filter_props = request_spec.to_legacy_filter_properties_dict()
            
            #  判断是否超过了最大重试次数
            scheduler_utils.populate_retry(filter_props, instance.uuid)
            scheduler_utils.populate_filter_properties(filter_props,
                                                       host)

            # 在 request_spec 中填充 request_allocation 也就是向 placement 请求的资源
            try:
                scheduler_utils.fill_provider_mapping(request_spec, host)
            except Exception as exc:
                # If anything failed here we need to cleanup and bail out.
                with excutils.save_and_reraise_exception():
                    self._cleanup_build_artifacts(
                        context, exc, instances, build_requests, request_specs,
                        block_device_mapping, tags, cell_mapping_cache)

            with obj_target_cell(instance, cell) as cctxt:
                # 发送 notification ，vm 的状态为 BUILDING
                notifications.send_update_with_states(cctxt, instance, None,
                        vm_states.BUILDING, None, None, service="conductor")
                # 创建 create action，并且存入 instance_actions 表
                objects.InstanceAction.action_start(
                    cctxt, instance.uuid, instance_actions.CREATE,
                    want_result=False)
                # 在表 black_device_mapping 创建对应条目
                instance_bdms = self._create_block_device_mapping(
                    cell, instance.flavor, instance.uuid, block_device_mapping)
                # 在表 tags 中创建对应条目
                instance_tags = self._create_tags(cctxt, instance.uuid, tags)

            instance.tags = instance_tags if instance_tags \
                else objects.TagList()

            # 将选中主机的 cell 更新到 instance_mappings 表
            self._map_instance_to_cell(context, instance, cell)

            # 在 instance 入库后，就可以删除 BuildRequest 构建请求了
            # 如果在这里删除 BuildRequest 时找不到，说明在此之前就被删除了，不进行任何创建 vm 的操作
            # 如果删除成功，那么继续进行 vm 的构建
            if not self._delete_build_request(
                    context, build_request, instance, cell, instance_bdms,
                    instance_tags):
                continue

            try:
                # cyborg 是一个加速管理程序
                accel_uuids = self._create_and_bind_arq_for_instance(
                        context, instance, host, request_spec)
            except Exception as exc:
                with excutils.save_and_reraise_exception():
                    self._cleanup_build_artifacts(
                        context, exc, instances, build_requests, request_specs,
                        block_device_mapping, tags, cell_mapping_cache)

            # 获取 安全组的 id
            legacy_secgroups = [s.identifier
                                for s in request_spec.security_groups]
            
            # rpc 远程异步调用 nova-compute 构建 vm
            with obj_target_cell(instance, cell) as cctxt:
                self.compute_rpcapi.build_and_run_instance(
                    cctxt, instance=instance, image=image,
                    request_spec=request_spec,
                    filter_properties=filter_props,
                    admin_password=admin_password,
                    injected_files=injected_files,
                    requested_networks=requested_networks,
                    security_groups=legacy_secgroups,
                    block_device_mapping=instance_bdms,
                    host=host.service_host, node=host.nodename,
                    limits=host.limits, host_list=host_list,
                    accel_uuids=accel_uuids)

```

总结：

1. 通过 rpc 远程调用 nova-scheduler 的接口，获取对应 request_specs 对应的一组可被调用的主机列表。

    - 具体的调用逻辑如下：

        ```python
        @profiler.trace_cls("rpc")
        class ComputeTaskManager(base.Base):
            def __init__(self):
        		.....
                # 这里其实就是 nova-scheduler 的 rpc client
                self.query_client = query.SchedulerQueryClient()
            	....
            ....
            def _schedule_instances(self, context, request_spec,
                                    instance_uuids=None, return_alternates=False):
                scheduler_utils.setup_instance_group(context, request_spec)
                with timeutils.StopWatch() as timer:
                   
                    host_lists = self.query_client.select_destinations(
                        context, request_spec, instance_uuids, return_objects=True,
                        return_alternates=return_alternates)
                LOG.debug('Took %0.2f seconds to select destinations for %s '
                          'instance(s).', timer.elapsed(), len(instance_uuids))
                return host_lists
        ```

    - 通过 rpc client 调用 nova-scheduler 的 `select_destinations` 接口，开始调度。注意：这里使用的是 同步 rpc 调用，也就是 call，因为要等待调度结束

2. 一个 vm 对应一组调度节点，但是第一个调度节点是最佳选择，并且已经声明了资源。接下来就是获取对应 vm 第一个调度节点的 host_mappings

    - `HostMapping` 对象，对应数据库的 host_mappings 表，该表存储了 host 与 cell 的映射，例如: compute1 <-> cell_id: 2
    - `HostMapping `对象中有一个 `cell_mapping` 字段，表示该 host 对应的 cell_mapping, 对应数据库中的 cell_mappings 表。cell_mappings 表存储了不同 cell 对应的 uuid，transport_url(mq), database_connection

3. 在创建 vm 之前，做最后一次检查构建请求 BuildRequest 是否仍然存在并且没有被用户删除

    - **如果 BuildRequest 被删除，那么也需要删除 InstanceMapping**
    - **如果 BuildRequest 被删除，需要通知 nova-scheduler，让 scheduler 调用 placement api，删除当前 vm 的使用量**。
    - **如果 BuildRequest 存在，那么查找当前 host 所在的 az，并且将 Instance 对象存入当前 host 所在 cell 的 database 中**。

4.  检查 quota 有没有超出配额
5. 判断是否超过了最大重试次数
6. 发送 Notification，更新 vm 的状态为 building
7. 更新数据库：
    - 在 instance_actions 表中创建 Create action 条目，类似操作日志
    - 在表 block_device_mapping 创建对应的条目
    - 在表 tags 中创建对应条目
    - 更新 instance_mappings 表中的 instance 与 cell 的映射关系，初始化创建的条目是没有 cell_id 的，因为已经选中主机了，就可以更新主机的 cell 到 instance_mappings 表
    - 在表 build_requests 删除 BuildRequest 条目，如果在此之前被删除，那么不进行 vm 的构建，如果删除成功，那么继续进行 vm 的构建
8. 调用了 cyborg，Cyborg 是加速器的通用管理框架
    - cyborg（以前称为Nomad）是用于管理硬件和软件加速资源（如 GPU、FPGA、CryptoCards和DPDK / SPDK）的框架
    - 通过Cyborg，运维者可以列出、识别和发现加速器，连接和分离加速器实例，安装和卸载驱动。它也可以单独使用或与Nova或Ironic结合使用。Cyborg可以通过Nova计算控制器或Ironic裸机控制器来配置和取消配置这些设备。
    - 在加速器方面，Nova计算控制器现在可以将Workload部署到Nvidia和Intel的虚拟化GPU（AMD GPU正在开发）。加速器可用于图形处理的场景（如虚拟桌面和工作站），还可以应用于集群上的通过虚拟化GPU以运行HPC或AI Workload的场景。
9. 通过 rpc 远程异步(cast)调用 nova-compute api，构建 vm



### 3. nova-scheduler



可以发现，nova-conductor 才是组装真正业务逻辑的地方，其中，第一步，就是 rpc 远程调用了 nova-scheduler 的 `select_destinations` 方法来获取可以被调度的主机列表。



nova-scheduler 以 rpc server 启动，其所有可以被远程调用呃呃 rpc endpoint 接口位于 manager(`nova/scheduler/manager`) 的 `SchedulerManager` 类中，下面就来看一下，获取可以被调度的主机列表的方法，也是 nova-scheduler 最重要的一个功能：`select_destinations`:

```python
class SchedulerManager(manager.Manager):
    def __init__(self, *args, **kwargs):
        self.placement_client = report.SchedulerReportClient()
        self.driver = driver.DriverManager(
            'nova.scheduler.driver',
            CONF.scheduler.driver,
            invoke_on_load=True
        ).driver
    
    
    @messaging.expected_exceptions(exception.NoValidHost)
    def select_destinations(self, ctxt, request_spec=None,
            filter_properties=None, spec_obj=_sentinel, instance_uuids=None,
            return_objects=False, return_alternates=False):

        LOG.debug("Starting to schedule for instances: %s", instance_uuids)

        if spec_obj is self._sentinel:
            spec_obj = objects.RequestSpec.from_primitives(ctxt,
                                                           request_spec,
                                                           filter_properties)
		# 判断该请求是否是 rebuild，
        is_rebuild = utils.request_is_rebuild(spec_obj)
        alloc_reqs_by_rp_uuid, provider_summaries, allocation_request_version \
            = None, None, None
        
        # 判断是否通过 placement 先筛选一遍，默认为 true
        if self.driver.USES_ALLOCATION_CANDIDATES and not is_rebuild:

            try:
                # 通过对 request_spec 请求进行过滤处理
                request_filter.process_reqspec(ctxt, spec_obj)
            except exception.RequestFilterFailed as e:
                raise exception.NoValidHost(reason=e.message)
			
            # 根据 request_spec 返回 ResourceRequest 对象，用于 placement 
            resources = utils.resources_from_request_spec(
                ctxt, spec_obj, self.driver.host_manager,
                enable_pinning_translate=True)
            # 通过 placement 先进行一遍过滤
            # 此处返回的是一个三元组，分别对应的是 alloc_reqs, provider_summaries, allocation_request_version
            res = self.placement_client.get_allocation_candidates(ctxt,
                                                                  resources)
            
            if res is None:
                res = None, None, None

            alloc_reqs, provider_summaries, allocation_request_version = res
            alloc_reqs = alloc_reqs or []
            provider_summaries = provider_summaries or {}

            # cpu 绑定相关检查
            if (resources.cpu_pinning_requested and
                    not CONF.workarounds.disable_fallback_pcpu_query):
                LOG.debug('Requesting fallback allocation candidates with '
                          'VCPU instead of PCPU')
                resources = utils.resources_from_request_spec(
                    ctxt, spec_obj, self.driver.host_manager,
                    enable_pinning_translate=False)
                # 再次通过查找 placement 获取绑定 cpu 过滤条件后的 可调度的主机列表
                res = self.placement_client.get_allocation_candidates(
                    ctxt, resources)
                if res:
                    # merge the allocation requests and provider summaries from
                    # the two requests together
                    alloc_reqs_fallback, provider_summaries_fallback, _ = res

                    alloc_reqs.extend(alloc_reqs_fallback)
                    provider_summaries.update(provider_summaries_fallback)

            # 如果没有候选主机，直接报错
            if not alloc_reqs:
                LOG.info("Got no allocation candidates from the Placement "
                         "API. This could be due to insufficient resources "
                         "or a temporary occurrence as compute nodes start "
                         "up.")
                raise exception.NoValidHost(reason="")
            else:
                # Build a dict of lists of allocation requests, keyed by
                # provider UUID, so that when we attempt to claim resources for
                # a host, we can grab an allocation request easily
                alloc_reqs_by_rp_uuid = collections.defaultdict(list)
                for ar in alloc_reqs:
                    for rp_uuid in ar['allocations']:
                        alloc_reqs_by_rp_uuid[rp_uuid].append(ar)

		# 仅当 return_objects 和 return_alternates 都为 True 时才返回 Selection 对象
        return_alternates = return_alternates and return_objects
        # 调用 scheduler driver 的 select_destinations 方法进行真正的调度选择
        selections = self.driver.select_destinations(ctxt, spec_obj,
                instance_uuids, alloc_reqs_by_rp_uuid, provider_summaries,
                allocation_request_version, return_alternates)
        # 如果 return_objects 为 false，返回 json 
        if not return_objects:
            selection_dicts = [sel[0].to_dict() for sel in selections]
            return jsonutils.to_primitive(selection_dicts)
        return selections

```



总结：

1. 判断请求是否是 rebuild 请求：
    - 通过 `spec_obj.scheduler_hints.get('_nova_check_type') == ['rebuild']` 判断
2. 判断是否通过 placement 先筛选一遍，默认为 true，后续版本会删除此标志，而且必须先通过 placement 过滤：
    - 在调用 placement 之前，先对 request_spec，也就是 `objects.ReqestSpec` 对象进行处理， 也就是在 request_spec 的 requested_destination 字段添加过滤条件，然后通过 placement 进行过滤，一共有 7 个 filter 过滤：
        - `require_tenant_aggregate`: 查找当前租户 project 下的所有主机聚合，并过滤找到所有携带 `filter_tenant_id` 元数据的主机聚合，设置为传入请求参数，要求必须满足主机聚合携带当前的 project_id。可以通过 `limit_tenants_to_placement_aggregate `配置打开或关闭。
        - `map_az_to_placement_aggregate`: 查找当前请求 request_spec 中携带的 availability zones，并将结果传入请求参数，要求必须满足 az 相匹配。可以通过 `query_placement_for_availability_zone` 配置打开或关闭
        - `require_image_type_support`：如果 vm 是通过 image 启动的，判断 image 的 disk_format 格式，然后将 trait COMPUTE_IMAGE_TYPE_QCOW2 传入请求参数。所有支持的 trait 在 os-trait 中定义。可以通过 `query_placement_for_image_type_support` 配置打开或关闭
        - `compute_status_filter`：使用 COMPUTE_STATUS_DISABLED 预过滤计算节点，也就是过滤掉禁用的 compute nodes，将 trait COMPUTE_STATUS_DISABLED 传入请求参数，作为过滤条件。
        - `isolate_aggregates`：通过匹配所有不满足 key 前缀为 "train:" ，value 值为 "required" 格式的主机聚合，传入请求的禁止参数中。可以通过 `enable_isolated_aggregate_filtering` 配置打开或关闭
        - `transform_image_metadata`：通过查找 image metadata 中某些特定的元数据，转成 trait name 传入请求参数。例如：image metadata `hw_disk_bus` <-> trait `COMPUTE_STORAGE_BUS`。可以通过 `image_metadata_prefilter` 配置打开或关闭
        - `accelerators_filter`：过滤仅允许具有加速器支持的计算节点。也就是添加 trait `COMPUTE_ACCELERATORS` 到请求参数。
    - 添加完过滤请求参数后，根据 request_spec 生成 ResourceRequest 对象
    - 向 Placement 发送 Rpc 远程调用请求 `get_allocation_candidates`，先对上面 7 个 filter 进行一遍筛选
    - cpu 绑定相关检查
3. 调用 `self.driver.select_destinations` 执行真正的调度业务逻辑。这里的 driver 其实就是 `CONF.scheduler.driver` 配置的 driver 名称，例如 `driver=filter_scheduler`。
    - 通过 stevedore 标准库来导入插件，根据entry points配置的不同，stevedore提供了三种加载插件的方式：ExtensionManager、DriverManager、HookManager：
        - **ExtensionManager**：一种通用的加载方式。这种方式下，对于给定的命名空间，会加载该命名空间下的所有插件，同时也允许同一个命名空间下的插件拥有相同的名称，其实现即为 `stevedore.extension.ExtensionManager` 类。
        - **HookManager**：在这种加载方式下，对于给定的命名空间，允许同一个命名空间下的插件拥有相同的名称，程序可以根据给定的命名空间和名称加载该名称对应的多个插件，其实现为 `stevedore.hook.HookManager` 类。
        - **DriverManager**：在这种加载方式下，对于给定的命名空间，一个名字只能对应一个 entry point，对于同一类资源有多个不同插件的情况，只能选择一个进行注册；这样，在使用时就可以根据命名空间和名称定位到某一个插件，其实现为 `stevedore.driver.DriverManager` 类。
    - Stevedore 标准库中概念：
        - **namespace**：命名空间，表示 entry points 的命名空间。
        - **name**：表示一个 entry point 的名称。
        - **entry_point**：表示从 pkg_resources 获得的一个 EntryPoint 对象。
        - **plugin**：通过调用 `entry_point.load()` 方法返回的 plugin 类。
        - **obj**：extension 被 manager 类加载时，会调用 `plugin(*args, **kwds)` 返回一个 plugin 对象。







从上面的最后一步，可以发现，`self.driver` 就是导入的是 `nova.scheduler.driver` 命名空间下的 `CONF.scheduler.driver`（默认为 `filter_scheduler`） 名称的插件，查看 setup.cfg 配置：

```python
[entry_points]
...
nova.scheduler.driver =
    filter_scheduler = nova.scheduler.filter_scheduler:FilterScheduler
...
```



那么接下来就看 `nova.scheduler.filter_scheduler.FilterSchedulers.elect_destinations` 方法的具体实现：

```python
class FilterScheduler(driver.Scheduler):
	.....
    	# 调度逻辑
    def select_destinations(self, context, spec_obj, instance_uuids,
            alloc_reqs_by_rp_uuid, provider_summaries,
            allocation_request_version=None, return_alternates=False):
        
        # 发送 LEGACY notification ，调度开始
        self.notifier.info(
            context, 'scheduler.select_destinations.start',
            dict(request_spec=spec_obj.to_legacy_request_spec_dict()))
        # 发送 versioned notification 通知
        compute_utils.notify_about_scheduler_action(
            context=context, request_spec=spec_obj,
            action=fields_obj.NotificationAction.SELECT_DESTINATIONS,
            phase=fields_obj.NotificationPhase.START)
		
        # 调度逻辑封装
        host_selections = self._schedule(context, spec_obj, instance_uuids,
                alloc_reqs_by_rp_uuid, provider_summaries,
                allocation_request_version, return_alternates)
        # 发送 LEGACY notification ，调度结束
        self.notifier.info(
            context, 'scheduler.select_destinations.end',
            dict(request_spec=spec_obj.to_legacy_request_spec_dict()))
        
        # 发送 versioned notification 通知
        compute_utils.notify_about_scheduler_action(
            context=context, request_spec=spec_obj,
            action=fields_obj.NotificationAction.SELECT_DESTINATIONS,
            phase=fields_obj.NotificationPhase.END)
        return host_selections

    # 调度业务
    def _schedule(self, context, spec_obj, instance_uuids,
            alloc_reqs_by_rp_uuid, provider_summaries,
            allocation_request_version=None, return_alternates=False):
        
        elevated = context.elevated()


		# 获取所有计算节点信息，这里的 hosts 是一个生成器，返回的是  HostState 对象
        hosts = self._get_all_host_states(elevated, spec_obj,
            provider_summaries)

        # 计算请求中，需要创建 vm 的个数
        num_instances = (len(instance_uuids) if instance_uuids
                         else spec_obj.num_instances)

        # 备用主机，如果最佳调度主机创建 vm 失败，可以继续从备用主机中创建 vm
        # 可返回最大的备用主机数量，由 CONF.scheduler.max_attempts 配置
        # return_alternates 表示可以返回 备用主机列表
        num_alts = (CONF.scheduler.max_attempts - 1
                    if return_alternates else 0)
        
		# 旧版本，不支持 placement 调用，需要使用旧版本的 调度程序（filter and weigher）
        if (instance_uuids is None or
                not self.USES_ALLOCATION_CANDIDATES or
                alloc_reqs_by_rp_uuid is None):
            return self._legacy_find_hosts(context, num_instances, spec_obj,
                                           hosts, num_alts,
                                           instance_uuids=instance_uuids)

        # 存放在 placement 声明资源成功的 instance uuid 列表
        # 如果最后无法成功 claim 所有 instance，那么需要将这些已经在 placement 声明过的ins 资源删除
        claimed_instance_uuids = []

        # 已经 claim 声明过的主机列表，也就是已选中的主机
        claimed_hosts = []

        for num, instance_uuid in enumerate(instance_uuids):
            # 在批量创建 vm 时，instance_uuid 有多个不同的，而 spec_obj(request_spec) 只有一个，
            # 因此每次都更新 spec_obj 中的 uuid
            spec_obj.instance_uuid = instance_uuid
            # Reset the field so it's not persisted accidentally.
            spec_obj.obj_reset_changes(['instance_uuid'])

            # 执行 filter and weigher 调度程序
			# 获得一个可调度主机列表，第一个是最佳选择，后面都是备用主机
            hosts = self._get_sorted_hosts(spec_obj, hosts, num)
            # 如果没有可调度的主机，直接跳出
            if not hosts:
                break

            # 遍历所有 filter 后的主机列表，查找这列列表是否通过了 placement 的资源声明
            # 也就是 placement 会 check 主机是否具有足够的资源分配给要创建的 vm
            claimed_host = None
            for host in hosts:
                cn_uuid = host.uuid
                if cn_uuid not in alloc_reqs_by_rp_uuid:
                    msg = ("A host state with uuid = '%s' that did not have a "
                           "matching allocation_request was encountered while "
                           "scheduling. This host was skipped.")
                    LOG.debug(msg, cn_uuid)
                    continue
				# 如果通过了 placement 的 资源声明，就找到第一个 allocation_requests 去 placement 真正的 claim resource
                alloc_reqs = alloc_reqs_by_rp_uuid[cn_uuid]
                alloc_req = alloc_reqs[0]
                # 去 placement 声明资源
                # 如果成功，将该主机添加到 claimed_host 中，跳出
                if utils.claim_resources(elevated, self.placement_client,
                        spec_obj, instance_uuid, alloc_req,
                        allocation_request_version=allocation_request_version):
                    claimed_host = host
                    break
			
            
            # 对所有的 host 进行 资源声明后，如果没有声明成功的主机，直接进行下一个 vm 的调度
            if claimed_host is None:
                LOG.debug("Unable to successfully claim against any host.")
                break

            claimed_instance_uuids.append(instance_uuid)
            claimed_hosts.append(claimed_host)

            # 如果声明成功，那么就要在对应 计算节点上 减去 当前 vm 的用量，以便下一个 vm 调度时，能获取到最新的资源使用情况
            self._consume_selected_host(claimed_host, spec_obj,
                                        instance_uuid=instance_uuid)

        # 检查是否为每一个 vm 都分配了主机，如果没有，报错 NoValidHost  
        self._ensure_sufficient_hosts(context, claimed_hosts, num_instances,
                claimed_instance_uuids)

        # 生成备用主机列表
        selections_to_return = self._get_alternate_hosts(
            claimed_hosts, spec_obj, hosts, num, num_alts,
            alloc_reqs_by_rp_uuid, allocation_request_version)
        return selections_to_return

```

总结：

- 每当选中主机时，实际上都会消耗它上面的资源，因此后续的选择应该相应地进行调整。
- 首先要获取最新的所有计算节点的信息
    - 首先判断有没有指定的 cell，如果没有，就获取所有的 cellmapping，来找到所有 cell 的compute nodes，否则就获取某个特定 cell 的 compute nodes
    - 在上面获取 cell 下 compute nodes 步骤中，使用了并行的方式（并行读取数据库），采用 eventlet 的 greenThread 绿色线程 与 eventlet.queue 实现。有兴趣可以继续阅读，具体文件
        - 调用位于 `nova/scheduler/host_manager.py`  文件下的 `_get_computes_for_cells` 方法
        - 实现位于 `nova/context.py` 下的 `scatter_gather_cells` 方法
    - 获取到 compute node 计算节点信息后，生成 HostStates 对象，用来在内存中保存一份 compute node 信息，最后返回一个 HostState 对象的生成器
- 计算需要创建 vm 的个数，以及 可返回备用主机的个数：
    - return_alternates 表示可以返回备用主机列表
    - 可返回最大的备用主机数量，由 CONF.scheduler.max_attempts 配置
- 执行 filter and weigher 调度程序(`self._get_sorted_hosts`)，获得一个可调度主机列表，第一个是最佳选择，后面都是备用主机
- 之前在调用 placement api 时，已经判断了主机是否可以申请到 vm 需要的这些资源用量的 allocation_request，存放在 allocation 中，遍历 filter 过后的主机列表，查找有没有通过 placement 声明资源可用
    - 如果没通过，直接跳过该主机
    - 否则，就找到第一个 allocation_requests 去 placement 真正的 claim resource

- 对所有的 host 进行 资源声明后，如果没有声明成功的主机，直接进行下一个 vm 的调度
- 如果声明成功，那么就要在**对应 计算节点上 减去 当前 vm 的用量，以便下一个 vm 调度时，能获取到最新的资源使用情况**
    - 例如，第一个 vm 调度完成，选择 host1 主机，那么在本地存储的 HostState 对象就应该减去 vm 的用量，当下一个 vm 开始调度时，能够获取的上一个 vm 调度完成后的资源用量。
    - `self._consume_selected_host` 方法的主要作用就是，每一个 host 信息都存放在 HostState 对象中，第一个 vm 调度成功后，就需要在对应的主机 HostState 对象中减去 vm 所需的 vcpu、ram、disk 信息。
- 检查是否为每一个 vm 都分配了主机，如果没有，报错 NoValidHost
- 最后生成备用主机列表，再次调用 `self._get_sorted_hosts` 方法，来筛选，原因：
    - 假设由两个 vm 需要调度，第一次调度完成后，有一系列 hosts_1 满足要求
    - 第二个 vm 调度时，肯定是根据 第一个 vm 调度完后的结果，因为批量 vm 的用量是一样的，因此只有这些主机满足，那么对 hosts_1 在进行一次筛选，得到 hosts_2
    - 当要为所有的选定主机，筛选出备用主机时，肯定也要 hosts_2 的基础上进行再次过滤





而 `self._get_sorted_hosts` 方法是如何调度的，可以查看 nova-scheduler 文章



### 4. nova-compute



nova-conductor 组装业务逻辑中，通过 nova-scheduler 选择主机后，最后 rpc 远程调用了 nova-compute 的 `build_and_run_instance` 方法来最终在指定的节点上运行 vm。



nova-compute 同样是一个 rpc server，其入口点就在 `nova/compute/manager.py` 文件中的 `ComputeManager` 类中，下面我们具体来看 `build_and_run_instance` 方法的源码：

```python
class ComputeManager(manager.Manager):
    def __init__(self, compute_driver=None, *args, **kwargs):
        self.reportclient = report.SchedulerReportClient()
        self.virtapi = ComputeVirtAPI(self)
        
        # max_concurrent_builds 用于配置 并发创建虚拟机 的最大数量
        if CONF.max_concurrent_builds != 0:
            self._build_semaphore = eventlet.semaphore.Semaphore(
                CONF.max_concurrent_builds)
        else:
            self._build_semaphore = compute_utils.UnlimitedSemaphore()
        ....
        
        
    @wrap_exception()
    @reverts_task_state
    @wrap_instance_fault
    def build_and_run_instance(self, context, instance, image, request_spec,
                     filter_properties, admin_password=None,
                     injected_files=None, requested_networks=None,
                     security_groups=None, block_device_mapping=None,
                     node=None, limits=None, host_list=None, accel_uuids=None):

        @utils.synchronized(instance.uuid)
        def _locked_do_build_and_run_instance(*args, **kwargs):
            # 采用信号量保持多个异步任务同步，确保在我们等待其他 instance 创建时，没有别的任务来修改
            with self._build_semaphore:
                try:
                    # 封装的 build vm 的方法
                    result = self._do_build_and_run_instance(*args, **kwargs)
                except Exception:
                    # 如果执行构建 vm 任务有异常，返回 Failed 状态
                    result = build_results.FAILED
                    raise
                finally:
                    if result == build_results.FAILED:
                        # 如果构建失败，需要在 placement 中删除资源的声明
                        self.reportclient.delete_allocation_for_instance(
                            context, instance.uuid)

                    if result in (build_results.FAILED,
                                  build_results.RESCHEDULED):
                        self._build_failed(node)
                    else:
                        self._build_succeeded(node)

        # 采用 eventlet.spawn_n 来实现异步任务 _locked_do_build_and_run_instance 的调用
        utils.spawn_n(_locked_do_build_and_run_instance,
                      context, instance, image, request_spec,
                      filter_properties, admin_password, injected_files,
                      requested_networks, security_groups,
                      block_device_mapping, node, limits, host_list,
                      accel_uuids)

```

总结：

1. 使用 `eventlet.spwan_n` 实现创建 vm 的异步任务 `_locked_do_build_and_run_instance` 的调用
2. 在异步任务中 `_locked_do_build_and_run_instance` 中：
    - 采用信号量，来同步多个并发创建虚拟机任务
    - `_do_build_and_run_instance` 进一步封装了 构建 vm 的业务逻辑
    - 如果构建 vm 出错，那么需要删除 placement 中的资源声明：
        - reportclient 是在 `nova/scheduler/client` 目录下封装的与 placement 交互的功能类
        - `delete_allocation_for_instance` 方法作用就是在 placement 删除 `/allocations/[instance_uuid]` 的资源分配
    - 并且添加成功/失败 节点的统计信息：
        - 如果失败，增加给定节点的 failed_builds 统计信息，通过 `CONF.compute.consecutive_build_service_disable_threshold` 配置控制开关
        - 如果成功，重置给定节点的 failed_builds 统计信息





构建 vm 的逻辑在 `self._do_build_and_run_instance` 函数中，源码如下：

```python
class ComputeManager(manager.Manager):
    def __init__(self, compute_driver=None, *args, **kwargs):
    	self.compute_task_api = conductor.ComputeTaskAPI()
    	...
        
    ......
    @wrap_exception()
    @reverts_task_state
    @wrap_instance_event(prefix='compute')
    @wrap_instance_fault
    def _do_build_and_run_instance(self, context, instance, image,
            request_spec, filter_properties, admin_password, injected_files,
            requested_networks, security_groups, block_device_mapping,
            node=None, limits=None, host_list=None, accel_uuids=None):

        try:
            # 修改数据库 instances 表中 vm 的状态，
            LOG.debug('Starting instance...', instance=instance)
            instance.vm_state = vm_states.BUILDING
            instance.task_state = None
            instance.save(expected_task_state=
                    (task_states.SCHEDULING, None))
        except exception.InstanceNotFound:
            msg = 'Instance disappeared before build.'
            LOG.debug(msg, instance=instance)
            return build_results.FAILED
        except exception.UnexpectedTaskStateError as e:
            LOG.debug(e.format_message(), instance=instance)
            return build_results.FAILED

        # 对要注入文件进行 base64 解码
        decoded_files = self._decode_files(injected_files)

        if limits is None:
            limits = {}
		
        # 通过 libvirt driver 获取当前 compute node 的 hostname
        if node is None:
            node = self._get_nodename(instance, refresh=True)

        try:
            # StopWatch 是一个简单的计时器
            with timeutils.StopWatch() as timer:
                # 构建 vm
                self._build_and_run_instance(context, instance, image,
                        decoded_files, admin_password, requested_networks,
                        security_groups, block_device_mapping, node, limits,
                        filter_properties, request_spec, accel_uuids)
            LOG.info('Took %0.2f seconds to build instance.',
                     timer.elapsed(), instance=instance)
            return build_results.ACTIVE
        # 需要重新调度
        except exception.RescheduledException as e:
            retry = filter_properties.get('retry')
            if not retry:
                # 不 retry
                LOG.debug("Retry info not present, will not reschedule",
                    instance=instance)
                # 清除 已经创建的网络
                self._cleanup_allocated_networks(context, instance,
                    requested_networks)
                # 将错误信息入库
                compute_utils.add_instance_fault_from_exc(context,
                        instance, e, sys.exc_info(),
                        fault_message=e.kwargs['reason'])
                # 将 instance 的 所在 host、node等 字段置空，表示 vm 失败
                self._nil_out_instance_obj_host_and_node(instance)
                # 设置 instance 的 vm_state 为 Error
                self._set_instance_obj_error_state(instance,
                                                   clean_task_state=True)
                return build_results.FAILED
           
        	# 需要 retry
            LOG.debug(e.format_message(), instance=instance)
            # 记录 retry 的日志 trace 和 reason
            retry['exc'] = traceback.format_exception(*sys.exc_info())
            retry['exc_reason'] = e.kwargs['reason']

            # 清除已创建的网络
            self._cleanup_allocated_networks(context, instance,
                                             requested_networks)
			
            # 修改 instance 的状态
            self._nil_out_instance_obj_host_and_node(instance)
            instance.task_state = task_states.SCHEDULING
            instance.save()
            # 通知 placement ，将之前已声明的资源释放
            self.reportclient.delete_allocation_for_instance(context,
                                                             instance.uuid)
			
            # 通过远程 rpc 调用 nova-conducdor 接口，告知重新构建 vm
            self.compute_task_api.build_instances(context, [instance],
                    image, filter_properties, admin_password,
                    injected_files, requested_networks, security_groups,
                    block_device_mapping, request_spec=request_spec,
                    host_lists=[host_list])
            return build_results.RESCHEDULED
        # vm 在构建过程中被删除
        except (exception.InstanceNotFound,
                exception.UnexpectedDeletingTaskStateError):
            msg = 'Instance disappeared during build.'
            LOG.debug(msg, instance=instance)
            self._cleanup_allocated_networks(context, instance,
                    requested_networks)
            return build_results.FAILED
        
        # 其他错误
    	except Exception as e:
            if isinstance(e, exception.BuildAbortException):
                LOG.error(e.format_message(), instance=instance)
            else:
                # Should not reach here.
                LOG.exception('Unexpected build failure, not rescheduling '
                              'build.', instance=instance)
            self._cleanup_allocated_networks(context, instance,
                    requested_networks)
            self._cleanup_volumes(context, instance,
                    block_device_mapping, raise_exc=False)
            compute_utils.add_instance_fault_from_exc(context, instance,
                    e, sys.exc_info())
            self._nil_out_instance_obj_host_and_node(instance)
            self._set_instance_obj_error_state(instance, clean_task_state=True)
            return build_results.FAILED

```



总结：

- 修改数据库 instances 表中 vm 的状态，vm_state 为 building 状态
    - vm_state: 表示 vm 当前状态
    - task_state：表示 vm 构建阶段

- 对要注入文件进行 base64 解码
- 执行 vm 构建方法 `self._build_and_run_instance`
    - 执行过程中如果出现 `RescheduledException` 异常，说明需要重新调度
        - 如果不重试：
            - 需要清除已创建的网络，例如 vif 虚拟接口，删除的方法就是使用 oslo_privsep 执行 `ip link delete` 命令
            - 将出错信息写入数据库的 instance_faults 表中
            - 将 instance 的 所在 host、node、launched_on、availability_zone 字段置空，表示 vm 失败。注意：这一步并没有直接入库，因为后面同样会修改 instance 数据，所以多次对数据库的写入，合并至一次
            - 设置 instance 的 vm_state 为 Error，设置为 None，此时调用 `instance.save` 方法，将对 instance 的修改入库，两次合并至一次写入
        - 如果重试：
            - 记录 retry 的日志 trace 与 reason
            - 修改 instance host、node 等字段为空，并且设置 task_state 为 scheduling，并且存入数据库
            - 清除已创建网络
            - 在构建 vm 之前 scheduler 已经在 placement 中声明了该计算节点的资源，需要释放
            - 通过远程 rpc 调用 nova-conductor 接口，告知重新构建 vm
    - 执行过程中如果出现 `InstanceNotFound` 异常，说明在构建 vm 时，vm 已被删除
    - 其他错误，同样需要清理





接下来继续深入查看  vm 构建方法 `self._build_and_run_instance` ：

```python
class ComputeManager(manager.Manager):
    ......
    def _build_and_run_instance(self, context, instance, image, injected_files,
            admin_password, requested_networks, security_groups,
            block_device_mapping, node, limits, filter_properties,
            request_spec=None, accel_uuids=None):
		
        # 获取 image name
        image_name = image.get('name')
        # 发送 legacy 和 versioned  notification
        self._notify_about_instance_usage(context, instance, 'create.start',
                extra_usage_info={'image_name': image_name})
        compute_utils.notify_about_instance_create(
            context, instance, self.host,
            phase=fields.NotificationPhase.START,
            bdms=block_device_mapping)

        # 更新 system_metadata
        instance.system_metadata.update(
            {'boot_roles': ','.join(context.roles)})

        # 检查libvirt是否支持 device tag
        self._check_device_tagging(requested_networks, block_device_mapping)
        self._check_trusted_certs(instance)
		
        # 获取 request_spec 中的 requested_resource 列表，在 placement　中申请的资源映射
        provider_mapping = self._get_request_group_mapping(request_spec)

        if provider_mapping:
            try:
                compute_utils\
                    .update_pci_request_spec_with_allocated_interface_name(
                        context, self.reportclient, instance, provider_mapping)
            except (exception.AmbiguousResourceProviderForPCIRequest,
                    exception.UnexpectedResourceProviderNameForPCIRequest
                    ) as e:
                raise exception.BuildAbortException(
                    reason=six.text_type(e), instance_uuid=instance.uuid)

        # 从　placement　中获取　资源　allocation
        allocs = self.reportclient.get_allocations_for_consumer(
                context, instance.uuid)

        try:
            # 获取 request_spec 中的 scheduler_hints 字段，用户为调度添加的一些自定义元数据
            scheduler_hints = self._get_scheduler_hints(filter_properties,
                                                        request_spec)
            
            # 重要，在 vm 构建之前，nova-compute 先进行 资源的 claim
            with self.rt.instance_claim(context, instance, node, allocs,
                                        limits):
                # 检查 instance group 的策略限制
                self._validate_instance_group_policy(context, instance,
                                                     scheduler_hints)
                # image metadata
                image_meta = objects.ImageMeta.from_dict(image)
				
                # 创建网络资源，绑定 volume 块设备
                with self._build_resources(context, instance,
                        requested_networks, security_groups, image_meta,
                        block_device_mapping, provider_mapping,
                        accel_uuids) as resources:
                    
                    # 更新 instance 状态，并入库
                    instance.vm_state = vm_states.BUILDING
                    instance.task_state = task_states.SPAWNING
                    instance.save(expected_task_state=
                            task_states.BLOCK_DEVICE_MAPPING)
                    block_device_info = resources['block_device_info']
                    network_info = resources['network_info']
                    accel_info = resources['accel_info']
                    LOG.debug('Start spawning the instance on the hypervisor.',
                              instance=instance)
                    with timeutils.StopWatch() as timer:
                        self.driver.spawn(context, instance, image_meta,
                                          injected_files, admin_password,
                                          allocs, network_info=network_info,
                                          block_device_info=block_device_info,
                                          accel_info=accel_info)
                    LOG.info('Took %0.2f seconds to spawn the instance on '
                             'the hypervisor.', timer.elapsed(),
                             instance=instance)
        except (exception.InstanceNotFound,
                exception.UnexpectedDeletingTaskStateError) as e:
            with excutils.save_and_reraise_exception():
                self._notify_about_instance_usage(context, instance,
                    'create.error', fault=e)
                compute_utils.notify_about_instance_create(
                    context, instance, self.host,
                    phase=fields.NotificationPhase.ERROR, exception=e,
                    bdms=block_device_mapping)
        except exception.ComputeResourcesUnavailable as e:
            LOG.debug(e.format_message(), instance=instance)
            self._notify_about_instance_usage(context, instance,
                    'create.error', fault=e)
            compute_utils.notify_about_instance_create(
                    context, instance, self.host,
                    phase=fields.NotificationPhase.ERROR, exception=e,
                    bdms=block_device_mapping)
            raise exception.RescheduledException(
                    instance_uuid=instance.uuid, reason=e.format_message())
        except exception.BuildAbortException as e:
            with excutils.save_and_reraise_exception():
                LOG.debug(e.format_message(), instance=instance)
                self._notify_about_instance_usage(context, instance,
                    'create.error', fault=e)
                compute_utils.notify_about_instance_create(
                    context, instance, self.host,
                    phase=fields.NotificationPhase.ERROR, exception=e,
                    bdms=block_device_mapping)
        except exception.NoMoreFixedIps as e:
            LOG.warning('No more fixed IP to be allocated',
                        instance=instance)
            self._notify_about_instance_usage(context, instance,
                    'create.error', fault=e)
            compute_utils.notify_about_instance_create(
                    context, instance, self.host,
                    phase=fields.NotificationPhase.ERROR, exception=e,
                    bdms=block_device_mapping)
            msg = _('Failed to allocate the network(s) with error %s, '
                    'not rescheduling.') % e.format_message()
            raise exception.BuildAbortException(instance_uuid=instance.uuid,
                    reason=msg)
        except (exception.ExternalNetworkAttachForbidden,
                exception.VirtualInterfaceCreateException,
                exception.VirtualInterfaceMacAddressException,
                exception.FixedIpInvalidOnHost,
                exception.UnableToAutoAllocateNetwork,
                exception.NetworksWithQoSPolicyNotSupported) as e:
            LOG.exception('Failed to allocate network(s)',
                          instance=instance)
            self._notify_about_instance_usage(context, instance,
                    'create.error', fault=e)
            compute_utils.notify_about_instance_create(
                    context, instance, self.host,
                    phase=fields.NotificationPhase.ERROR, exception=e,
                    bdms=block_device_mapping)
            msg = _('Failed to allocate the network(s), not rescheduling.')
            raise exception.BuildAbortException(instance_uuid=instance.uuid,
                    reason=msg)
        except (exception.FlavorDiskTooSmall,
                exception.FlavorMemoryTooSmall,
                exception.ImageNotActive,
                exception.ImageUnacceptable,
                exception.InvalidDiskInfo,
                exception.InvalidDiskFormat,
                cursive_exception.SignatureVerificationError,
                exception.CertificateValidationFailed,
                exception.VolumeEncryptionNotSupported,
                exception.InvalidInput,
                # TODO(mriedem): We should be validating RequestedVRamTooHigh
                # in the API during server create and rebuild.
                exception.RequestedVRamTooHigh) as e:
            self._notify_about_instance_usage(context, instance,
                    'create.error', fault=e)
            compute_utils.notify_about_instance_create(
                    context, instance, self.host,
                    phase=fields.NotificationPhase.ERROR, exception=e,
                    bdms=block_device_mapping)
            raise exception.BuildAbortException(instance_uuid=instance.uuid,
                    reason=e.format_message())
        except Exception as e:
            LOG.exception('Failed to build and run instance',
                          instance=instance)
            self._notify_about_instance_usage(context, instance,
                    'create.error', fault=e)
            compute_utils.notify_about_instance_create(
                    context, instance, self.host,
                    phase=fields.NotificationPhase.ERROR, exception=e,
                    bdms=block_device_mapping)
            raise exception.RescheduledException(
                    instance_uuid=instance.uuid, reason=six.text_type(e))

        # NOTE(alaski): This is only useful during reschedules, remove it now.
        instance.system_metadata.pop('network_allocated', None)

        # If CONF.default_access_ip_network_name is set, grab the
        # corresponding network and set the access ip values accordingly.
        network_name = CONF.default_access_ip_network_name
        if (network_name and not instance.access_ip_v4 and
                not instance.access_ip_v6):
            # Note that when there are multiple ips to choose from, an
            # arbitrary one will be chosen.
            for vif in network_info:
                if vif['network']['label'] == network_name:
                    for ip in vif.fixed_ips():
                        if not instance.access_ip_v4 and ip['version'] == 4:
                            instance.access_ip_v4 = ip['address']
                        if not instance.access_ip_v6 and ip['version'] == 6:
                            instance.access_ip_v6 = ip['address']
                    break

        self._update_instance_after_spawn(instance)

        try:
            instance.save(expected_task_state=task_states.SPAWNING)
        except (exception.InstanceNotFound,
                exception.UnexpectedDeletingTaskStateError) as e:
            with excutils.save_and_reraise_exception():
                self._notify_about_instance_usage(context, instance,
                    'create.error', fault=e)
                compute_utils.notify_about_instance_create(
                    context, instance, self.host,
                    phase=fields.NotificationPhase.ERROR, exception=e,
                    bdms=block_device_mapping)

        self._update_scheduler_instance_info(context, instance)
        self._notify_about_instance_usage(context, instance, 'create.end',
                extra_usage_info={'message': _('Success')},
                network_info=network_info)
        compute_utils.notify_about_instance_create(context, instance,
                self.host, phase=fields.NotificationPhase.END,
                bdms=block_device_mapping)

```

总结：

- 发送 notification
- 检查libvirt是否支持 device tag、trust cert
- 从　placement　中获取　资源　allocation，也就是期望从某个　Resource　Provider　获得的资源类型和数量
- 重要，在 vm 构建之前，nova-compute 先进行 资源的 claim
    - 先判断当前计算机节点是否有足够资源来创建 vm，也就是一个 **预声明** 。
- 检查 instance group 的策略限制
    - 例如 host1 不能与 host2 在同一台计算节点上创建等策略检查
- `self._build_resources` 上下文管理器的作用有：
    - 入口：主要做两件事：
        - 网络设备的创建，向 neutron 发送请求创建相关网络资源，在此阶段，会修改 instance 的 vm_state 状态为 building，task_state 状态为 networking，并入库
        - block device 块设备的准备，向 cinder 发送 attach 请求绑定 volume，在此阶段，会修改 instance 的 vm_state 状态为 building，task_state 状态为 block_device_mapping，并入库
    - 出口：如果在此上下文管理器中执行的代码异常，做异常处理
- 网络、块设备准备好后，更新 instance 状态 vm_state 为 building，task_state 为 spawning，并入库
- 调用 LibvirtDriver 的 `self.driver.spawn` 接口来生成 vm 所需的 xml 文件
- 在上述操作过程遇到的错误，都需要特殊处理
- 最后创建 vm 后，将 vm 的 vm_state 状态更新为 active，如果需要固定 ip，那么选择第一个，绑定。并发送 vm 创建成功的 notification





最后，我们看一下 libvirt 创建 vm 所需的 xml 文件是如何生成的。

上面步骤中调用了 LibvirtDriver 的 `self.driver.spawn` 方法，源码如下(`nova/virt/libvirt/driver.py`)：

```python
class LibvirtDriver(driver.ComputeDriver):
    def spawn(self, context, instance, image_meta, injected_files,
              admin_password, allocations, network_info=None,
              block_device_info=None, power_on=True, accel_info=None):
		.....
		
        # 生成 xml 
        xml = self._get_guest_xml(context, instance, network_info,
                                  disk_info, image_meta,
                                  block_device_info=block_device_info,
                                  mdevs=mdevs, accel_info=accel_info)
        # 通过 xml ，调用 python-libvirt 标准库进行 vm 的创建
        self._create_guest_with_network(
            context, xml, instance, network_info, block_device_info,
            post_xml_callback=gen_confdrive,
            power_on=power_on,
            cleanup_instance_dir=created_instance_dir,
            cleanup_instance_disks=created_disks)
        LOG.debug("Guest created on hypervisor", instance=instance)
		......


    def _get_guest_xml(self, context, instance, network_info, disk_info,
                       image_meta, rescue=None,
                       block_device_info=None,
                       mdevs=None, accel_info=None):
        .......
        # 生成 vm 的全配置
        conf = self._get_guest_config(instance, network_info, image_meta,
                                      disk_info, rescue, block_device_info,
                                      context, mdevs, accel_info)
        # 根据配置 生成 xml
        xml = conf.to_xml()

        LOG.debug('End _get_guest_xml xml=%(xml)s',
                  {'xml': xml}, instance=instance)
        return xml
   	
    
    
    def _get_guest_config(self, instance, network_info, image_meta,
                          disk_info, rescue=None, block_device_info=None,
                          context=None, mdevs=None, accel_info=None):
 
        .....
    	# LibvirtConfigGuest 类就是配置的一个基类，也就是 xml 的根
        guest = vconfig.LibvirtConfigGuest()
		
        # 后面的逻辑都是在填充这个 配置类
        guest.virt_type = virt_type
        guest.name = instance.name
        guest.uuid = instance.uuid
        # We are using default unit for memory: KiB
        guest.memory = flavor.memory_mb * units.Ki
        guest.vcpus = flavor.vcpus

        guest_numa_config = self._get_guest_numa_config(
            instance.numa_topology, flavor, image_meta)

        guest.cpuset = guest_numa_config.cpuset
        guest.cputune = guest_numa_config.cputune
        guest.numatune = guest_numa_config.numatune
        ......
```





