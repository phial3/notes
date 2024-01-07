# nova Rebuild 重建过程

[toc]



## Rebuild

如果 instance 损坏了，可以通过 snapshot 恢复，这个恢复的操作就是 Rebuild。

Rebuild 会用 snapshot 替换 instance 当前的镜像文件，同时保持 instance 的其他诸如网络，资源分配属性不变。



## nova-api 入口



本文基于 Victoria 版本进行源码分析



可以通过 horizon 将某一个 instance 重建，并指定一个 image，对于 volume ，image 不可变。



nova-api 的入口在 `nova.api.openstack.compute.servers.ServersController._action_rebuild`，主要步骤为：

- 判断 policy
- 调用 compute_api 的 rebuild 方法
- 生成 response

```python
class ServersController(wsgi.Controller):
    @wsgi.response(202)
    @wsgi.expected_errors((400, 403, 404, 409))
    @wsgi.action('rebuild')
    @validation.schema(schema_servers.base_rebuild_v20, '2.0', '2.0')
    @validation.schema(schema_servers.base_rebuild, '2.1', '2.18')
    @validation.schema(schema_servers.base_rebuild_v219, '2.19', '2.53')
    @validation.schema(schema_servers.base_rebuild_v254, '2.54', '2.56')
    @validation.schema(schema_servers.base_rebuild_v257, '2.57', '2.62')
    @validation.schema(schema_servers.base_rebuild_v263, '2.63')
    def _action_rebuild(self, req, id, body):
        """Rebuild an instance with the given attributes."""
        rebuild_dict = body['rebuild']
		
        # 指定的重建镜像
        image_href = rebuild_dict["imageRef"]
        password = self._get_server_admin_password(rebuild_dict)

        # 检查 policy
        context = req.environ['nova.context']
        instance = self._get_server(context, req, id)
        target = {'user_id': instance.user_id,
                  'project_id': instance.project_id}
        context.can(server_policies.SERVERS % 'rebuild', target=target)
        
        ....
        
        try:
            # 调用 compute_api rebuild 方法
            self.compute_api.rebuild(context,
                                     instance,
                                     image_href,
                                     password,
                                     **kwargs)
        except (
            exception.InstanceIsLocked,
            exception.OperationNotSupportedForVTPM,
        ) as e:
            ....
```





compute_api.rebuild 位于 `nova.compute.api.API.rebuild`，主要步骤：

- 对参数、key pair、image、flavor 等的检查
- 判断 root_bdm 是否是 volume 类型
- 如果是 volume 类型，判断 volume 的 image_id 与 api 传入的 image_id 是否相同
- 修改 instance 状态为 rebuilding
- 删除 instance system_metadata 中的 image 相关信息

