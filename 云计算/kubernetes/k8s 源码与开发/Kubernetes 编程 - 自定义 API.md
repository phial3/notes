[TOC]

# Kubernetes 编程 - 自定义 API

## CRD 与 聚合API

自定义资源实际上是为了扩展 kubernetes 的 API，向 kubenetes API 中增加新类型，可以使用以下三种方式：

- 修改 kubenetes 的源码，显然难度比较高，也不太合适
- 创建自定义 API server 并聚合到 API 中
- 创建自定义资源(CRD)

之前说到了 CRD 自定义资源，但是也有一定的局限性(**CRD 的局限性**)：

1. 只支持 etcd
2. 只支持JSON，不支持 protobuf （一种高性能的序列化语言）
3. 只支持2种子资源接口 （ /status 和 /scale）
4. 不支持优雅删除
5. 显著增加 api server 负担
6. 只支持 CRUD 原语
7. 不支持跨 API groups 共享存储，即不同 API 组的资源或者不同名字的资源在底层共享存储

**自定义API server相比CRD的优势：**

1. 底层存储无关（像metrics server 存在内存里面）
2. 支持 protobuf
3. 支持任意自定义子资源
4. 可以实现优雅删除
5. 支持复杂验证
6. 支持自定义语义

## 聚合 APi 架构

### 原理

Aggregated（聚合的）API server 是为了将原来的 API server 这个巨石（monolithic）应用给拆分开，为了方便用户开发自己的 API server 集成进来，而不用直接修改 Kubernetes 官方仓库的代码，这样一来也能将 API server 解耦，方便用户使用实验特性。

简而言之，它是允许k8s的开发人员编写一个自己的服务，可以把这个服务注册到k8s的api里面，这样，就像k8s自己的api一样，自定义的服务只要运行在k8s集群里面，k8s 的Aggregate通过service名称就可以转发到我们自定义的service里面去了。这些 API server 可以跟 kube-apiserver 无缝衔接，使用 kubectl 也可以管理它们。

**完成 Kubernentes 原生 API 和自定义 API 的代理功能的组件在 Kube-apiserver 进程中，成为 kube-aggregator**。<u>代理 API 请求到自定义 API 服务器的过程成为 API 聚合</u>

kube-apiserver 的原理如下图：

![k8s-kube-apiserver](E:\notes\云计算\pic\k8s开发\k8s-kube-apiserver.jpg)

向自定义 API 服务器发起请求的过程大致为：

- Kubernetes 中的 **kube-apiserver 服务器收到请求**

- 请求**先经过处理链处理**，完成包括身份认证、审计日志、切换用户、限流、授权等处理流程

- kube-apiserver 知道系统中存在哪些聚合 API，所以可以对相关 `/apis/aggregated-API-group-name` 的 HTTP 路径下的**请求进行拦截**

- kube-apiserver 将拦截下来的请求转发给自定义的 API 服务器

kube-aggregator为所有聚合的自定义 kube-apiserver 服务器本身的发现端点 `/apis` 和 `/apis/group-name/` 提供服务。注意：**<u>处理有一个预定的顺序规则。使用 APIService 资源提供的信息来生成结果</u>**。

### APIService

APIService ：为了 Kube-apiserver 直到一个自定义的 API 服务器能为哪些 API 组提供服务，就必须在 `apiregistration.k8s.io/v1` 的 API 组下创建一个 APIService 对象。

APIService 这类对象只需列出 API 组和版本，不需要细节：

```yaml
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: v1beta1.custom.metrics.k8s.io
  labels:
    api: custom-metrics-apiserver
    apiserver: "true"
spec:
  version: v1beta1 #API版本
  group: custom.metrics.k8s.io #API所属的组
  groupPriorityMinimum: 2000
  service:
    name: custom-metrics-apiserver #自定义API所关联的service名称，当访问这个自定义API后转发到哪个service处理，就根据这个service名称选择
    namespace: default
  versionPriority: 10
  caBundle: "LS0tLS1CRUdJTiBDRVJUSUZJQ0"
```

有几个关键的字段：

- group：组名，也就是 HTTP 的路径 `/apis/group-name`

- version：版本名，对应 HTTP 路径 `/apis/group-name/version`

- service ：转发对应的自定义的 service 上。
  
  - 可以是 k8s 集群内普通的 ClusterIP 服务
  
  - 也可以是集群为的自定义服务，加上集群内具有 DNS 名称的 ExternalName 服务
  
  - 注意：这里必须是 HTTPS 的，也就是 443 端口

- groupPriorityMinimum：决定了自定义组的优先级，值越大优先级越高

- versionPriority：决定了自定义版本的优先级，值越大优先级越高

下面是原生的 Kubernetes API 的优先级列表：

```go
// The proper way to resolve this letting the aggregator know the desired group and version-within-group order of the underlying servers
// is to refactor the genericapiserver.DelegationTarget to include a list of priorities based on which APIs were installed.
// This requires the APIGroupInfo struct to evolve and include the concept of priorities and to avoid mistakes, the core storage map there needs to be updated.
// That ripples out every bit as far as you'd expect, so for 1.7 we'll include the list here instead of being built up during storage.
var apiVersionPriorities = map[schema.GroupVersion]priority{
    {Group: "", Version: "v1"}: {group: 18000, version: 1},
    // to my knowledge, nothing below here collides
    {Group: "apps", Version: "v1"}:                               {group: 17800, version: 15},
    {Group: "events.k8s.io", Version: "v1"}:                      {group: 17750, version: 15},
    {Group: "events.k8s.io", Version: "v1beta1"}:                 {group: 17750, version: 5},
    {Group: "authentication.k8s.io", Version: "v1"}:              {group: 17700, version: 15},
    {Group: "authentication.k8s.io", Version: "v1alpha1"}:        {group: 17700, version: 1},
    {Group: "authorization.k8s.io", Version: "v1"}:               {group: 17600, version: 15},
    {Group: "autoscaling", Version: "v1"}:                        {group: 17500, version: 15},
    {Group: "autoscaling", Version: "v2"}:                        {group: 17500, version: 30},
    {Group: "autoscaling", Version: "v2beta1"}:                   {group: 17500, version: 9},
    {Group: "autoscaling", Version: "v2beta2"}:                   {group: 17500, version: 1},
    {Group: "batch", Version: "v1"}:                              {group: 17400, version: 15},
    {Group: "batch", Version: "v1beta1"}:                         {group: 17400, version: 9},
    {Group: "batch", Version: "v2alpha1"}:                        {group: 17400, version: 9},
    {Group: "certificates.k8s.io", Version: "v1"}:                {group: 17300, version: 15},
    {Group: "networking.k8s.io", Version: "v1"}:                  {group: 17200, version: 15},
    {Group: "networking.k8s.io", Version: "v1alpha1"}:            {group: 17200, version: 1},
    {Group: "policy", Version: "v1"}:                             {group: 17100, version: 15},
    {Group: "policy", Version: "v1beta1"}:                        {group: 17100, version: 9},
    {Group: "rbac.authorization.k8s.io", Version: "v1"}:          {group: 17000, version: 15},
    {Group: "storage.k8s.io", Version: "v1"}:                     {group: 16800, version: 15},
    {Group: "storage.k8s.io", Version: "v1beta1"}:                {group: 16800, version: 9},
    {Group: "storage.k8s.io", Version: "v1alpha1"}:               {group: 16800, version: 1},
    {Group: "apiextensions.k8s.io", Version: "v1"}:               {group: 16700, version: 15},
    {Group: "admissionregistration.k8s.io", Version: "v1"}:       {group: 16700, version: 15},
    {Group: "admissionregistration.k8s.io", Version: "v1alpha1"}: {group: 16700, version: 9},
    {Group: "scheduling.k8s.io", Version: "v1"}:                  {group: 16600, version: 15},
    {Group: "coordination.k8s.io", Version: "v1"}:                {group: 16500, version: 15},
    {Group: "node.k8s.io", Version: "v1"}:                        {group: 16300, version: 15},
    {Group: "node.k8s.io", Version: "v1alpha1"}:                  {group: 16300, version: 1},
    {Group: "node.k8s.io", Version: "v1beta1"}:                   {group: 16300, version: 9},
    {Group: "discovery.k8s.io", Version: "v1"}:                   {group: 16200, version: 15},
    {Group: "discovery.k8s.io", Version: "v1beta1"}:              {group: 16200, version: 12},
    {Group: "flowcontrol.apiserver.k8s.io", Version: "v1beta3"}:  {group: 16100, version: 18},
    {Group: "flowcontrol.apiserver.k8s.io", Version: "v1beta2"}:  {group: 16100, version: 15},
    {Group: "flowcontrol.apiserver.k8s.io", Version: "v1beta1"}:  {group: 16100, version: 12},
    {Group: "flowcontrol.apiserver.k8s.io", Version: "v1alpha1"}: {group: 16100, version: 9},
    {Group: "internal.apiserver.k8s.io", Version: "v1alpha1"}:    {group: 16000, version: 9},
    {Group: "resource.k8s.io", Version: "v1alpha1"}:              {group: 15900, version: 9},
    // Append a new group to the end of the list if unsure.
    // You can use min(existing group)-100 as the initial value for a group.
    // Version can be set to 9 (to have space around) for a new group.
}
```

