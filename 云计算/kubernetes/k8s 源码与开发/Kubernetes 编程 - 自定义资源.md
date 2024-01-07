[TOC]

# Kubernetes 编程 - 自定义资源

## 概述

[Extend the Kubernetes API with CustomResourceDefinitions | Kubernetes](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/)

自定义资源定义（Custom Resource Definition，CRD），本身也是一种 Kubernetes 的资源，用来描述在当前集群中使用的自定义资源。

自定义资源（Custom Resource，CR），这就是对应自定义资源定义的具体某种类型，对应 GVK

例如：

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ats.cnat.programming-kubernetes.info
spec:
  group: cnat.programming-kubernetes.info
  names:
    kind: At
    plural: ats
    listKind: AtList
    singular: at
    shortNames:
      - at
  scope: Namespaced

  versions:
    - name: v1alpha1
      served: true
      storage: true
      additionalPrinterColumns:
        - jsonPath: .spec.schedule
          name: schedule
          type: string
        - jsonPath: .spec.command
          name: command
          type: string
        - jsonPath: .status.phase
          name: phase
          type: string
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                schedule:
                  type: string
                command:
                  type: string
                status:
                  type: object
                  properties:
                    phase:
                      type: string
```

- 创建后，会通过 apiextensions-apiserver 去检查新创建资源的名称，确认是否与其他资源名称发生冲突，以及它自身内部的定义是否一致。    

创建 CRD ：

```shell
root@k8s-master:~/demo/program_k8s/CRD# kubectl apply -f at_crd.yaml
customresourcedefinition.apiextensions.k8s.io/ats.cnat.programming-kubernetes.info created
```

查看 Kubernetes 中的 资源列表：

```yaml
root@k8s-master:~/demo/program_k8s/CRD# kubectl api-resources  | grep ats
ats                                                                               cnat.programming-kubernetes.info/v1alpha1   true         At
```

下面是 CR：

```yaml
apiVersion: cnat.programming-kubernetes.info/v1alpha1
kind: At
metadata:
  name: example-at
spec:
  schedule: '2022-11-22T15:00:00Z'
  status:
    phase: "pending"
```

创建 CR：

```shell
root@k8s-master:~/demo/program_k8s/CRD# kubectl apply -f at_cr.yaml
at.cnat.programming-kubernetes.info/example-at created
```

查看创建的对应的资源：

```shell
root@k8s-master:~/demo/program_k8s/CRD# kubectl get ats
NAME         SCHEDULE               COMMAND   PHASE
example-at   2022-11-22T15:00:00Z
```

那么 client-go 是如何发现这些新创建的信息呢？

按照传统的思路，获取资源不存在时，会返回 404，但现在整个服务发现的流程就是：

- RESTMapper 通过 GVR 也就是 来获取到 GVK

- GVK 再通过 Scheme 拿到详细的信息

![k8s_client-go_object_trans](E:\notes\云计算\pic\k8s开发\k8s_client-go_object_trans.PNG)

## 子资源

子资源：其实是一个特殊的 HTTP 端点（也就是 restful 的一个地址），通过在普通资源的 HTTP 路径后加入后缀得到。例如：

- `/api/v1/namespace/namespaces/pods/name/logs`

- `/api/v1/namespace/namespaces/pods/name/portforward`

- `/api/v1/namespace/namespaces/pods/name/exec`

- `/api/v1/namespace/namespaces/pods/name/status`

自定义资源支持两种子资源：

- `/status`

- `/scale`

### 1. 状态子资源

**`/status` 子资源用于把用户提供的 CR 实例的规格（Spec） 与控制器提供的状态（Status）分离。**

- 用户一边拿不会更改状态 status

- 控制器不应该更新资源的规格 spec

如果一个资源（包括自定义资源）具备了 `/status` 子资源，会有一些变化：

- <u>在主 HTTP 端点上创建或更新资源时（创建时 status 字段会被直接丢弃），会忽略 status 字段</u>

- 而<u>对 `/status` 子资源的任何操作都会忽略除了 status 以外的值，在 `/status` 接口上不能进行创建资源的操作</u>

- <u>当 metadata 和 status 以外的字段发生变化，也就是 spec 规格发生变化，主资源会递增 metadata.generation 字段的值，触发控制器的动作</u>。

`/status` 子资源的使用一般在`spec.versions[].subresources` 字段中，例如：

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ats.cnat.programming-kubernetes.info
spec:
......

  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
    - name: v1beta1
      served: true
      storage: true
```