```python
@profiler.trace_cls("compute_api")
class API(base.Base):
    @reject_vtpm_instances(instance_actions.REBUILD)
    @block_accelerators(until_service=SUPPORT_ACCELERATOR_SERVICE_FOR_REBUILD)
    # TODO(stephenfin): We should expand kwargs out to named args
    @check_instance_lock
    # 检查vm状态，只有在指定的状态下才可以执行
    @check_instance_state(vm_state=[vm_states.ACTIVE, vm_states.STOPPED,
                                    vm_states.ERROR])
    def rebuild(self, context, instance, image_href, admin_password,
                files_to_inject=None, **kwargs):
                """Rebuild the given instance with the provided attributes."""
            
        # 参数获取
        files_to_inject = files_to_inject or []
        metadata = kwargs.get('metadata', {})
        preserve_ephemeral = kwargs.get('preserve_ephemeral', False)
        auto_disk_config = kwargs.get('auto_disk_config')

        if 'key_name' in kwargs:
            key_name = kwargs.pop('key_name')
            if key_name:
                # NOTE(liuyulong): we are intentionally using the user_id from
                # the request context rather than the instance.user_id because
                # users own keys but instances are owned by projects, and
                # another user in the same project can rebuild an instance
                # even if they didn't create it.
                key_pair = objects.KeyPair.get_by_name(context,
                                                       context.user_id,
                                                       key_name)
                instance.key_name = key_pair.name
                instance.key_data = key_pair.public_key
                instance.keypairs = objects.KeyPairList(objects=[key_pair])
            else:
                instance.key_name = None
                instance.key_data = None
                instance.keypairs = objects.KeyPairList(objects=[])

        # Use trusted_certs value from kwargs to create TrustedCerts object
        trusted_certs = None
        if 'trusted_certs' in kwargs:
            # Note that the user can set, change, or unset / reset trusted
            # certs. If they are explicitly specifying
            # trusted_image_certificates=None, that means we'll either unset
            # them on the instance *or* reset to use the defaults (if defaults
            # are configured).
            trusted_certs = kwargs.pop('trusted_certs')
            instance.trusted_certs = self._retrieve_trusted_certs_object(
                context, trusted_certs, rebuild=True)
		# 调用 glance 获取 image 详情
        image_id, image = self._get_image(context, image_href)
        self._check_auto_disk_config(image=image,
                                     auto_disk_config=auto_disk_config)
        self._check_image_arch(image=image)
		
        # 从 数据库中 获取 instance 的 flavor 信息
        flavor = instance.get_flavor()
        
        # 从数据库中获取 bdm 信息（Block Device Mapping 块设备映射关系）
        bdms = objects.BlockDeviceMappingList.get_by_instance_uuid(
            context, instance.uuid)
        
        # 获取 boot_index=0 的 bdm，也就是 系统盘
        root_bdm = compute_utils.get_root_bdm(context, instance, bdms)

        # 判断 root_bdm 是否是  volume 类型
        is_volume_backed = compute_utils.is_volume_backed_instance(
            context, instance, bdms)
        if is_volume_backed:
            .....
            
            # 根据 bdm 的 volume_id 获取 volume 信息
            volume = self.volume_api.get(context, root_bdm.volume_id)
            # 从 volume 的metadata 中获取 image_id
            volume_image_metadata = volume.get('volume_image_metadata', {})
            orig_image_ref = volume_image_metadata.get('image_id')

            # 如果 volume 的 image_id 与 api 传入的 imageRef 不同，报错
            if orig_image_ref != image_href:
                # Leave a breadcrumb.
                LOG.debug('Requested to rebuild instance with a new image %s '
                          'for a volume-backed server with image %s in its '
                          'root volume which is not supported.', image_href,
                          orig_image_ref, instance=instance)
                msg = _('Unable to rebuild with a different image for a '
                        'volume-backed server.')
                raise exception.ImageUnacceptable(
                    image_id=image_href, reason=msg)
        .....
        
        instance.task_state = task_states.REBUILDING
        # An empty instance.image_ref is currently used as an indication
        # of BFV.  Preserve that over a rebuild to not break users.
        if not is_volume_backed:
            instance.image_ref = image_href
        instance.kernel_id = kernel_id or ""
        instance.ramdisk_id = ramdisk_id or ""
        instance.progress = 0
        instance.update(kwargs)
        instance.save(expected_task_state=[None])

        # 删除 instance system_metadata 中的 image 相关信息
        orig_sys_metadata = _reset_image_metadata()
        
    	# NOTE(sbauza): The migration script we provided in Newton should make
        # sure that all our instances are currently migrated to have an
        # attached RequestSpec object but let's consider that the operator only
        # half migrated all their instances in the meantime.
        host = instance.host
        # 如果在重建时提供了新图像，需要再次运行调度程序，但希望实例在它已经在的同一主机上重建。
        if orig_image_ref != image_href:
            request_spec.image = objects.ImageMeta.from_dict(image)
            request_spec.save()
            if 'scheduler_hints' not in request_spec:
                request_spec.scheduler_hints = {}
            del request_spec.id

			# 调度过滤条件
            request_spec.scheduler_hints['_nova_check_type'] = ['rebuild']
            request_spec.force_hosts = [instance.host]
            request_spec.force_nodes = [instance.node]
            host = None
        # 调用 nova-conductor 接口
        self.compute_task_api.rebuild_instance(context, instance=instance,
                new_pass=admin_password, injected_files=files_to_inject,
                image_ref=image_href, orig_image_ref=orig_image_ref,
                orig_sys_metadata=orig_sys_metadata, bdms=bdms,
                preserve_ephemeral=preserve_ephemeral, host=host,
                request_spec=request_spec)
```



## nova-conductor 组装逻辑