- 如果存在冲突的资源名称或短名称，拥有最大的 groupPriorityMinimum 值的资源会真正生效

- 也可以用作，用一个 Api 替换另一个 Api

- kube-apiserver 不需要直到具体的 Group/Version 下有什么资源，只需要将请求转发给自定义的服务器即可。

### 自定义 API 服务器的内部结构

一个自定义 API 服务器的构成大体上与 kube-apiserver 相同，当然自定义 API 服务器没有嵌入 kube-aggregator 和 apiextension-apiserver（为 CRD 提供服务）。构成如下：

![k8s-kube-aggregator](E:\notes\云计算\pic\k8s开发\k8s-kube-aggregator.jpg)

聚合自定义 API 服务器的特性：

- 拥有与 kube-apiserver 一致的内部基础结构

- 拥有自己的处理链，包括身份认证、审计、切换用户、限流和授权等

- 拥有自己的资源处理流水线，包括解码、转换、准入、REST 映射和编码

- 会调用准入 webhook （准入控制）

- 可能会写入 etcd（也可以选择使用不同的后端存储）。操作的 etcd 不要求与 kube-apiserver 使用的相同

- 拥有自己的 Scheme，并实现了自定义 API 组的注册表（Registry）。可以使用不同的方式实现，也可以随意进行定制

- 再次进行身份认证。通常以一个 TokenAccessReview 请求对 kube-apiserver 进行回调，实现基于客户端的证书认证和基于令牌的认证。

- 自己进行审计。

- 使用 SubjectAccessReview 请求 kube-apiserver 完成自己的身份认证逻辑。

#### 委托身份认证和信任机制

Kubernetes apiserver 使用 x509 证书向扩展 apiserver 认证。大致流程如下：

1. Kubernetes apiserver：对发出请求的用户身份认证，并对请求的 API 路径执行鉴权。
2. Kubernetes apiserver：将请求转发到扩展 apiserver
3. 扩展 apiserver：认证来自 Kubernetes apiserver 的请求
4. 扩展 apiserver：对来自原始用户的请求鉴权
5. 扩展 apiserver：执行

![k8s-aggregation-api-auth-flow](E:\notes\云计算\pic\k8s开发\k8s-aggregation-api-auth-flow.png)

<u>聚合自定义 API 服务（基于 `k8s.io/apiserver），和 kube-apiserver 服务器使用相同的身份认证库，它可以使用客户端证书或者令牌（Token）来对用户进行认证</u>。

因为聚合自定义 API 服务在 kube-apiserver 之后，因此在 kube-apiserver 已经进行了认证，kube-apiserver 会将认证的记过放在 HTTP 请求头里，通常的名字为：`X-Remote-User` 和 `X-Remote-Group`。也可以通过下面的配置来修改 Header 的名字：

- 通过 `--requestheader-username-headers` 标明用来保存用户名的头部
- 通过 `--requestheader-group-headers` 标明用来保存 group 的头部
- 通过 `--requestheader-extra-headers-prefix` 标明用来保存拓展信息前缀的头部

这些头部名称也放置在 `extension-apiserver-authentication` ConfigMap 中， 因此扩展 apiserver 可以检索和使用它们。例如：

```yaml
root@k8s-master:~# kubectl -n kube-system get configmaps extension-apiserver-authentication
NAME                                 DATA   AGE
extension-apiserver-authentication   6      16d
root@k8s-master:~# kubectl -n kube-system get configmaps extension-apiserver-authentication  -o yaml
apiVersion: v1
data:
  client-ca-file: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
  requestheader-allowed-names: '["front-proxy-client"]'
  requestheader-client-ca-file: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
  requestheader-extra-headers-prefix: '["X-Remote-Extra-"]'
  requestheader-group-headers: '["X-Remote-Group"]'
  requestheader-username-headers: '["X-Remote-User"]'
kind: ConfigMap
metadata:
  creationTimestamp: "2022-11-09T15:18:13Z"
  name: extension-apiserver-authentication
  namespace: kube-system
  resourceVersion: "21"
  uid: a0a1a2fa-9991-4825-af97-96a0b3725244
```

那么问题来了，聚合自定义 API 服务什么时候可以信任这些头呢？调用方携带这些头是不是模拟认证过程？

肯定是不行的，**聚合自定义 API 服务于 kube-apiserver 之间的通信是通过客户端 CA 的特殊请求头实现**。认证过程如下：

- http api 客户端使用于 `client-ca-file` 所指定的客户端证书相匹配的证书发起请求

- 通过了 kube-apiserver 服务器的预认证的客户端，使用指定的 `requestheader-client-ca-file` 证书向自定义聚合 APi 服务转发请求，并在 HTTP Header 中添加用户名（X-Remote-Header) 和组（X-Remote-Group）信息。

- 最后，聚合自定义 API 服务有一个 TokenAccessReview(令牌访问审查) 的机制，默认是关闭的。原理就是聚合自定义 API 服务会发送不记名令牌，也就是通过 HTTP 头 `Authorization: bearer token` 给 kube-apiserver 以验证其合法性

#### 委托授权

<u>完成身份认证后，每个请求都需要被授权，在实际的 聚合自定义 API 服务中，这项工作主要是由 `k8s.io/apiserver` 自定实现的。这里只做了解</u>

身份认证是**基于用户名和组**列表来完成的。Kubernetes 默认的授权机制是基于角色的访问控制（Role-Based Access Control，RBAC）。

聚合自定义 API 服务是通过 SubjectAccessReview 代理授权机制来对请求授权，聚合自定义 API 服务自己不会处理 RBAC 规则，而是委托 kube-apiserver 处理。

1. 聚合自定义 API 服务向 kube-apiserver 发送一个 SubjectAccessReview 审查请求    

```yaml
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  resourceAttributes:
    group: apps
    resource: deployments
    verb: create
    namespace: default
    version: v1
    name: example
  user: michael
  groups:
    - system: authenticated
    - admins
    - authors
apiVersion: authorization.k8s.io/v1安排【
```

2. kube-apiserver 收到聚合自定义 API 发来的请求后，基于 RBAC 规则做出判定，返回一个 SubjectAccessReview 对象，其中包含 Status 属性
   
   - allowed 和 denied 属性可能同时为 false，用于表示 kube-apiserver 无法对这个授权进行判断，用于外部授权系统。
   
   - 出于性能考虑，委托授权机制在每个聚合自定义 API 服务中都维护了一个本地缓存，默认缓存 1024 条授权条目：
     
     - 所有通过的授权的请求的缓存过期时间为 5 分钟
     
     - 所有拒绝的授权请求的缓存过期时间为 30 秒
     
     - 可以通过 `--authorization-webhook-cache-authorized-ttl` 和 `--authorization-webhook-cache-unauthorized-ttl` 设置 

```yaml
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
status:
  allowed: true
  denied: false
  reson: "rule foo allowed this request"
```

相信信息见：

[SubjectAccessReview | Kubernetes](https://kubernetes.io/zh-cn/docs/reference/kubernetes-api/authorization-resources/subject-access-review-v1/)

## 开发聚合自定义 API 服务

项目地址：[GitHub - programming-kubernetes/pizza-apiserver: An aggregated custom API server for pizza bakers](https://github.com/programming-kubernetes/pizza-apiserver)

kube-apiserver 是基于 `k8s.io/apiserver` 实现的，同样，开发聚合自定义 API 服务也是基于此包。

下面就以书本上的例子，现在向在 `restaurant.programming-kubernetes.info` API 组中创建两种类型：

- Topping
  
  - 披萨配料。例如，意大利腊肠（slami）、莫泽雷勒干酪（mozzarella）、番茄（tomato）
  
  - 配料是集群范围的资源，并且只有一个浮点类型的值，表示每份配料列表
    
    ```yaml
    apiVersion: restaurant.programming-kubernetes.info/v1alpha1
    kind: Topping
    metadata:
      name: mozzarella
    spec:
      cost: 1.0
    ```

- Pizza
  
  - 餐馆的披萨类型 
  
  - 每个披萨可以搭配多种配料
    
    ```yaml
    apiVersion: restaurant.programming-kubernetes.info/v1alpha1
    kind: Pizza
    metadata:
      name: margherita
    spec:
      toppings:
      - mozzarella
      - tomato
    ```

### 聚合自定义 API 服务的启动

#### 1. 选项（option） - 配置（config）

`k8s.io/apiserver` 库使用一种 "选项 - 配置" 模式来创建一个可运行的 API 服务器

1. 选项

**选项一般不会存储 "运行时" 的数据结构，通常只在启动时使用**，然后就会转换成配置（config）或者相关的服务器对象。

下面基于 RecommendedOptions 来实现所有的选项，这是 apiserver 推荐的选项。这些推荐的选项足以创建一个提供简单API的正常的自定义聚合 API 服务。（`pkg/cmd/server/start.go`）

```go
package server

import (
    informers "github.com/programming-kubernetes/gsh-apiserver/pkg/generated/informers/externalversions"
    genericoptions "k8s.io/apiserver/pkg/server/options"
    "k8s.io/client-go/informers"
)

const defaultEtcdPathPrefix = "/registry/pizza-apiserver.programming-kubernetes.info"

