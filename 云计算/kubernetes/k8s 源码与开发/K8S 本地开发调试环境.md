[TOC]

# K8S 本地开发调试环境

## telepresence 工具

 
 

### 1. 安装

 
window 和 linux 略有不同，建议使用 linux 环境安装
 
安装完成后，可以通过下面命名查看是否安装成功：

```shell
[root@localhost telepresence]# telepresence version
Enhanced Client: v2.9.3
Root Daemon : v2.9.3
User Daemon : v2.9.3
Traffic Manager: v2.9.3
 
```

### 2. 配置

 
telepresence 工具的配置目录在  **~/.config/telepresence/config.yml**
 
主要配置 agent-injector 的镜像名称，可以配置私有仓库地址（目前没有测试，我直接导入的镜像）

```shell
[root@localhost telepresence]# cat ~/.config/telepresence/config.yml 
timeouts:
 agentInstall: 1m
 intercept: 10s
images:
 agentImage: ambassador-telepresence-agent:1.13.4
 registry: xxxxx
```

- agentImage: 指定注入 sidecar 的 image 名称

- registry：私有仓库地址，注意：上面的仓库地址需要修改
   
   
   

### 3. 导入镜像

 
目前我把用到的镜像手动导入到内网使用，后续我会把镜像上传到 Jforg 的 docker 镜像仓库上，大家可以直接通过配置上面的 registry 拉取镜像。

否则，会默认从 docker.io/datawire 拉取镜像 
 
 

### 4. 配置 telepresence 连接 k8s 的环境

 
telepresence 需要连接到 k8s 集群环境，因此需要 k8s 的 kubeconfig 文件。Kubernetes 中的 kubernetes-admin 用户的默认的 kubeconfig 文件路径为 **~/.kube/config** 。
 
telepresence 有两种方式使用 kubeconfig 文件：

- 命令行中指定 kubeconfig 文件路径，每次输入 telepresence 命令添加 --kubeconfig Path/to/kubeconfig

- 将 kubeconfig 文件同样放置在 ~/.kube/config 路径下
   
  这里我采用第二种方式：

```shell
# 创建 ~/.kube/ 目录
$ mkdir -p ~/.kube

# 拷贝 k8s kubeconfig 文件，示例中是我的开发 k8s 集群环境
$ scp root@10.20.80.231:~/.kube/config ~/.kube/config
```

 

### 5. 安装 telepresence agent 到 k8s 集群

 
通过 helm install 的命令来安装 telepresence agent 到 k8s 集群

```shell
# 这里会使用我们之前配置文件中的 registry 来拉取镜像，获取手动提前拉取
$ telepresence helm install
```

 
安装完成后，在 k8s 环境中查看状态：

```shell
# telepresence 安装在 ambassador 命名空间下
$ kubectl -n ambassador get all
NAME READY STATUS RESTARTS AGE
pod/traffic-manager-6b6b46b58c-gvhhw 1/1 Running 0 2d17h

NAME TYPE CLUSTER-IP EXTERNAL-IP PORT(S) AGE
service/agent-injector ClusterIP 10.233.5.142 <none> 443/TCP 2d17h
service/traffic-manager ClusterIP None <none> 8081/TCP,15766/TCP 2d17h

NAME READY UP-TO-DATE AVAILABLE AGE
deployment.apps/traffic-manager 1/1 1 1 2d17h

NAME DESIRED CURRENT READY AGE
replicaset.apps/traffic-manager-6b6b46b58c 1 1 1 2d17h
```

### 6. 连接到 k8s 环境

 
查看 telepresense 状态：

```shell
[root@localhost telepresence]# telepresence status
User Daemon: Running
 Version : v2.9.3 (api 3)
 Executable : /usr/local/bin/telepresence
 Install ID : 99c12ea9-2e65-4b1b-87a4-64251ff41387
 Status : Not connected
 Kubernetes server : 
Kubernetes context: 
Intercepts : 0 total
Root Daemon: Running
 Version: v2.9.3 (api 3)
Ambassador Cloud:
 Status : Logged out
```

 
可以发现目前状态是 Not connected，下面命令用于连接到 k8s 集群环境

```shell
# 连接到 k8s 环境
[root@localhost telepresence]# telepresence connect
Connected to context kubernetes-admin@cluster.local (https://172.20.0.34:6443)

# 再次查看状态，目前已经连接成功
[root@localhost telepresence]# telepresence status
User Daemon: Running
  Version           : v2.9.3 (api 3)
  Executable        : /usr/local/bin/telepresence
  Install ID        : 99c12ea9-2e65-4b1b-87a4-64251ff41387
  Status            : Connected
  Kubernetes server : https://172.20.0.34:6443
  Kubernetes context: kubernetes-admin@cluster.local
  Intercepts        : 0 total
Root Daemon: Running
  Version: v2.9.3 (api 3)
  DNS    :
    Local IP        : 10.10.10.10
    Remote IP       : <nil>
    Exclude suffixes: [.com .io .net .org .ru]
    Include suffixes: []
    Timeout         : 8s
  Also Proxy : (0 subnets)
  Never Proxy: (1 subnets)
    - 172.20.0.34/32
Ambassador Cloud:
  Status      : Logged out
```

这里已经连接到了 k8s 环境，可以测试：