nova-conductor 的重建逻辑位于 `nova.conductor.manager.ComputeTaskManager.rebuild_instance`

```python
@profiler.trace_cls("rpc")
class ComputeTaskManager(base.Base):
    @targets_cell
    def rebuild_instance(self, context, instance, orig_image_ref, image_ref,
                         injected_files, new_pass, orig_sys_metadata,
                         bdms, recreate, on_shared_storage,
                         preserve_ephemeral=False, host=None,
                         request_spec=None):
        evacuate = recreate


        with compute_utils.EventReporter(context, 'rebuild_server',
                                         self.host, instance.uuid):
            node = limits = None

            try:
                migration = objects.Migration.get_by_instance_and_status(
                    context, instance.uuid, 'accepted')
            except exception.MigrationNotFoundByStatus:
                LOG.debug("No migration record for the rebuild/evacuate "
                          "request.", instance=instance)
                migration = None

            # 根据是 rebuild 还是 evacuate 决定是否执行 调度程序
            if host:
				......
			
            # 发送 notification 消息
            compute_utils.notify_about_instance_usage(
                self.notifier, context, instance, "rebuild.scheduled")
            compute_utils.notify_about_instance_rebuild(
                context, instance, host,
                action=fields.NotificationAction.REBUILD_SCHEDULED,
                source=fields.NotificationSource.CONDUCTOR)

            instance.availability_zone = (
                availability_zones.get_host_availability_zone(
                    context, host))
            try:
                accel_uuids = self._rebuild_cyborg_arq(
                    context, instance, host, request_spec, evacuate)
            except exception.AcceleratorRequestBindingFailed as exc:
                cyclient = cyborg.get_client(context)
                cyclient.delete_arqs_by_uuid(exc.arqs)
                LOG.exception('Failed to rebuild. Reason: %s', exc)
                raise exc

            # 调用 nova-compute 执行 rebuild
            self.compute_rpcapi.rebuild_instance(
                context,
                instance=instance,
                new_pass=new_pass,
                injected_files=injected_files,
                image_ref=image_ref,
                orig_image_ref=orig_image_ref,
                orig_sys_metadata=orig_sys_metadata,
                bdms=bdms,
                recreate=evacuate,
                on_shared_storage=on_shared_storage,
                preserve_ephemeral=preserve_ephemeral,
                migration=migration,
                host=host,
                node=node,
                limits=limits,
                request_spec=request_spec,
                accel_uuids=accel_uuids)
```





## nova-compute 最终执行

nova-compute 执行逻辑位于：`nova.compute.manager.ComputeManager.rebuild_instance`，步骤有：

- 获取 image_meta
- 如果没有调度主机节点，则使用 instance 的 host，保持 vm 的宿主机不变
- 调用 `_do_rebuild_instance_with_claim`，执行 rebuild 逻辑

```python
class ComputeManager(manager.Manager):
        @messaging.expected_exceptions(exception.PreserveEphemeralNotSupported,
                                   exception.BuildAbortException)
    @wrap_exception()
    @reverts_task_state
    @wrap_instance_event(prefix='compute')
    @wrap_instance_fault
    def rebuild_instance(self, context, instance, orig_image_ref, image_ref,
                         injected_files, new_pass, orig_sys_metadata,
                         bdms, recreate, on_shared_storage,
                         preserve_ephemeral, migration,
                         scheduled_node, limits, request_spec,
                         accel_uuids=None):

        evacuate = recreate
        context = context.elevated()

        if evacuate:
            LOG.info("Evacuating instance", instance=instance)
        else:
            LOG.info("Rebuilding instance", instance=instance)

        # rebuild 为 false，不需要 resource tracker
        if evacuate:
            rebuild_claim = self.rt.rebuild_claim
        else:
            rebuild_claim = claims.NopClaim

        # 获取 image_metadata
        if image_ref:
            image_meta = objects.ImageMeta.from_image_ref(
                context, self.image_api, image_ref)
        elif evacuate:
            image_meta = instance.image_meta
        else:
            image_meta = objects.ImageMeta()

        # 如果没有调度主机节点，则使用 instance 的 host，保持 vm 的宿主机不变
        if not scheduled_node:
            if evacuate:
                try:
                    compute_node = self._get_compute_info(context, self.host)
                    scheduled_node = compute_node.hypervisor_hostname
                except exception.ComputeHostNotFound:
                    LOG.exception('Failed to get compute_info for %s',
                                  self.host)
            else:
                scheduled_node = instance.node

        allocs = self.reportclient.get_allocations_for_consumer(
                    context, instance.uuid)

        # If the resource claim or group policy validation fails before we
        # do anything to the guest or its networking/volumes we want to keep
        # the current status rather than put the instance into ERROR status.
        instance_state = instance.vm_state
        with self._error_out_instance_on_exception(
                context, instance, instance_state=instance_state):
            try:
                # 执行 rebuild 逻辑
                self._do_rebuild_instance_with_claim(
                    context, instance, orig_image_ref,
                    image_meta, injected_files, new_pass, orig_sys_metadata,
                    bdms, evacuate, on_shared_storage, preserve_ephemeral,
                    migration, request_spec, allocs, rebuild_claim,
                    scheduled_node, limits, accel_uuids)
            except (exception.ComputeResourcesUnavailable,
                    exception.RescheduledException) as e:
				......

```



 `_do_rebuild_instance_with_claim` 方法中又调用了 `_do_rebuild_instance` ：