type CustomServerOptions struct {
    RecommendedOptions *genericoptions.RecommendedOptions

    SharedInformerFactory informers.SharedInformerFactory
}

func NewCustomServerOptions() *CustomServerOptions {
    o := &CustomServerOptions{
        RecommendedOptions: genericoptions.NewRecommendedOptions(
            defaultEtcdPathPrefix,
            apiserver.Codecs.LegacyCodec(v1alpha1.SchemeGroupVersion),
            genericoptions.NewProcessInfo("pizza-apiserver", "pizza-apiserver"),
        ),
    }

    return o
}
```

- defaultEtcdPathPrefix: 表示在 ETCD 中 Key 的前缀

- CustomServerOptions 中嵌入了：
  
  - RecommendedOptions：是 apiserver 的推荐选项的结构体
  
  - SharedInformerFactory：是我们自己的 CR 的进程级别的共享 Informer 工厂，以避免相同资源创建多个不必要的 Informer。注意，这里是我们自己的 CR 资源的 Informer

下面看看 apiserver 的推荐选项都有哪些：

```go
func NewRecommendedOptions(prefix string, codec runtime.Codec) *RecommendedOptions {
    sso := NewSecureServingOptions()

    // We are composing recommended options for an aggregated api-server,
    // whose client is typically a proxy multiplexing many operations ---
    // notably including long-running ones --- into one HTTP/2 connection
    // into this server.  So allow many concurrent operations.
    sso.HTTP2MaxStreamsPerConnection = 1000

    return &RecommendedOptions{
        Etcd:           NewEtcdOptions(storagebackend.NewDefaultConfig(prefix, codec)),
        SecureServing:  sso.WithLoopback(),
        Authentication: NewDelegatingAuthenticationOptions(),
        Authorization:  NewDelegatingAuthorizationOptions(),
        Audit:          NewAuditOptions(),
        Features:       NewFeatureOptions(),
        CoreAPI:        NewCoreAPIOptions(),
        // Wired a global by default that sadly people will abuse to have different meanings in different repos.
        // Please consider creating your own FeatureGate so you can have a consistent meaning for what a variable contains
        // across different repos.  Future you will thank you.
        FeatureGate:                feature.DefaultFeatureGate,
        ExtraAdmissionInitializers: func(c *server.RecommendedConfig) ([]admission.PluginInitializer, error) { return nil, nil },
        Admission:                  NewAdmissionOptions(),
        EgressSelector:             NewEgressSelectorOptions(),
        Traces:                     NewTracingOptions(),
    }
}
```

- **Etcd**：<u>设置存储栈</u>，存储层是通过读写 etcd 来实现

- **SecureServing**：<u>设置 HTTPS 的一切选项</u>

- **Authentication**：<u>身份认证选项</u>

- **Authorization**：<u>授权选项</u>

- **Audit**：<u>设置审计输出栈</u>。默认禁用，可以设置输出到审计日志或者将审计事件发送到外部的后端系统

- **Features**：<u>设置是否禁用某些 Alpha 和 Beta 功能</u>

- **CoreAPI**：<u>设置用于访问 Kubernetes API 服务器的 kubeconfig 文件的路径</u>。默认使用当前集群的配置

- **Admission**：<u>是一个在每个 API 请求上执行的变更和准入的插件集</u>。

- **ExtraAdmissionInitializers**：<u>允许添加更多的准入初始化逻辑</u>。默认的初始化器会创建一些基础设施，例如，自定义 API 服务器的 Informer 和客户端。

- **EgressSelector**：<u>用于控制来自 API Server 的出站流量</u>

- **Traces**：<u>代码跟踪的选项</u>
2. 配置

选项可以通过 `Config(*apiserver.Config, error)` 方法来转换成服务器配置（config），**配置设置的是运行时对象的配置**。(`pkg/cmd/server/start.go`)

```go
func (o *CustomServerOptions) Config() (*apiserver.Config, error) {
    // TODO have a "real" external address
    if err := o.RecommendedOptions.SecureServing.MaybeDefaultWithSelfSignedCerts("localhost", nil, []net.IP{net.ParseIP("127.0.0.1")}); err != nil {
        return nil, fmt.Errorf("error creating self-signed certificates: %v", err)
    }

    o.RecommendedOptions.ExtraAdmissionInitializers = func(c *genericapiserver.RecommendedConfig) ([]admission.PluginInitializer, error) {
        client, err := clientset.NewForConfig(c.LoopbackClientConfig)
        if err != nil {
            return nil, err
        }
        informerFactory := informers.NewSharedInformerFactory(client, c.LoopbackClientConfig.Timeout)
        o.SharedInformerFactory = informerFactory
        return []admission.PluginInitializer{custominitializer.New(informerFactory)}, nil
    }

    serverConfig := genericapiserver.NewRecommendedConfig(apiserver.Codecs)
    if err := o.RecommendedOptions.ApplyTo(serverConfig); err != nil {
        return nil, err
    }

    config := &apiserver.Config{
        GenericConfig: serverConfig,
        ExtraConfig:   apiserver.ExtraConfig{},
    }
    return config, nil
}
```

- `o.RecommendedOptions.SecureServing.MaybeDefaultWithSelfSignedCerts` 创建了一个自签名证书，可以在用户没有传与生成证书时使用

- `genericapiserver.NewRecommendedConfig` 返回一个推荐的默认配置，然后通过 `ApplyTo` 来根据选项来修改配置。

- 这里注意，apiserver 是自定义的配置，而 genericapiserver 是 `k8s.io/apiserver` 推荐的配置

我们可以对 `k8s.io/apiserver` 推荐的配置进行简单的封装(`pkg/apiserver/apiserver.go`)：

```go
package apiserver

import (
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apiserver/pkg/registry/rest"
    genericapiserver "k8s.io/apiserver/pkg/server"
)

type ExtraConfig struct {
    // Place you custom config here.
}

type Config struct {
    GenericConfig *genericapiserver.RecommendedConfig
    ExtraConfig   ExtraConfig
}

// CustomServer contains state for a Kubernetes cluster master/api server.
type CustomServer struct {
    GenericAPIServer *genericapiserver.GenericAPIServer
}

type completedConfig struct {
    GenericConfig genericapiserver.CompletedConfig
    ExtraConfig   *ExtraConfig
}

type CompletedConfig struct {
    // Embed a private pointer that cannot be instantiated outside of this package.
    *completedConfig
}

// Complete fills in any fields not set that are required to have valid data. It's mutating the receiver.
func (cfg *Config) Complete() CompletedConfig {
    c := completedConfig{
        cfg.GenericConfig.Complete(),
        &cfg.ExtraConfig,
    }

    c.GenericConfig.Version = &version.Info{
        Major: "1",
        Minor: "0",
    }

    return CompletedConfig{&c}
}

