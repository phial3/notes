[TOC]

# 深入理解Kube-APIServer

## kube-Apiserver 架构

kube-apiserver是Kubernetes最重要的核心组件之一，主要提供以下的功能

- ++提供集群管理的 REST API 接口，包括认证授权、数据校验以及集群状态变更等++
- ++提供其他模块之间的数据交互和通信的枢纽(其他模块通过API Server查询或改数据，只有API Server才直接操作etcd)++

kube-apiserver 访问控制细节如下图：

![kube-apiserver-1]()

- panic recover：golang 的 panic 捕捉
- request-timeout：超时控制
- authentication：认证
- audit：审计日志
- impersonation：在 Request 中添加 impersonation Header，来模拟另一个用户的请求
- max-in-flight：最大并发请求数
- authorization：鉴权
- kube-aggregator & CRD：流量转发到自定义聚合 Apiserver 上
- resource handler：真正 request 的逻辑处理，包括解码、准入，写入etcd等。

## 认证

开启TLS时，所有的请求都需要首先认证。Kubernetes支持多种认证机制，并支持同时开启多个认证插件（只要有一个认证通过即可）。

如果认证成功，则用户的username会传入授权模块做进一步授权验证；而对于认证失败的请求则返回HTTP 401。

### 认证插件

- X509证书
  - 使用X509客户端证书只需要 API Server 启动时配置 --client-ca-file=SOMEFILE。
  - 在证书认证时，其CN域用作用户名，而组织机构域则用作group名。
- 静态Token文件
  - 使用静态Token文件认证只需要API Server启动时配置--token-auth-file=SOMEFILE。
  - 该文件为csv格式，每行至少包括三列token,username,user。例如：`id，token,user,uid,"group1,group2,group3”`
- 引导Token
  - 为了支持平滑地启动引导新的集群，Kubernetes 包含了一种动态管理的持有者令牌类型， 称作 启动引导令牌（Bootstrap
    Token）。
  - 这些令牌以 Secret 的形式保存在 kube-system 名字空间中，可以被动态管理和创建。
  - 控制器管理器包含的 TokenCleaner 控制器能够在启动引导令牌过期时将其删除。
  - 在使用kubeadm部署Kubernetes时，可通过kubeadm token list命令查询。