```python
    def _do_rebuild_instance(
            self, context, instance, orig_image_ref, image_meta,
            injected_files, new_pass, orig_sys_metadata, bdms, evacuate,
            on_shared_storage, preserve_ephemeral, migration, request_spec,
            allocations, request_group_resource_providers_mapping,
            accel_uuids):
        orig_vm_state = instance.vm_state

        # rebuild 不走此处逻辑
        if evacuate:
            if request_spec:
                hints = self._get_scheduler_hints({}, request_spec)
                self._validate_instance_group_policy(context, instance, hints)

            if not self.driver.capabilities.get("supports_evacuate", False):
                raise exception.InstanceEvacuateNotSupported

			.....

        # 检查证书
        self._check_trusted_certs(instance)

        # 获取 instance 原来的 image url，
        orig_image_ref_url = self.image_api.generate_image_url(orig_image_ref,
                                                               context)
        # 发送 notification 消息
        extra_usage_info = {'image_ref_url': orig_image_ref_url}
        compute_utils.notify_usage_exists(
                self.notifier, context, instance, self.host,
                current_period=True, system_metadata=orig_sys_metadata,
                extra_usage_info=extra_usage_info)

        # This message should contain the new image_ref
        extra_usage_info = {'image_name': self._get_image_name(image_meta)}
        self._notify_about_instance_usage(context, instance,
                "rebuild.start", extra_usage_info=extra_usage_info)

        compute_utils.notify_about_instance_rebuild(
            context, instance, self.host,
            phase=fields.NotificationPhase.START,
            bdms=bdms)

        # 修改 instance 状态为 rebuilding
        instance.power_state = self._get_power_state(instance)
        instance.task_state = task_states.REBUILDING
        instance.save(expected_task_state=[task_states.REBUILDING])

        # 获取 instance 当前的 网络信息
        if evacuate:
            self.network_api.setup_networks_on_host(
                    context, instance, self.host)
            self.network_api.setup_instance_network_on_host(
                context, instance, self.host, migration,
                provider_mappings=request_group_resource_providers_mapping)
            network_info = self.network_api.get_instance_nw_info(context,
                                                                 instance)
        else:
            network_info = instance.get_network_info()

        if bdms is None:
            bdms = objects.BlockDeviceMappingList.get_by_instance_uuid(
                    context, instance.uuid)

        # 从 bdm 中获取 bloak device info
        # 有三个字段，分别是 root_device_name(挂载点)，ephemerals(临时盘)、block_device_mapping(bdm 根据 不同的类型，例如 volume 类型 转为 DriverVolumeBlockDevice 类型)
        block_device_info = \
            self._get_instance_block_device_info(
                    context, instance, bdms=bdms)

        # 卸载所有的 bdm 设备
        def detach_block_devices(context, bdms):
            for bdm in bdms:
                if bdm.is_volume:
                    # 1. 下面操作会先在 cinder 出申请一个 attachment，也就是 instance、volume、attachment 一个映射关系
                    # 2. 在 detach 前先创建 attachment 的原因是：如果不预先创建一个 attachment，那么在 detach ，并删除了旧 attachment 后，volume 编程 available 状态，允许被其他 vm 绑定，会有问题
            		
                    attachment_id = None
                    if bdm.attachment_id:
                        attachment_id = self.volume_api.attachment_create(
                            context, bdm['volume_id'], instance.uuid)['id']
                    # 重要，这里卸载了 系统盘
                    self._detach_volume(context, bdm, instance,
                                        destroy_bdm=False)
                    if attachment_id:
                        bdm.attachment_id = attachment_id
                        bdm.save()
		
        files = self._decode_files(injected_files)

        kwargs = dict(
            context=context,
            instance=instance,
            image_meta=image_meta,
            injected_files=files,
            admin_password=new_pass,
            allocations=allocations,
            bdms=bdms,
            detach_block_devices=detach_block_devices,			# 卸载操作
            attach_block_devices=self._prep_block_device,		# 挂载操作
            block_device_info=block_device_info,
            network_info=network_info,
            preserve_ephemeral=preserve_ephemeral,
            evacuate=evacuate,
            accel_uuids=accel_uuids)
        try:
            with instance.mutated_migration_context():
                # 执行 对应 driver 的 rebuild 操作，此处使用 libvirt 没有实现 rebuild
                self.driver.rebuild(**kwargs)
        except NotImplementedError:
            # libvirt 没有rebuild，因此调用下面的方法
            self._rebuild_default_impl(**kwargs)
		
        # 修改 instance 状态
        self._update_instance_after_spawn(instance)
        instance.save(expected_task_state=[task_states.REBUILD_SPAWNING])

        if orig_vm_state == vm_states.STOPPED:
            LOG.info("bringing vm to original state: '%s'",
                     orig_vm_state, instance=instance)
            instance.vm_state = vm_states.ACTIVE
            instance.task_state = task_states.POWERING_OFF
            instance.progress = 0
            instance.save()
            self.stop_instance(context, instance, False)
        self._update_scheduler_instance_info(context, instance)
        # 发送 notification
        self._notify_about_instance_usage(
                context, instance, "rebuild.end",
                network_info=network_info,
                extra_usage_info=extra_usage_info)
        compute_utils.notify_about_instance_rebuild(
            context, instance, self.host,
            phase=fields.NotificationPhase.END,
            bdms=bdms)

```