// New returns a new instance of CustomServer from the given config.
func (c completedConfig) New() (*CustomServer, error) {
    genericServer, err := c.GenericConfig.New("pizza-apiserver", genericapiserver.NewEmptyDelegate())
    if err != nil {
        return nil, err
    }

    s := &CustomServer{
        GenericAPIServer: genericServer,
    }

    [...API installation...]

    return s, nil
}
```

- Config：封装了 `k8s.io/apiserver` 的 GenericConfig（推荐配置 RecommendedConfig）和 ExtraConfig (可以存放额外的配置信息)

- 配置（Config）有一个 `Complete() CompletedConfig` 方法用来设置其默认值。原则上调用 Complete() 才能将 Config 转成 completeConfig。如果没有调用该方法，编译器会报错

- CustomServer：封装了了可以启动的 `genericapiserver.GenericAPIServer`

- 最后，通过 New 构造方法，把一份完成的配置变成 CustomServer 运行时结构。中间省略了 API 组的安装。CustomServer 对象最终可以被 `Run(stopCh <- chan strut{}) error` 方法启动

整个启动的流程就是：

- 创建选项

- 通过选项创建配置

- 完成配置

- 创建 CustomServer

- 调用 CustomServer.Run

最终的启动 `Run(stopCh <- chan strut{}) error` 方法如下（`pkg/cmd/server/start.go`）：

```go
func (o CustomServerOptions) Run(stopCh <-chan struct{}) error {
    config, err := o.Config()
    if err != nil {
        return err
    }

    server, err := config.Complete().New()
    if err != nil {
        return err
    }

    server.GenericAPIServer.AddPostStartHook("start-pizza-apiserver-informers", func(context genericapiserver.PostStartHookContext) error {
        config.GenericConfig.SharedInformerFactory.Start(context.StopCh)
        o.SharedInformerFactory.Start(context.StopCh)
        return nil
    })

    return server.GenericAPIServer.PrepareRun().Run(stopCh)
}
```

- PrepareRun 方法调用对接了 OpenAPI 规范，并且可能进行一些其他 API 安装完成后的操作

- 在 PrepareRun 之后，Run 方法会启动真正的服务，并且一直阻塞到 stopCh 关闭为止

- 这里还对接了一个启动后的钩子，AddPostStartHook 允许您添加 PostStartHook，也就是启动后，钩子会在HTTPS 服务启动并监听后调用。

- `/healthz` 接口，只会在所有启动后钩子都成功执行后，才返回成功。

上面搞定了所有启动的选项、配置、以及启动HTTP服务等基础设施，最后把启动包装到 cobra 的一个命令中（`pkg/server/start.go`）：

```go
// NewCommandStartCustomServer provides a CLI handler for 'start master' command
// with a default CustomServerOptions.
func NewCommandStartCustomServer(defaults *CustomServerOptions, stopCh <-chan struct{}) *cobra.Command {
    o := *defaults
    cmd := &cobra.Command{
        Short: "Launch a custom API server",
        Long:  "Launch a custom API server",
        RunE: func(c *cobra.Command, args []string) error {
            if err := o.Complete(); err != nil {
                return err
            }
            if err := o.Validate(); err != nil {
                return err
            }
            if err := o.Run(stopCh); err != nil {
                return err
            }
            return nil
        },
    }

    flags := cmd.Flags()
    o.RecommendedOptions.AddFlags(flags)

    return cmd
}
```

有了 NewCommandStartCustomServer ，main 函数就非常简单了：

```go
func main() {
    logs.InitLogs()
    defer logs.FlushLogs()

    stopCh := genericapiserver.SetupSignalHandler()
    options := server.NewCustomServerOptions()
    cmd := server.NewCommandStartCustomServer(options, stopCh)
    cmd.Flags().AddGoFlagSet(flag.CommandLine)
    if err := cmd.Execute(); err != nil {
        klog.Fatal(err)
    }
}
```

- 这里注意 SetupSignalHandler 的调用，对接了 UNIX 信号处理。当接受了 SIGINT（Ctrl-C）和 SIGKILL 信号，终止程序的 Channel 对象会关闭。Channel 停止时，API 服务器也会关闭

- 上述动作是平滑的，确保了所有请求都会发送到审计后端，不会丢失审计日志。

- 最后调用  cmd.Execute() 将会调用 cmd 总的 runE 函数。 

#### 2. 启动命令

加入 kubeconfig 的配置文件在 `~/.kube/config` ，可以使用如下命令启动：

```shell
# go run . -etcd-servers localhost:2379 --authentication-kubeconfig ~/.kube/config --authorization-kubeconfig ~/.kube/config --kubeconfig ~/.kube/config
```

服务器启动后，可以查看通用的 API 接口，查看状态：

```shell
$ curl -k https://locaolhost:443/healthz
ok
```

### 内部类型和转换

现在可以实现真正的 API 了，但是在开始之前，要了解 API 版本。

**每个 API 服务器都可以提供多个资源和版本的服务**。<u>有些资源有多个版本，为了让一个资源的多版本共存，API 服务器需要把资源在多个版本之间进行转换</u>。

为了避免版本转换场景数量的平方级增长，**API服务器在实现真正的 API 逻辑时，使用了一个内部版本**。这个内部版本通常也叫做**中枢版本**，因为<u>它可以用作每个版本都能与之转换的一个中间版本</u>。如下图：

<img src="file:///E:/notes/云计算/pic/k8s开发/k8s-custom-api-internal-api-trans.jpg" title="" alt="k8s-custom-api-internal-api-trans" data-align="center">

下图展示了 API 服务器在一个 API 请求的生命周期里与内部版本的转换：

- 用户发送一个特定版本的请求（例如 v1）

- API 服务器将请求解码并转换成内部版本

- API 服务器对内部版本的请求进行准入检测和验证

- 实现注册表里 API  的逻辑时，用的就是该内部版本

- etcd 读取或写入特定版本的对象（例如使用 v2 作为存储版本），在这个过程，需要与内部版本进行互转

- 结果会转成请求中所指定的版本返回，即 v1

![k8s-custom-api-live-trans](E:\notes\云计算\pic\k8s开发\k8s-custom-api-live-trans.jpg)

- 在内部中枢版本和外部版本的每个连接处，都会发生一次转换。

- 在发生写操作时，至少要做四次操作，在集群里部署准入 webhook 时还会发生多次转换。

- 因此，转换至关重要

除了转换，默认值填充在特定转换时也会发生，如下图：

![k8s-custom-api-live-default](E:\notes\云计算\pic\k8s开发\k8s-custom-api-live-default.jpg)

- 默认值处理是填充未设定值字段的过程。

- 默认值处理总是和转换一起出现，并且总是对来自用户请求、etcd 或者准入 webhook 的外部版本进行。

- 默认值不会出现在中枢版本往外部版本转换的过程。

### 编写 API 类型

前面介绍了，为了给自定义 API 服务器添加一个 API，我们**需要编写内部中枢版本类型和外部类型，以及他们之间的转换**。其中

- API 类型一般会放在项目的 `pkg/apis/[group-name]` 中

- 内部类型放在项目的 `pkg/apis/[group-name]/types.go`

- 外部类型放在项目的 `pkg/apis/[group-name]/version/types.go`

例如项目中的 `pkg/apis/restaurant/types.go`（内部类型）、 `pkg/apis/restaurant/v1beta1/types.go` （v1beta1 版本的外部类型）、`pkg/apis/restaurant/v1alpha1/types.go`（v1alpha1 版本的外部类型）

**不同类型之间转换和默认值处理代码**一般可以由生成器自动生成，也可以自定义（后面介绍）：

- **conversion-gen **：转换代码生成器
  
  - 自动生成位置在 `pkg/apis/[group-name]/version/zz_generated.conversion.go` 文件
  
  - 开发者自定义的代码在 `pkg/apis/[group-name]/version/conversion.go` 文件

- **defaulter-gen** ：默认值处理的代码生成器
  
  - 位置在 `pkg/apis/[group-name]/version/zz_generated.defaults.go` 文件
  
  - 开发者自定义的代码在 `pkg/apis/[group-name]/version/defaults.go` 文件

#### 1. 编写 API 类型

编写 API 类型与 CRD 的自定义类型是一样的，用到了 `k8s.io/apimachinery` 包中的 TypeMeta 和 ObjectMeta

这里要注意的是，与  CRD 不同的是 聚合自定义 API 要定义 内部中枢类型 和 外部版本类型。

例如，项目中的内部类型位于 `pkg/apis/restaurant/types.go`:

```go
package restaurant

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

// +genclient
// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

// Pizza specifies an offered pizza with toppings.
type Pizza struct {
    metav1.TypeMeta
    metav1.ObjectMeta

    Spec   PizzaSpec
    Status PizzaStatus
}

type PizzaSpec struct {
    // toppings is a list of Topping names. They don't have to be unique. Order does not matter.
    Toppings []PizzaTopping
}

type PizzaTopping struct {
    // name is the name of a Topping object .
    Name string
    // quantity is the number of how often the topping is put onto the pizza.
    Quantity int
}

type PizzaStatus struct {
    // cost is the cost of the whole pizza including all toppings.
    Cost float64
}

// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

// PizzaList is a list of Pizza objects.
type PizzaList struct {
    metav1.TypeMeta
    metav1.ListMeta

    Items []Pizza
}

// +genclient
// +genclient:nonNamespaced
// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

// Topping is a topping put onto a pizza.
type Topping struct {
    metav1.TypeMeta
    metav1.ObjectMeta

    Spec ToppingSpec
}

type ToppingSpec struct {
    // cost is the cost of one instance of this topping.
    Cost float64
}

// +genclient:nonNamespaced
// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

// ToppingList is a list of Topping objects.
type ToppingList struct {
    metav1.TypeMeta
    metav1.ListMeta

    // Items is a list of Toppings
    Items []Topping
}
```

注意：

**外部类型和内部类型定义不同之处在于：内部类型不需要 JOSN 和 Protobuf 标签，而外部类型需要**。

JSON标签通常被一些生成器用于探测一个 types.go 文件是外部版本还是内部版本。

#### 2. 注册 API 类型到 Scheme

内部类型和外部类型的定义是一样的，只是在注册的时候不同。

- 内部版本注册的时候（`pkg/apis/restaurant/register.go`），定义的 SchemeGroupVersion 引用了 runtime.APIVersionInternal 作为其组版本

```go
var SchemeGroupVersion = schema.GroupVersion{Group: GroupName, Version: runtime.APIVersionInternal}
```

- 外部版本如下（`pkg/apis/restaurant/v1alpha1/register.go`）:

```go
var SchemeGroupVersion = schema.GroupVersion{Group: GroupName, Version: "v1alpha1"}
```

最后，**需要定义辅助工具函数将 API 的所有版本安装到 Scheme 中。一般放在 `pkg/apis/[group-name]/install/install.go`**

例如：现在项目中 `pkg/apis/restaurant/install/install.go`:

```go
// Install registers the API group and adds types to a scheme
func Install(scheme *runtime.Scheme) {
    utilruntime.Must(restaurant.AddToScheme(scheme))
    utilruntime.Must(v1beta1.AddToScheme(scheme))
    utilruntime.Must(v1alpha1.AddToScheme(scheme))
    utilruntime.Must(scheme.SetVersionPriority(v1beta1.SchemeGroupVersion, v1alpha1.SchemeGroupVersion))
}
```

- 最后 SetVersionPriority 定义了版本的优先级，决定了该资源优先使用哪个默认的存储版本。

### 转换与默认值处理

#### 1. 转换

**转换用于将某个版本的对象转成拎一个版本**。转换是通过转换函数实现的，转换函数可以手写（`pkg/apis/[group-name]/version/conversion.go`）、也可以通过 conversion-gen 自动生成（`pkg/apis/[group-name]/version/zz_generated.conversion.go`）。

为了完成实际的转换操作，<u>Scheme 需要知道所有的 Golang API 类型，它们的 GroupVersionKind，以及不同 GroupVersionKind 之间的转换函数</u>。

conversion-gen 通过本地的 Scheme 构建起注册了生成的转换函数，例如 `pkg/apis/restaurant/v1alpha1/zz_generated.conversion.go`  开头的注册函数:

```go
func init() {
    localSchemeBuilder.Register(RegisterConversions)
}