```shell
# 这里在本地 curl 一个 k8s 环境中的 svc
[root@localhost telepresence]# curl ks-apiserver.kubesphere-system -v
* Rebuilt URL to: ks-apiserver.kubesphere-system/
*   Trying 10.233.37.69...
* TCP_NODELAY set
* Connected to ks-apiserver.kubesphere-system (10.233.37.69) port 80 (#0)
> GET / HTTP/1.1
> Host: ks-apiserver.kubesphere-system
> User-Agent: curl/7.61.1
> Accept: */*
> 
< HTTP/1.1 403 Forbidden
< content-type: application/json
< x-content-type-options: nosniff
< date: Mon, 05 Dec 2022 02:38:46 GMT
< content-length: 233
< x-envoy-upstream-service-time: 1
< server: envoy
< 
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {

  },
  "status": "Failure",
  "message": "forbidden: User \"system:anonymous\" cannot GET path \"/\"",
  "reason": "Forbidden",
  "details": {

  },
  "code": 403
* Connection #0 to host ks-apiserver.kubesphere-system left intact
```

 
可以发现，这里已经可以解析 svc 的域名，并且能够识别到 svc 的 ClusterIP 地址，在 k8s 集群中查看，正是 ks-apiserver 这个服务的 IP：

```shell
└─[$]> kubectl -n kubesphere-system get svc  
NAME TYPE CLUSTER-IP EXTERNAL-IP PORT(S) AGE
ks-apiserver ClusterIP 10.233.37.69 <none> 80/TCP 3d19h
ks-console NodePort 10.233.31.220 <none> 80:30880/TCP 3d19h
ks-controller-manager ClusterIP 10.233.63.129 <none> 443/TCP 3d19h
minio ClusterIP 10.233.20.28 <none> 9000/TCP 3d20h
openldap ClusterIP None <none> 389/TCP 3d20h
redis ClusterIP 10.233.56.181 <none> 6379/TCP 3d20h
```

 
 
断开连接只需要：

```shell
$ telepresence quit
```

 

### 7. telepresence 常用命令

 

1. telepresence version - 查看版本

2. telepresence connect - 连接到 Kubernetes 集群

3. telepresence quit - 断开连接

4. telepresence status - 查看连接状态，也可以查看已拦截的列表

5. telepresence helm install - 在 Kubernetes 集群中安装 teleprecence agent

6. telepresence helm uninstall - 卸载 agent

7. telepresence list - 查看当前可以拦截的服务，通过 -n 指定命名空间

8. telepresence leave [Intercept-Name] - 取消某个拦截
    
    
    

### 本地开发调试环境

下面以本地调试开发 kubesphere golang 后端为例：

首先在 Kubernetes 集群中找到想要调试的 Pod，这里我调试的是 ks-apiserver 组件，注意，telepresence 拦截的必须是deployment 的服务，因此需要给 deployment 添加 svc

```shell
└─[$]> kubectl -n kubesphere-system get all | grep ks-apiserver
pod/ks-apiserver-5ffc785fc6-d6tvq 1/1 Running 2 (106s ago) 2d17h  
service/ks-apiserver ClusterIP 10.233.37.69 <none> 80/TCP 3d20h  
deployment.apps/ks-apiserver 1/1 1 1 3d20h  
replicaset.apps/ks-apiserver-5ffc785fc6 1 1 1 2d17                                       
```

然后再本机进行流量的拦截：

```shell
# 查看当前 namespace 下有哪些可以拦截的服务
[root@localhost telepresence]# telepresence list -n kubesphere-system
ks-apiserver         : ready to intercept (traffic-agent not yet installed)
ks-console           : ready to intercept (traffic-agent not yet installed)
ks-controller-manager: ready to intercept (traffic-agent not yet installed)
minio                : ready to intercept (traffic-agent not yet installed)
openldap             : ready to intercept (traffic-agent not yet installed)
redis                : ready to intercept (traffic-agent not yet installed)


# 拦截 ks-apiesrver 服务的 80 端口 到 本地 的 9090 端口
[root@localhost telepresence]# telepresence intercept ks-apiserver --port 9090:80 --preview-url=false --namespace kubesphere-system    
Using Deployment ks-apiserver
intercepted
   Intercept name         : ks-apiserver-kubesphere-system
   State                  : ACTIVE
   Workload kind          : Deployment
   Destination            : 127.0.0.1:9090
   Service Port Identifier: 80
   Volume Mount Point     : /tmp/telfs-3886978017
   Intercepting           : all TCP requests

# 再次查看 list 列表
[root@localhost telepresence]# telepresence list -n kubesphere-system
ks-apiserver         : intercepted
   Intercept name         : ks-apiserver-kubesphere-system
   State                  : ACTIVE
   Workload kind          : Deployment
   Destination            : 127.0.0.1:9090
   Service Port Identifier: 80
   Volume Mount Point     : /tmp/telfs-2158868818
   Intercepting           : all TCP requests
ks-console           : ready to intercept (traffic-agent not yet installed)
ks-controller-manager: ready to intercept (traffic-agent not yet installed)
minio                : ready to intercept (traffic-agent not yet installed)
openldap             : ready to intercept (traffic-agent not yet installed)
redis                : ready to intercept (traffic-agent not yet installed)
```

拦截失败原因是 sshfs 时，可以在本地机器上安装 sshfs。

```shell
yum install sshfs
```

到目前，拦截已经完成，查看 kubernetes 中对应 组件的 pod 信息：

```shell
└─[$]> kubectl -n kubesphere-system get pods                   
NAME                                    READY   STATUS    RESTARTS        AGE
ks-apiserver-5ffc785fc6-d6tvq           2/2     Running   2 (10m ago)     2d17h
```

对应 Pod 中已经有两个 container 了，telepresence 在对应的 pod 中注入了一个 sidecar ，用来拦截流量。
 
 
最后，只需要在本地启动 ks-apiserver 组件到端口 9090，就可以把 k8s 环境的流量代理到本地，进行开发调试了。