上面最重要的方法就是 `_rebuild_default_impl`，这个方法逻辑如下：

```python
    def _rebuild_default_impl(
            self, context, instance, image_meta, injected_files,
            admin_password, allocations, bdms, detach_block_devices,
            attach_block_devices, network_info=None, evacuate=False,
            block_device_info=None, preserve_ephemeral=False,
            accel_uuids=None):
        if preserve_ephemeral:
            raise exception.PreserveEphemeralNotSupported()

        accel_info = []
        if evacuate:
            if instance.flavor.extra_specs.get('accel:device_profile'):
                try:
                    accel_info = self._get_bound_arq_resources(
                        context, instance, accel_uuids or [])
                except (Exception, eventlet.timeout.Timeout) as exc:
                    LOG.exception(exc)
                    self._build_resources_cleanup(instance, network_info)
                    msg = _('Failure getting accelerator resources.')
                    raise exception.BuildAbortException(
                        instance_uuid=instance.uuid, reason=msg)
            detach_block_devices(context, bdms)
        else:		# rebuild 逻辑分支
            # 关机
            self._power_off_instance(instance, clean_shutdown=True)
            # 重要：调用上面，detach_block_devices 方法，卸载 系统盘
            detach_block_devices(context, bdms)
            # 调用 libvirt 接口，destroy instance
            self.driver.destroy(context, instance,
                                network_info=network_info,
                                block_device_info=block_device_info)
            try:
                accel_info = self._get_accel_info(context, instance)
            except Exception as exc:
                LOG.exception(exc)
                self._build_resources_cleanup(instance, network_info)
                msg = _('Failure getting accelerator resources.')
                raise exception.BuildAbortException(
                    instance_uuid=instance.uuid, reason=msg)

        # 修改 instance 状态为 rebuild_block_device_mapping
        instance.task_state = task_states.REBUILD_BLOCK_DEVICE_MAPPING
        instance.save(expected_task_state=[task_states.REBUILDING])

        # 重要：调用 _prep_block_device 方法，绑定 attach 系统盘
        new_block_device_info = attach_block_devices(context, instance, bdms)

        # 修改 instance 状态为 REBUILD_SPAWNING
        instance.task_state = task_states.REBUILD_SPAWNING
        instance.save(
            expected_task_state=[task_states.REBUILD_BLOCK_DEVICE_MAPPING])

        # 上面 destroy instance，下面重新创建 xml ，调用 libvirt 接口重新创建 vm
        with instance.mutated_migration_context():
            self.driver.spawn(context, instance, image_meta, injected_files,
                              admin_password, allocations,
                              network_info=network_info,
                              block_device_info=new_block_device_info,
                              accel_info=accel_info)

```