// RegisterConversions adds conversion functions to the given scheme.
// Public to allow building arbitrary schemes.
func RegisterConversions(s *runtime.Scheme) error {
    if err := s.AddGeneratedConversionFunc((*Pizza)(nil), (*restaurant.Pizza)(nil), func(a, b interface{}, scope conversion.Scope) error {
        return Convert_v1beta1_Pizza_To_restaurant_Pizza(a.(*Pizza), b.(*restaurant.Pizza), scope)
    }); err != nil {
        return err
    }
    if err := s.AddGeneratedConversionFunc((*restaurant.Pizza)(nil), (*Pizza)(nil), func(a, b interface{}, scope conversion.Scope) error {
        return Convert_restaurant_Pizza_To_v1beta1_Pizza(a.(*restaurant.Pizza), b.(*Pizza), scope)
    }); err != nil {
        return err
    }

    ...

    if err := s.AddGeneratedConversionFunc((*restaurant.PizzaTopping)(nil), (*PizzaTopping)(nil), func(a, b interface{}, scope conversion.Scope) error {
        return Convert_restaurant_PizzaTopping_To_v1beta1_PizzaTopping(a.(*restaurant.PizzaTopping), b.(*PizzaTopping), scope)
    }); err != nil {
        return err
    }
    return nil
}


// Convert_v1beta1_Pizza_To_restaurant_Pizza is an autogenerated conversion function.
func Convert_v1beta1_Pizza_To_restaurant_Pizza(in *Pizza, out *restaurant.Pizza, s conversion.Scope) error {
    return autoConvert_v1beta1_Pizza_To_restaurant_Pizza(in, out, s)
}
```

- 这个文件是自动生成的

- Convert_v1beta1_Pizza_To_restaurant_Pizz 函数也是自动生成的，可以将一个 v1beta1 版本的对象转换成内部类型

- RegisterConversions 将转换函数添加到给定的方案中。

自定义的转换函数具有更高的优先级，自定义的转换函数写在 conversion.go 中，命名规范与上面的类似，`Convert_[source-version]_[source-kind]_To_[target-version]_[target_kind]`

conversion-gen 发现包里已经由这样的命名规范的函数，就会跳过这些类型的转函数。例如（`pkg/apis/restaurant/v1alpha1/conversion.go`）:

```go
func Convert_v1alpha1_PizzaSpec_To_restaurant_PizzaSpec(in *PizzaSpec, out *restaurant.PizzaSpec, s conversion.Scope) error {
    idx := map[string]int{}
    for _, top := range in.Toppings {
        if i, duplicate := idx[top]; duplicate {
            out.Toppings[i].Quantity++
            continue
        }
        idx[top] = len(out.Toppings)
        out.Toppings = append(out.Toppings, restaurant.PizzaTopping{
            Name: top,
            Quantity: 1,
        })
    }

    return nil
}
```

- 注意：源对象一定不能修改。

- 为了性能考虑，强烈建议在类型匹配的情况下，尽量在目标对象里服用源对象的数据结构

#### 2. 默认值处理

**默认值处理是 API 生命周期里给对象（来自客户端或者 etcd）中缺失的字段填充默认值的步骤**。

默认值处理是 `k8s.io/apiserver` 通过 Scheme 进行初始化、类型转换。因此我们也同样需要在 Scheme 中为我们的自定义类型注册默认值处理函数。

与转换函数类似，默认值处理函数可以通过 defaaulter-gen 生成，它会遍历 API 类型，并且在生成`pkg/apis/[group-name]/version/zz_generated.defaults.go` 文件，在此文件中创建默认值处理函数，例如(`pkg/apis/restaurant/v1alpha1/zz_generated.defaults.go`)：

```go
func RegisterDefaults(scheme *runtime.Scheme) error {
    scheme.AddTypeDefaultingFunc(&Pizza{}, func(obj interface{}) { SetObjectDefaults_Pizza(obj.(*Pizza)) })
    scheme.AddTypeDefaultingFunc(&PizzaList{}, func(obj interface{}) { SetObjectDefaults_PizzaList(obj.(*PizzaList)) })
    return nil
}

func SetObjectDefaults_Pizza(in *Pizza) {
    SetDefaults_PizzaSpec(&in.Spec)
}

func SetObjectDefaults_PizzaList(in *PizzaList) {
    for i := range in.Items {
        a := &in.Items[i]
        SetObjectDefaults_Pizza(a)
    }
}
```

- RegisterDefaults 用来注册默认值处理函数，与转换不同的是，如果由自定义的默认值处理函数，我们需要手动在本地 Scheme 构建起中对该函数进行注册。

- SetDefaults_PizzaSpec 是一个自定义的默认值处理函数

自定义默认值处理函数一般在 `pkg/apis/[group-name]/version/defaults.go` ，自定义默认值处理函数命名规范为：

```shell
SetDefaults_Kind
```

例如，在项目中 `pkg/apis/restaurant/v1alpha1/defaults.go`:

```go
func init() {
    localSchemeBuilder.Register(RegisterDefaults)
}

func SetDefaults_PizzaSpec(obj *PizzaSpec) {
    if len(obj.Toppings) == 0 {
        obj.Toppings = []string{"salami","mozzarella","tomato"}
    }
}
```

- init 函数就是手动调用注册函数，注册到 Scheme 构建器

默认值处理的难点是，某一个字段是否需要被设置默认值。例如，如果某个 bool 类型的字段没有设定值，golang 的零值为 false，那么如何判断 false 是不是用户设定的值呢？

为了避免这种情况，**Golang API 类型中使用类型的指针**，例如可有设置字段类型为 `*bool` ，也就是 bool 指针类型，如果用户没有设置值，那就是 nil。

#### 3. 双程测试

双程测试通过在随机测试中，自动检测转换的结果，来判断结果是否符合预期。即在所有组版本之间来回转换，并丢失数据，来保证逻辑正确。

例如，在项目中，`pkg/apis/restaurant/install/roundtrip_test.go`:

```go
import (
    "testing"

    "k8s.io/apimachinery/pkg/api/apitesting/fuzzer"
    "k8s.io/apimachinery/pkg/api/apitesting/roundtrip"
    metafuzzer "k8s.io/apimachinery/pkg/apis/meta/fuzzer"

    restaurantfuzzer "github.com/programming-kubernetes/pizza-apiserver/pkg/apis/restaurant/fuzzer"
)

func TestRoundTripTypes(t *testing.T) {
    roundtrip.RoundTripTestForAPIGroup(t, Install, fuzzer.MergeFuzzerFuncs(metafuzzer.Funcs, restaurantfuzzer.Funcs))
}
```

- <u>RoundTripTestForAPIGroup 内部会调用 install 函数在一个临时 Scheme 中安装该 API 组，然后用指定的 Fuzzer 模糊测试创建随机的内部版本对象，并转换程其他外部版本然后再转回来。转换的结果必须和原始的对象等价。</u>

Fuzzer 函数返回一组随机函数，这些随机函数可以生成随机的内湖类型及其子类型的对象。例如 `pkg/apis/restaurant/fuzzer/fuzzer.go`:

```go
var Funcs = func(codecs runtimeserializer.CodecFactory) []interface{} {
    return []interface{}{
        func(s *restaurant.PizzaSpec, c fuzz.Continue) {
            c.FuzzNoCustom(s) // fuzz first without calling this function again

            // avoid empty Toppings because that is defaulted
            if len(s.Toppings) == 0 {
                s.Toppings = []restaurant.PizzaTopping{
                    {"salami", 1},
                    {"mozzarella", 1},
                    {"tomato", 1},
                }
            }

            seen := map[string]bool{}
            for i := range s.Toppings {
                // make quantity strictly positive and of reasonable size
                s.Toppings[i].Quantity = 1 + c.Intn(10)

                // remove duplicates
                for {
                    if !seen[s.Toppings[i].Name] {
                        break
                    }
                    s.Toppings[i].Name = c.RandString()
                }
                seen[s.Toppings[i].Name] = true
            }
        },
    }
}
```

- 如果没有提供 Fuzzer 函数，那么 `github.com/google/gofuzz` 基础库会尝试通过基础类型设置随机值来狗在对象。

- 构造 Fuzzer 函数时，建议先调用 c.FuzzNoCustom(s) 函数，它会为给定的对象 s 进行随机赋值，并调用其子结构的自定义随机函数、

### 验证

**验证过程是在变更准入插件和验证准入插件之间完成，这个位置远早于实际的创建或更新逻辑**，如下：

![k8s-custom-api-live-trans](E:\notes\云计算\pic\k8s开发\k8s-custom-api-live-trans.jpg)

根据上图，<u>验证过程，其实是对内部类型进行的，因此只需要为内部类型实现一次，而不需要为各种外部版本分别实现</u>。

验证过程会调用 `pkg/apis/[group-name]/validation` 包中的验证函数，函数的命名规范为：

```go
func ValidateKind(f *restaurant.Pizza) field.ErrorList
func ValidateKindUpdate(f *restaurant.Pizza) field.ErrorList
```

验证函数返回返回错误列表，在递归调用结构体中个对象的验证函数时，会把发现的错误追到这个列表中。

例如：

```go
// ValidatePizza validates a Pizza.
func ValidatePizza(f *restaurant.Pizza) field.ErrorList {
    allErrs := field.ErrorList{}

    allErrs = append(allErrs, ValidatePizzaSpec(&f.Spec, field.NewPath("spec"))...)

    return allErrs
}