这样做的好处是，不会影响 v1beta1 版本的状态。

注意：

主资源和子资源，也就是 status 和 spec 共享相同的资源版本，在存储层上，spec 和 status 其实是相同的一份数据，没有分离。

### 2. 扩缩容子资源

`/scale` 子资源：用于查看或修改资源中指定的副本数。主要用于类似 Kubernetes 中 Deployment 和 ReplicSet 这样的具有副本数的资源，通过 `/scale` 子资源可以进行扩容和缩容。

`kubectl scale --replicas=3 [Your-Custom-Resource]` 命令调用的就是 `/scale` 子资源。

原理，其实就是通过 `/status` 可以读取到标签选择器的值，然后控制器对 满足选择器的 pod 进行计数。

对应的 `/scale` 子资源在 CRD 中的 yaml 定义，在代码 `k8s.io/api/autoscaling/v1` 定义：

```go
// k8s.io/api/autoscaling/v1/types.go
type Scale struct {
    metav1.TypeMeta `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty" protobuf:"bytes,1,opt,name=metadata"`
    Spec ScaleSpec `json:"spec,omitempty" protobuf:"bytes,2,opt,name=spec"`
    Status ScaleStatus `json:"status,omitempty" protobuf:"bytes,3,opt,name=status"`
}

// k8s.io/api/autoscaling/v1/types.go
// ScaleSpec describes the attributes of a scale subresource.
type ScaleSpec struct {
    // desired number of instances for the scaled object.
    // +optional
    Replicas int32 `json:"replicas,omitempty" protobuf:"varint,1,opt,name=replicas"`
}

// k8s.io/api/autoscaling/v1/types.go
// ScaleStatus represents the current status of a scale subresource.
type ScaleStatus struct {
    // actual number of observed instances of the scaled object.
    Replicas int32 `json:"replicas" protobuf:"varint,1,opt,name=replicas"`

    // label query over pods that should match the replicas count. This is same
    // as the label selector but in the string format to avoid introspection
    // by clients. The string will be in the same format as the query-param syntax.
    // More info about label selectors: http://kubernetes.io/docs/user-guide/labels#label-selectors
    // +optional
    Selector string `json:"selector,omitempty" protobuf:"bytes,2,opt,name=selector"`
}
```

主要由两部分组成：

- spec：由 replicas 组成（规格）

- status：由 replicas 和 selector 组成（控制器状态）

在 CRD 的 yaml 文件中启用 `/scale` 子资源需要定义下面三个参数：

- `specReplicasPath`: 必填，对应 `scale.spec.replicas` 的 JsonPath

- `statusReplicasPath`：必填，对应 `scale.spec.status` 的 JsonPath

- `labelSelectorPath`：可选，对应 `scale.spec.selector` 的 JsonPath，它必须设置为与 HPA 一起使用。

具体实例如下：

```yaml
      subresources:
        # status enables the status subresource.
        status: {}
        # scale enables the scale subresource.
        scale:
          # specReplicasPath defines the JSONPath inside of a custom resource that corresponds to Scale.Spec.Replicas.
          specReplicasPath: .spec.replicas
          # statusReplicasPath defines the JSONPath inside of a custom resource that corresponds to Scale.Status.Replicas.
          statusReplicasPath: .status.replicas
          # labelSelectorPath defines the JSONPath inside of a custom resource that corresponds to Scale.Status.Selector.
          labelSelectorPath: .status.labelSelector
```

## 动态客户端与强类型客户端

### 1. 动态客户端

`k8s.io/client-go/dynamic` **提供的动态客户端，对 GVK 完全无感知**。

使用如下：

```go
    client, err := dynamic.NewForConfig(config)
    gvr := schema.GroupVersionResource{
        Group: "apps",
        Version: "v1",
        Resource: "deployments",
    }
    unstructured, err := client.Resource(gvr).Namespace("kubesphere-system").Get(context.Background(), "ks-apiserver", metav1.GetOptions{})