注意到上面比较重要的两个点：

- 卸载盘
- 挂载盘



首先来看卸载系统盘，在 `_do_rebuild_instancec` 方法中定义了 `detach_block_devices` 用来卸载所有的 bdm 设备。其中的步骤为：

- 遍历所有的 bdm
- 如果盘的类型是 volume：
    - 先为此 instance 的 volume 在 cinder 中创建一个 attachment
    - 调用 `self._detach_volume` 卸载盘
    - 保存新的 attachment_id 到 bdm 表中

`self._detach_volume` 卸载的逻辑为：

```python
    def _detach_volume(self, context, bdm, instance, destroy_bdm=True,
                       attachment_id=None):
        # 获取 volume_id
        volume_id = bdm.volume_id
        
        # 发送 notification
        compute_utils.notify_about_volume_attach_detach(
            context, instance, self.host,
            action=fields.NotificationAction.VOLUME_DETACH,
            phase=fields.NotificationPhase.START,
            volume_id=volume_id)

        self._notify_volume_usage_detach(context, instance, bdm)

        LOG.info('Detaching volume %(volume_id)s',
                 {'volume_id': volume_id}, instance=instance)

        # 根据 bdm 不同类型，转换成对应的对象，例如此处为 volume，转换为 DriverVolumeBlockDevice
        driver_bdm = driver_block_device.convert_volume(bdm)
        # 调用 DriverVolumeBlockDevice.detach 方法
        driver_bdm.detach(context, instance, self.volume_api, self.driver,
                          attachment_id=attachment_id, destroy_bdm=destroy_bdm)

        info = dict(volume_id=volume_id)
        self._notify_about_instance_usage(
            context, instance, "volume.detach", extra_usage_info=info)
        compute_utils.notify_about_volume_attach_detach(
            context, instance, self.host,
            action=fields.NotificationAction.VOLUME_DETACH,
            phase=fields.NotificationPhase.END,
            volume_id=volume_id)

        if 'tag' in bdm and bdm.tag:
            self._delete_disk_metadata(instance, bdm)
        if destroy_bdm:
            bdm.destroy()

```

`DriverVolumeBlockDevice.detach` 最终调用了 libvirt 的 `detach_volume` 方法通过 libvirt 接口直接卸载(`nova.virt.libvirt.driver.LibvirtDriver.detach_volume`)

`detach_volume` 调链为：

- `nova.virt.libvirt.guest.Guest.detach_device_with_retry`
- `nova.virt.libvirt.guest.Guest.detach_device` ，下面是关键的代码：

```python
        # 获取 libvirt xml 中的 disk device 部分
    	device_xml = conf.to_xml()
        if isinstance(device_xml, bytes):
            device_xml = device_xml.decode('utf-8')

        LOG.debug("detach device xml: %s", device_xml)
        # 删除了当前 instance 对应的 libvirt xml 中的 disk device 部分，也就是卸载了盘
        self._domain.detachDeviceFlags(device_xml, flags=flags)
```





其次，来查看挂载的流程。挂载最终调用的是 `nova.compute.manager.ComputeManager._prep_block_device`