// ValidatePizzaSpec validates a PizzaSpec.
func ValidatePizzaSpec(s *restaurant.PizzaSpec, fldPath *field.Path) field.ErrorList {
    allErrs := field.ErrorList{}

    prevNames := map[string]bool{}
    for i := range s.Toppings {
        if s.Toppings[i].Quantity <= 0 {
            allErrs = append(allErrs, field.Invalid(fldPath.Child("toppings").Index(i).Child("quantity"), s.Toppings[i].Quantity, "cannot be negative or zero"))
        }
        if len(s.Toppings[i].Name) == 0 {
            allErrs = append(allErrs, field.Invalid(fldPath.Child("toppings").Index(i).Child("name"), s.Toppings[i].Name, "cannot be empty"))
        } else {
            if prevNames[s.Toppings[i].Name] {
                allErrs = append(allErrs, field.Invalid(fldPath.Child("toppings").Index(i).Child("name"), s.Toppings[i].Name, "must be unique"))
            }
            prevNames[s.Toppings[i].Name] = true
        }
    }

    return allErrs
}
```

### 注册表与策略

注册表是实现 API 组的核心，`k8s.io/apiserver` 中通用的 REST 请求处理器会调用注册逻辑

#### 1. 通用注册表

Rest 的逻辑是由通用注册表来实现的。在 `k8s.io/apiserver/pkg/registry/rest` 包中对通用注册表接口有一个通用的实现。通用注册表结构如下：

![k8s-common-reigstry-table](E:\notes\云计算\pic\k8s开发\k8s-common-registry-table.jpg)

通用注册表为普通资源实现了默认的 REST 行为。在 `k8s.io/apiserver/pkg/registry/rest/rest.go` 中定义了很多接口，与 HTTP Verb 和 API 功能基本对应。

如果注册表实现了某个接口，API 端点的代码就能提供相应的 REST 功能。

通用注册表实现了 `k8s.io/apiserver/pkg/registry/rest/rest` 中的大部分的接口，因此使用通用注册表的资源都可以支持所有默认的 Kubernentes HTTP Verbs。

下面是 `k8s.io/apiserver/pkg/registry/rest/rest.go` 中一些接口列表：

- **CollectionDeleter**：  CollectionDeleter 是一个可以删除 RESTful 资源集合的对象

- **Creater**： Creater 是一个可以创建 RESTful 对象实例的对象

- **NamedCreater**：NamedCreater 是一个可以使用名称参数创建 RESTful 对象实例的对象。

- **CreaterUpdater**：CreaterUpdater 是一个存储对象，必须同时支持创建和更新。 Go 阻止实现相同方法的嵌入式接口。

- **Updater**：Updater 是一个可以更新 RESTful 对象实例的对象

- **Exporter**：Exporter 是一个知道如何剥离 RESTful 资源以进行导出的对象。如果该类型通常支持导出，用于为导出功能进行 RESTful 资源裁剪的对象。当类型的某些实例不可导出时，在实际导出期间仍可能返回错误。

- **Getter**：Getter 是一个可以按名字检索 RESTful 资源的对象

- **GracefulDeleter**：GracefulDeleter 用于依据传入的删除选项实现 RESTful 对象延迟删除逻辑的对象

- **Lister**：可以匹配指定字段和标签条件获取资源列表的字段

- **Patcher**：Patcher是一个存储对象，同时支持get和update

- **Scoper**：用于指定资源所属域的对象（必选）

- **Watcher**：所有存储对象都必须实现的对象，用于 Watch API 提供的 watch 功能

还有很多接口，以 Creater 接口为例：

```go
// Creater is an object that can create an instance of a RESTful object.
type Creater interface {
    // New returns an empty object that can be used with Create after request data has been put into it.
    // This object must be a pointer type for use with Codec.DecodeInto([]byte, runtime.Object)
    New() runtime.Object

    // Create creates a new version of a resource.
    Create(ctx context.Context, obj runtime.Object, createValidation ValidateObjectFunc, options *metav1.CreateOptions) (runtime.Object, error)
}

// NamedCreater is an object that can create an instance of a RESTful object using a name parameter.
type NamedCreater interface {
    // New returns an empty object that can be used with Create after request data has been put into it.
    // This object must be a pointer type for use with Codec.DecodeInto([]byte, runtime.Object)
    New() runtime.Object

    // Create creates a new version of a resource. It expects a name parameter from the path.
    // This is needed for create operations on subresources which include the name of the parent
    // resource in the path.
    Create(ctx context.Context, name string, obj runtime.Object, createValidation ValidateObjectFunc, options *metav1.CreateOptions) (runtime.Object, error)
}
```

- Creater 创建对象的名字支持能从 `obj runtime.Object` 获取

- 而 NamedCreater 则名字是通过 url path 传入的

实现了哪些接口决定了 API 端点可以支持哪些 HTTP Verbs。

#### 2. 策略

策略，对通用注册表进行一定给程度上的定制。也就是每个资源都有自己的一套策略，注册表需要实现这套策略的接口。

在 `k8s.io/apisever/pkg/registry/rest` 包中已经定义了一些策略：

- **RESTCreateStrategy**：`k8s.io/apisever/pkg/registry/rest/create.go`
  
  - 定义最基本的验证条件、可以接受的输入，以及按照 Kubernentes API 规范为新建的对象生成名字的行为

- **RESTDeleteStrategy**：`k8s.io/apisever/pkg/registry/rest/delete.go`
  
  - 定义按照 Kubernetes API 规范实现的对象的删除行为。

- **RESTGracefulDeleteStrategy**：`k8s.io/apisever/pkg/registry/rest/delete.go`
  
  - 注册表需要实现这个接口以支持平滑的对象删除行为

- **GarbageCollectionDeleteStrategy**：`k8s.io/apisever/pkg/registry/rest/delete.go`
  
  - 注册表需要需要实现这个接口以支持默认的对孤儿对象的处理逻辑

- **RESTExportStrategy**：`k8s.io/apisever/pkg/registry/rest/export.go`
  
  - 定义如何导出一个一个 Kubernetes 对象

- **RESTUpdateStrategy**：`k8s.io/apisever/pkg/registry/rest/update.go`
  
  - 按照 Kubernetes 规范，定义在更新对象时，所需要的最基本的验证条件、可以接受的输入，以及生成对象名字的行为。

下面以 RESTCreateStrategy 策略为例：

```go
type RESTCreateStrategy interface {
    runtime.ObjectTyper
    // The name generator is used when the standard GenerateName field is set.
    // The NameGenerator will be invoked prior to validation.
    names.NameGenerator

    // NamespaceScoped returns true if the object must be within a namespace.
    NamespaceScoped() bool
    // PrepareForCreate is invoked on create before validation to normalize
    // the object.  For example: remove fields that are not to be persisted,
    // sort order-insensitive list fields, etc.  This should not remove fields
    // whose presence would be considered a validation error.
    //
    // Often implemented as a type check and an initailization or clearing of
    // status. Clear the status because status changes are internal. External
    // callers of an api (users) should not be setting an initial status on
    // newly created objects.
    PrepareForCreate(ctx context.Context, obj runtime.Object)
    // Validate returns an ErrorList with validation errors or nil.  Validate
    // is invoked after default fields in the object have been filled in
    // before the object is persisted.  This method should not mutate the
    // object.
    Validate(ctx context.Context, obj runtime.Object) field.ErrorList
    // Canonicalize allows an object to be mutated into a canonical form. This
    // ensures that code that operates on these objects can rely on the common
    // form for things like comparison.  Canonicalize is invoked after
    // validation has succeeded but before the object has been persisted.
    // This method may mutate the object. Often implemented as a type check or
    // empty method.
    Canonicalize(obj runtime.Object)
}
```

- 内置的 ObjectTypesr，能识别对象，会检查注册表能否支持请求中传入的对象。这对创建正确型别的对象非常重要。例如 ，Foo 资源，只能创建 Foo 类型的资源。

- NameGenerator，用于根据 ObjectMeta.GenerateName 字段来生成对象名字。

- NamespaceScoped，策略通过对 NamespaceScoped 返回 false 或 true 来表示其支持集群级别或命名空间级别的资源。

- PrepareForCreate，在验证前会对传入的对象调用 PrepareForCreate 方法

- Validate，验证函数的入口

- Canonicalize，归一化，例如对对象中包含的切片进行排序

#### 3. 把策略写入通用注册表

注册表上面介绍了，其实在 apiserver 中，就是一个 Store 对象。

下面是我们的项目中的 REST 存储构造对象。(类似于我们的 model 层)，`pkg/registry/restaurant/pizza/strategy.go`

```go
// NewREST returns a RESTStorage object that will work against API services.
func NewREST(scheme *runtime.Scheme, optsGetter generic.RESTOptionsGetter) (*registry.REST, error) {
    strategy := NewStrategy(scheme)

    store := &genericregistry.Store{
        NewFunc:                  func() runtime.Object { return &restaurant.Pizza{} },
        NewListFunc:              func() runtime.Object { return &restaurant.PizzaList{} },
        PredicateFunc:            MatchPizza,
        DefaultQualifiedResource: restaurant.Resource("pizzas"),

        CreateStrategy: strategy,
        UpdateStrategy: strategy,
        DeleteStrategy: strategy,
    }
    options := &generic.StoreOptions{RESTOptions: optsGetter, AttrFunc: GetAttrs}
    if err := store.CompleteWithOptions(options); err != nil {
        return nil, err
    }
    return &registry.REST{store}, nil
}
```

- 首先创建了一个自定义策略

- 其次，使用 genericregistry.Store 创建了一个通用注册表对象，并且设置了一些字段，其中包括， 
  
  - CreateStrategy、UpdateStrategy、DeleteStrategy 等策略，只用的是自定义的策略，并且实现了对应策略的方法。
  
  - NewFunc：用于创建新的对象实例
  
  - NewListFunc：用于创建一个对象列表
  
  - PredicateFunc：用于把一个选择器（可以传递给一个列表请求）转换为一个预测函数，用于过滤运行期的对象。

- genericregistry.Store 对象没有设置的字段，通过 CompleteWithOptions 函数设置默认值

- 最后返回要给 REST 对象，这个其实就是注册表，实现为(就是对 Store 对象简单封装)：
  
  ```go
  // REST implements a RESTStorage for API services against etcd
  type REST struct {
      *genericregistry.Store
  }
  ```

有了注册表，就可以创建 API 实例，并集成到 API 服务器中。

### 安装 API

在 API 服务器中启用 API，一共需要两步：

- <u>API 版本必须安装到相应的 API 类型（包括转换和默认函数）的服务器 Scheme 中</u>。

- <u>API 版本必须安装到服务器的 HTTP 复用器（MUX）中，也就是路由</u>

#### 1. 安装到 Scheme

第一步，API 版本安装到 Scheme 中通常在引导过程的某个位置使用 init 函数实现。

在此项目中，安装的过程在：`pkg/apiserver/apiserver.go`

```go
import (
    ....
    "k8s.io/apimachinery/pkg/runtime"
    "k8s.io/apimachinery/pkg/runtime/serializer"

    "github.com/programming-kubernetes/pizza-apiserver/pkg/apis/restaurant/install"
)