```

- 最后一行就返回了一个名为 ks-apiserver 的 deployment 对象，但注意，这里返回的类型是 `*unstructured.Unstructured` 类型

- `Unstructured` 对象是 `k8s.io/apimachinery` 中的一个基础类型

- `Unstructed` 其实就是对 `json.Unmarshal` 及其输出的一个封装。

- `Unstructured struct` 非结构化数据结构，其实很简单，就是对 json 格式数据结构封装

`unstructured.Unstructured` 的定义代码如下（`k8s.io/client-go/dynamic/unstructured.go` 和 `k8s.io/client-go/dynamic/unstructured.go_list`）：

```go
// unstructed.go
type Unstructured struct {
    // Object is a JSON compatible map with string, float, int, bool, []interface{}, or
    // map[string]interface{}
    // children.
    Object map[string]interface{}
}

// unstructed_list.go
type UnstructuredList struct {
    Object map[string]interface{}

    // Items is a list of unstructured objects.
    Items []Unstructured `json:"items"`
}
```

- 其实说白了，Unstructured 类型就是一个 map 对象，用来存放 key-value 的 json.Unmarshal 的反序列化后的数据：
  
  - 对象通过 `map[string]interface{}` 表示
  
  - 数组通过 `[]Unstructured`
  
  - 基础数据结构，还是 string、bool、int 等

如何将一个 `Unstructured` 的资源类型，序列化成 Json 格式？或者反向转化呢？需要 用到：

- `k8s.io/apimachinery/pkg/runtime.Encoder`
- `k8s.io/apimachinery/pkg/runtime.Decoder`
- `k8s.io/apimachinery/pkg/runtime.Serializer`
- `k8s.io/apimachinery/pkg/runtime.Codec`

实例：

```go
package main

import (
    "fmt"
    "reflect"

    "k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
    "k8s.io/apimachinery/pkg/runtime"
)

func main() {
    uConfigMap := unstructured.Unstructured{
        Object: map[string]interface{}{
            "apiVersion": "v1",
            "kind":       "ConfigMap",
            "metadata": map[string]interface{}{
                "creationTimestamp": nil,
                "namespace":         "default",
                "name":              "my-configmap",
            },
            "data": map[string]interface{}{
                "foo": "bar",
            },
        },
    }

    // Unstructured -> JSON (Option I)
    //   - Despite the name, `UnstructuredJSONScheme` is not a scheme but a codec
    //   - runtime.Encode() is just a helper function to invoke UnstructuredJSONScheme.Encode()
    //   - UnstructuredJSONScheme.Encode() is needed because the unstructured instance can be
    //     either a single object, a list, or an unknown runtime object, so some amount of
    //     preprocessing is required before passing the data to json.Marshal()
    //   - Usage example: dynamic client (client-go/dynamic.Interface)
    bytes, err := runtime.Encode(unstructured.UnstructuredJSONScheme, &uConfigMap)
    fmt.Println("Serialized (option I)", string(bytes))

    // Unstructured -> JSON (Option II)
    //   - This is just a handy shortcut for the above code.
    bytes, err = uConfigMap.MarshalJSON()
    if err != nil {
        panic(err.Error())
    }
    fmt.Println("Serialized (option II)", string(bytes))

    // JSON -> Unstructured (Option I)
    //   - Usage example: dynamic client (client-go/dynamic.Interface)
    obj1, err := runtime.Decode(unstructured.UnstructuredJSONScheme, bytes)
    if err != nil {
        panic(err.Error())
    }

    // JSON -> Unstructured (Option II)
    //   - This is just a handy shortcut for the above code.
    obj2 := &unstructured.Unstructured{}
    err = obj2.UnmarshalJSON(bytes)
    if err != nil {
        panic(err.Error())
    }
    if !reflect.DeepEqual(obj1, obj2) {
        panic("Unexpected configmap data")
    }
}
```

而 `Unstructured` 有一个 `UnstructuredContent` 方法，提供了访问 `Unstructured` 对象内部数据的能力，也就是返回 `Unstructured` 中的 `Unstructured.Object` Map 数据对象

此外同一个包中（`k8s.io/apimachinery/pkg/apis/meta/v1/unstructured/helpers.go`）还有一些辅助工具可以获取相关的字段值。

例如，获取 unstructured 结构中的具体某个路径下的值，这里是 `.metadata.name`

```go
package main

import "k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"