```python
    def _prep_block_device(self, context, instance, bdms):
        """Set up the block device for an instance with error logging."""
        try:
            self._add_missing_dev_names(bdms, instance)
            # 将 bdms 中所有 bdm 根据不同类型转成不同对象，例如 volume 类型，转成 DriverVolumeBlockDevice
            block_device_info = driver.get_block_device_info(instance, bdms)
            mapping = driver.block_device_info_get_mapping(block_device_info)
            # 挂载 bdm
            driver_block_device.attach_block_devices(
                mapping, context, instance, self.volume_api, self.driver,
                wait_func=self._await_block_device_map_created)

            self._block_device_info_to_legacy(block_device_info)
            return block_device_info

        except exception.OverQuota as e:
            LOG.warning('Failed to create block device for instance due'
                        ' to exceeding volume related resource quota.'
                        ' Error: %s', e.message, instance=instance)
            raise

        except Exception as ex:
            LOG.exception('Instance failed block device setup',
                          instance=instance)
            # InvalidBDM will eventually result in a BuildAbortException when
            # booting from volume, and will be recorded as an instance fault.
            # Maintain the original exception message which most likely has
            # useful details which the standard InvalidBDM error message lacks.
            raise exception.InvalidBDM(six.text_type(ex))


```



`driver_block_device.attach_block_devices` 调用链为：

- `nova.virt.block_device.attach_block_devices`

- `nova.virt.block_device.DriverVolumeBlockDevice.attach`

- `nova.virt.block_device.DriverVolumeBlockDevice._do_attach`

- `nova.virt.block_device.DriverVolumeBlockDevice._volume_attach` 逻辑如下：

    ```python
        def _volume_attach(self, context, volume, connector, instance,
                           volume_api, virt_driver, attachment_id,
                           do_driver_attach=False):
    
            # 获取 volume_id
            volume_id = volume['id']
            if self.volume_size is None:
                self.volume_size = volume.get('size')
    
            vol_multiattach = volume.get('multiattach', False)
            virt_multiattach = virt_driver.capabilities.get(
                'supports_multiattach', False)
    
            if vol_multiattach and not virt_multiattach:
                raise exception.MultiattachNotSupportedByVirtDriver(
                          volume_id=volume_id)
    
            LOG.debug("Updating existing volume attachment record: %s",
                      attachment_id, instance=instance)
            
            # 调用 cinder 接口，更新 attachment 中的 mount_device 也就是挂载点
            connection_info = volume_api.attachment_update(
                context, attachment_id, connector,
                self['mount_device'])['connection_info']
            
            # 在 libvirt xml 的 disk device 块中，serial 为 volume_id
            if 'serial' not in connection_info:
                connection_info['serial'] = self.volume_id
            self._preserve_multipath_id(connection_info)
            if vol_multiattach:
                connection_info['multiattach'] = True
    
            if do_driver_attach:
                encryption = encryptors.get_encryption_metadata(
                    context, volume_api, volume_id, connection_info)
    
                try:
                    # 调用 libvirt 接口 attach 盘，就是在 xml 中重新生成 disk device block
                    virt_driver.attach_volume(
                            context, connection_info, instance,
                            self['mount_device'], disk_bus=self['disk_bus'],
                            device_type=self['device_type'], encryption=encryption)
                except Exception:
                    with excutils.save_and_reraise_exception():
                        LOG.exception("Driver failed to attach volume "
                                          "%(volume_id)s at %(mountpoint)s",
                                      {'volume_id': volume_id,
                                       'mountpoint': self['mount_device']},
                                      instance=instance)
                        volume_api.attachment_delete(context,
                                                     attachment_id)
    
            self['connection_info'] = connection_info
            self.save()
    
            try:
                # 调用 cinder 的 attachment complete 接口，将 attachment 状态修改为 in-use
                volume_api.attachment_complete(context, attachment_id)
            except Exception:
                with excutils.save_and_reraise_exception():
                    if do_driver_attach:
                        # Disconnect the volume from the host.
                        try:
                            virt_driver.detach_volume(context,
                                                      connection_info,
                                                      instance,
                                                      self['mount_device'],
                                                      encryption=encryption)
                        except Exception:
                            LOG.warning("Driver failed to detach volume "
                                        "%(volume_id)s at %(mount_point)s.",
                                        {'volume_id': volume_id,
                                         'mount_point': self['mount_device']},
                                        exc_info=True, instance=instance)
                    # Delete the attachment to mark the volume as "available".
                    volume_api.attachment_delete(context, self['attachment_id'])
    
    ```

    