var (
    Scheme = runtime.NewScheme()
    Codecs = serializer.NewCodecFactory(Scheme)
)

func init() {
    install.Install(Scheme)

    // we need to add the options to empty v1
    // TODO fix the server code to avoid this
    metav1.AddToGroupVersion(Scheme, schema.GroupVersion{Version: "v1"})

    // TODO: keep the generic API server from wanting this
    unversioned := schema.GroupVersion{Group: "", Version: "v1"}
    Scheme.AddUnversionedTypes(unversioned,
        &metav1.Status{},
        &metav1.APIVersions{},
        &metav1.APIGroupList{},
        &metav1.APIGroup{},
        &metav1.APIResourceList{},
    )
}
```

- install.Install(Scheme) 将内部版本、自定义版本通过 AddToScheme 函数添加到 Scheme 中

#### 2. 安装到 MUX 中

第二个步骤，把 API 组添加到 HTTP 复用器（MUX）中。安装过程在 `pkg/apiserver/apiserver.go`

```go
// New returns a new instance of CustomServer from the given config.
func (c completedConfig) New() (*CustomServer, error) {
    genericServer, err := c.GenericConfig.New("pizza-apiserver", genericapiserver.NewEmptyDelegate())
    if err != nil {
        return nil, err
    }

    s := &CustomServer{
        GenericAPIServer: genericServer,
    }

    apiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(restaurant.GroupName, Scheme, metav1.ParameterCodec, Codecs)

    v1alpha1storage := map[string]rest.Storage{}
    v1alpha1storage["pizzas"] = customregistry.RESTInPeace(pizzastorage.NewREST(Scheme, c.GenericConfig.RESTOptionsGetter))
    v1alpha1storage["toppings"] = customregistry.RESTInPeace(toppingstorage.NewREST(Scheme, c.GenericConfig.RESTOptionsGetter))
    apiGroupInfo.VersionedResourcesStorageMap["v1alpha1"] = v1alpha1storage

    v1beta1storage := map[string]rest.Storage{}
    v1beta1storage["pizzas"] = customregistry.RESTInPeace(pizzastorage.NewREST(Scheme, c.GenericConfig.RESTOptionsGetter))
    apiGroupInfo.VersionedResourcesStorageMap["v1beta1"] = v1beta1storage

    if err := s.GenericAPIServer.InstallAPIGroup(&apiGroupInfo); err != nil {
        return nil, err
    }

    return s, nil
}
```

- 安装的过程是通过 我们自定义 的 CustomServer 结构体中内嵌的通用的 API 服务器提供的，也就是 `genericapiserver.GenericAPIServer.InstallAPIGroup`，它可以为一个 API 组建立起完整的请求流程

- 唯一要做的就是定义一个 APIGroupInfo 对象
  
  - 在 APIGroupInfo 中添加我们自定义的注册表（也就是 REST 对象）。
  
  - 注册表是版本无关的，因为它直接操作内部对象，因此我们对每个版本调用的都是同一个注册表构造函数。

### 准入控制

从之前的图中也可以看到，每一个请求在经过反序列化、默认值处理、转成内部类型后，都会经过插件链处理，也就是经过准入控制处理，分为两类:

- 变更准入插件
  
  - 变更准入插件是<u>可以对源对象 进行修改的</u>
  
  - 变更阶段，<u>变更插件会被依次调用</u>

- 验证准入插件
  
  - 验证准入插件<u>不可以对源对象进行修改</u>
  
  - 验证阶段，验证插件都会被调用（<u>有可能是并发的调用</u>）

同一个准入插件可以既是变更插件，也是验证插件，也就是一个插件可以用两个函数同时实现变更和验证。

注意，自定义聚合 API 服务器的准入，与 kubernetes 的 webhook 准入插件有很大不同:

- 自定义聚合 API 服务器的准入需要操作内部类型

- webhook 准入插件基于外部类型实现，如果是变更 Webhook，还包含调用 webhook 和返回过程中的转换处理。

#### 1. 准入插件实现

要是实现一个准入插件需要实现下列接口:

- 准入插件的 Interface 接口

- MutationInterface 接口（可选）

- ValidationInterface 接口（可选）

这三个接口的定义在：`k8s.io/apiserver/pkg/admission/interfaces.go`

```go
// Operation 是为准入控制检查的资源操作类型
type Operation string

// Operation constants
const (
    Create  Operation = "CREATE"
    Update  Operation = "UPDATE"
    Delete  Operation = "DELETE"
    Connect Operation = "CONNECT"
)



// Interface is an abstract, pluggable interface for Admission Control decisions.
type Interface interface {
    // Handles returns true if this admission controller can handle the given operation
    // where operation can be one of CREATE, UPDATE, DELETE, or CONNECT
    Handles(operation Operation) bool
}

type MutationInterface interface {
    Interface

    // Admit makes an admission decision based on the request attributes
    Admit(a Attributes, o ObjectInterfaces) (err error)
}