func main() {
    ...
    name, found, err := unstructured.NestedString(u.Object, "metadata", "name")
}
```

获取特定类型的字段值的方法还有很多，例如：

- NestedString

- NestedBool

- NestedFloat64

- ...

设置指定字段的value值时有一个通用的方法：SetNestedField

### 2. 强类型客户端

强类型客户端，不适用 `map[string]interface{}` 这样的通用数据结构，而是为每种 GVK 都采用不同的专用的 Go 类型。

强类型，例如 Deployments 结构（）：

```go
type Deployment struct {
    metav1.TypeMeta `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty" protobuf:"bytes,1,opt,name=metadata"`

    Spec DeploymentSpec `json:"spec,omitempty" protobuf:"bytes,2,opt,name=spec"`

    Status DeploymentStatus `json:"status,omitempty" protobuf:"bytes,3,opt,name=status"`
}
```

- 其实很简单，就这四个字段域

- 其中 TypeMeta 和 ObjectMeata 已经在 apimachinery 包中做了介绍，其实就是 基本属性（Apiversion、Kind） 和 元数据属性（Metadata）

- 主要区别在于 不同类型的 Spec 属性不同。开发时注意，Spec 和 Status 属性是需要添加的。 

这些强数据类型，都是通过 注释标签，进行自动代码生成的。

之前说到的 clientset 其实就是一个强类型的客户端。

例如，Deployment

```go
// k8s.io/client-go/kubernetes/typed/apps/v1/deployment.go
type DeploymentsGetter interface {
    Deployments(namespace string) DeploymentInterface
}

// DeploymentInterface has methods to work with Deployment resources.
type DeploymentInterface interface {
    Create(ctx context.Context, deployment *v1.Deployment, opts metav1.CreateOptions) (*v1.Deployment, error)
    Update(ctx context.Context, deployment *v1.Deployment, opts metav1.UpdateOptions) (*v1.Deployment, error)
    UpdateStatus(ctx context.Context, deployment *v1.Deployment, opts metav1.UpdateOptions) (*v1.Deployment, error)
    Delete(ctx context.Context, name string, opts metav1.DeleteOptions) error
    DeleteCollection(ctx context.Context, opts metav1.DeleteOptions, listOpts metav1.ListOptions) error
    Get(ctx context.Context, name string, opts metav1.GetOptions) (*v1.Deployment, error)
    List(ctx context.Context, opts metav1.ListOptions) (*v1.DeploymentList, error)
    Watch(ctx context.Context, opts metav1.ListOptions) (watch.Interface, error)
    Patch(ctx context.Context, name string, pt types.PatchType, data []byte, opts metav1.PatchOptions, subresources ...string) (result *v1.Deployment, err error)
    Apply(ctx context.Context, deployment *appsv1.DeploymentApplyConfiguration, opts metav1.ApplyOptions) (result *v1.Deployment, err error)
    ApplyStatus(ctx context.Context, deployment *appsv1.DeploymentApplyConfiguration, opts metav1.ApplyOptions) (result *v1.Deployment, err error)
    GetScale(ctx context.Context, deploymentName string, options metav1.GetOptions) (*autoscalingv1.Scale, error)
    UpdateScale(ctx context.Context, deploymentName string, scale *autoscalingv1.Scale, opts metav1.UpdateOptions) (*autoscalingv1.Scale, error)
    ApplyScale(ctx context.Context, deploymentName string, scale *applyconfigurationsautoscalingv1.ScaleApplyConfiguration, opts metav1.ApplyOptions) (*autoscalingv1.Scale, error)

    DeploymentExpansion
}

// deployments implements DeploymentInterface
type deployments struct {
    client rest.Interface
    ns     string
}
```

- 这就是代码生成器自动生成的 deployment 类型，强类型客户端代码生成如下：

```go
// k8s.io/client-go/kubernetes/typed/apps/v1/apps_client.go
type AppsV1Interface interface {
    RESTClient() rest.Interface
    ControllerRevisionsGetter
    DaemonSetsGetter
    DeploymentsGetter
    ReplicaSetsGetter
    StatefulSetsGetter
}

// AppsV1Client is used to interact with features provided by the apps group.
type AppsV1Client struct {
    restClient rest.Interface
}
```

- 其实就是对应的 GV （GroupVersion）关联上对应的 Resource DeploymentsGetter

- 最终通过 ClientSet 强类型客户端获取对应资源就变成：

```go
clientset, _ := kubernetes.NewForConfig(config)
deployments := clientset.AppsV1().Deployments("default")
deploy, err := deployments.Get(context.Background(), "nginx", metav1.GetOptions{})
```

这就是强类型客户端。