// ValidationInterface is an abstract, pluggable interface for Admission Control decisions.
type ValidationInterface interface {
    Interface

    // Validate makes an admission decision based on the request attributes.  It is NOT allowed to mutate
    Validate(a Attributes, o ObjectInterfaces) (err error)
}
```

- Interface 接口的 Handles 是负责对操作进行过滤的

- 变更插件通过调用 Amit 实现

- 验证插件通过调用 Validate 实现

其中，ObjectInterfaces 提供了访问工具函数的途径，工具函数通常是由 Scheme 来实现的：

```go
type ObjectInterfaces interface {
    // GetObjectCreater is the ObjectCreator appropriate for the requested object.
    GetObjectCreater() runtime.ObjectCreater
    // GetObjectTyper is the ObjectTyper appropriate for the requested object.
    GetObjectTyper() runtime.ObjectTyper
    // GetObjectDefaulter is the ObjectDefaulter appropriate for the requested object.
    GetObjectDefaulter() runtime.ObjectDefaulter
    // GetObjectConvertor is the ObjectConvertor appropriate for the requested object.
    GetObjectConvertor() runtime.ObjectConvertor
}
```

传递给插件的属性 Attributes，通常会包含所有可以从请求中解析出来，并且实现深入的检查有用的信息：

```go
type Attributes interface {
    // GetName returns the name of the object as presented in the request.  On a CREATE operation, the client
    // may omit name and rely on the server to generate the name.  If that is the case, this method will return
    // the empty string
    GetName() string
    // GetNamespace is the namespace associated with the request (if any)
    GetNamespace() string
    // GetResource is the name of the resource being requested.  This is not the kind.  For example: pods
    GetResource() schema.GroupVersionResource
    // GetSubresource is the name of the subresource being requested.  This is a different resource, scoped to the parent resource, but it may have a different kind.
    // For instance, /pods has the resource "pods" and the kind "Pod", while /pods/foo/status has the resource "pods", the sub resource "status", and the kind "Pod"
    // (because status operates on pods). The binding resource for a pod though may be /pods/foo/binding, which has resource "pods", subresource "binding", and kind "Binding".
    GetSubresource() string
    // GetOperation is the operation being performed
    GetOperation() Operation
    // IsDryRun indicates that modifications will definitely not be persisted for this request. This is to prevent
    // admission controllers with side effects and a method of reconciliation from being overwhelmed.
    // However, a value of false for this does not mean that the modification will be persisted, because it
    // could still be rejected by a subsequent validation step.
    IsDryRun() bool
    // GetObject is the object from the incoming request prior to default values being applied
    GetObject() runtime.Object
    // GetOldObject is the existing object. Only populated for UPDATE requests.
    GetOldObject() runtime.Object
    // GetKind is the type of object being manipulated.  For example: Pod
    GetKind() schema.GroupVersionKind
    // GetUserInfo is information about the requesting user
    GetUserInfo() user.Info

    // AddAnnotation sets annotation according to key-value pair. The key should be qualified, e.g., podsecuritypolicy.admission.k8s.io/admit-policy, where
    // "podsecuritypolicy" is the name of the plugin, "admission.k8s.io" is the name of the organization, "admit-policy" is the key name.
    // An error is returned if the format of key is invalid. When trying to overwrite annotation with a new value, an error is returned.
    // Both ValidationInterface and MutationInterface are allowed to add Annotations.
    AddAnnotation(key, value string) error
}
```

注意：

- 变更插件 Admit 从 GetObject 返回的对象是允许变更的。验证插件不允许更改

- 变更和验证都允许调用 AddAnnotation 向 API 服务器输出的审计结果中添加注解。

- Admit 和 Validate 插件返回 非 nil 值会触发拒绝请求的操作。

准入插件必须实现 admission.Interface 接口中的 Handles 方法。而在同一个包`k8s.io/apiserver/pkg/admission/handler.go` 中，有一个工具结构叫 Handler，可以通过调用 NewHandler 来创建一个 Handler 实例，然后再自定义的准入插件嵌入这个 Handler 对象，来提供 Handles 方法的实现 （`pkg/admission/plugin/pizzatoppings/admission.go`）:

```go
type PizzaToppingsPlugin struct {
    *admission.Handler
    toppingLister listers.ToppingLister
}
```

admission.Handler 已经实现了 Handles 方法，因此，准入插件只需要实现 Admit 或者 validate 方法即可。

 准入插件，必须首先检查传入对象的 GroupVersionKind（GVK）是否合法（也就是是否是当前插件所关注的 GVK），如果不是直接进行下一个插件判断，完整的验证插件如下（`pkg/admission/plugin/pizzatoppings/admission.go`）

```go
func (d *PizzaToppingsPlugin) Validate(a admission.Attributes, _ admission.ObjectInterfaces) error {
    // 判断 GVK 是否合法
    if a.GetKind().GroupKind() != restaurant.Kind("Pizza") {
        return nil
    }

    // 等待 Informer
    if !d.WaitForReady() {
        return admission.NewForbidden(a, fmt.Errorf("not yet ready to handle request"))
    }

    // 获取对象，并验证
    obj := a.GetObject()
    pizza := obj.(*restaurant.Pizza)
    for _, top := range pizza.Spec.Toppings {
        if _, err := d.toppingLister.Get(top.Name); err != nil && errors.IsNotFound(err) {
            return admission.NewForbidden(
                a,
                fmt.Errorf("unknown topping: %s", top.Name),
            )
        }
    }

    return nil
}
```

一共有三个步骤：

- 检查传入的 GVK 是否正确

- 再 Informer 准备好之前，禁止访问

- 获取对象并验证的过程，该项目是，验证配料的 Informer 列表，保证披萨规格中提到的每种配料都在集群中

#### 2. 准入插件注册

准入插件需要注册，注册的方法是通过调用 Register 方法，如下（`pkg/admission/plugin/pizzatoppings/admission.go`）：

```go
func Register(plugins *admission.Plugins) {
    plugins.Register("PizzaToppings", func(config io.Reader) (admission.Interface, error) {
        return New()
    })
}
```

这个函数，最终会添加到 RecommendedOptions 的插件列表中(`pkg/cmd/server/start.go`):

```go
func (o *CustomServerOptions) Complete() error {
    // register admission plugins
    pizzatoppings.Register(o.RecommendedOptions.Admission.Plugins)

    // add admisison plugins to the RecommendedPluginOrder
    o.RecommendedOptions.Admission.RecommendedPluginOrder = append(o.RecommendedOptions.Admission.RecommendedPluginOrder, "PizzaToppings")

    return nil
}
```

- 首先调用 Register 函数注册插件，然后把插件添加到插件列表的结尾，注意插件的处理是有顺序的。

- 也可以把自定义插件插入到任何位置，不一定最后

#### 3. 准入插件的基础设施

准入插件长需要客户都安和 Informer 或其他资源来实现它们的处理逻辑，这些必须的资源可以在插件的初始化时准备好。

`k8s.io/apiserver/pkg/admission/initializer` 已经为我们提供了一些标准的插件初始化器，如果实现了相关方法，那么 apiserver 就会在插件初始化时，回调方法，使得插件可以使用对应的 client 或 informer 资源

```go
// WantsExternalKubeClientSet defines a function which sets external ClientSet for admission plugins that need it
type WantsExternalKubeClientSet interface {
    SetExternalKubeClientSet(kubernetes.Interface)
    admission.InitializationValidator
}

// WantsExternalKubeInformerFactory defines a function which sets InformerFactory for admission plugins that need it
type WantsExternalKubeInformerFactory interface {
    SetExternalKubeInformerFactory(informers.SharedInformerFactory)
    admission.InitializationValidator
}

// WantsAuthorizer defines a function which sets Authorizer for admission plugins that need it.
type WantsAuthorizer interface {
    SetAuthorizer(authorizer.Authorizer)
    admission.InitializationValidator
}
```

注意，准入插件还需要实现 admission.InitializationValidator 来进行最后的检查，确认插件配置正常（`k8s.io/apiserver/pkg/admission/interfaces.go`）： 

```go
// InitializationValidator holds ValidateInitialization functions, which are responsible for validation of initialized
// shared resources and should be implemented on admission plugins
type InitializationValidator interface {
    ValidateInitialization() error
}
```

除了标准初始化器，我们还想使用其他的客户端或者 Informer 资源，例如，该项目中需要使用 Topping 配料的 Informer。那么我们就需要自定义初始化器。初始化器中包含：

- 一个 Wants* 接口（例如，WantsRestaurantInformerFactory），这个接口应该有准入插件实现（`pkg/admission/custominitializer/restaurantinformer.go`）

```go
// WantsRestaurantInformerFactory defines a function which sets InformerFactory for admission plugins that need it
type WantsRestaurantInformerFactory interface {
    SetRestaurantInformerFactory(informers.SharedInformerFactory)
    admission.InitializationValidator
}
```

- 一个初始化器结构体，并且实现 admission.PluginInitializer 接口，也就是必须实现 Initialize 方法(`pkg/admission/custominitializer/restaurantinformer.go`)
  
  - Initialize 方法会检查传入的插件是否实现了相应的自定义初始器的 Wants* 接口。
  
  - 如果有，则调用相应方法
  
  - 自定义准入插件实现了 SetRestaurantInformerFactory  方法，用于初始化使用到相应的资源。在该函数中，使用了 HasSynced() 方法，表示当前 Informer 有没有注册成功，也就是在真正的准入插件逻辑中，一定要使用 WaitForReady() 方法，等待 Informer 完成。

```go
func (i restaurantInformerPluginInitializer) Initialize(plugin admission.Interface) {
    if wants, ok := plugin.(WantsRestaurantInformerFactory); ok {
        wants.SetRestaurantInformerFactory(i.informers)
    }
}
```

- 把初始化器的构造函数设置到 RecommendedOptions.ExtraAdmissionInitializers 中，实现初始化器的注册（`pkg/cmd/server/start.go`）：

```go
func (o *CustomServerOptions) Config() (*apiserver.Config, error) {
    // TODO have a "real" external address
    if err := o.RecommendedOptions.SecureServing.MaybeDefaultWithSelfSignedCerts("localhost", nil, []net.IP{net.ParseIP("127.0.0.1")}); err != nil {
        return nil, fmt.Errorf("error creating self-signed certificates: %v", err)
    }

    o.RecommendedOptions.ExtraAdmissionInitializers = func(c *genericapiserver.RecommendedConfig) ([]admission.PluginInitializer, error) {
        client, err := clientset.NewForConfig(c.LoopbackClientConfig)
        if err != nil {
            return nil, err
        }
        informerFactory := informers.NewSharedInformerFactory(client, c.LoopbackClientConfig.Timeout)
        o.SharedInformerFactory = informerFactory
        return []admission.PluginInitializer{custominitializer.New(informerFactory)}, nil
    }

    ....
}
```
