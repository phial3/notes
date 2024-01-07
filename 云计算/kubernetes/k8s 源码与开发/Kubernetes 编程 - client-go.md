[TOC]

# Kubernetes 编程 - client-go

## client-go

### client-go、api、apimachinery

使用 k8s 相关 sdk 做二次开发时，经常用到 apimachinery、api、client-go 这三个库，之间的依赖关系如下：

- apimachinery 是最基础的库，包括核心的数据结构，比如 Scheme、Group、Version、Kind、Resource，以及排列组合出来的 常用的GVK、GV、GK、GVR等等，再就是编码、解码等操作
- api 库，这个库依赖 apimachinery，提供了k8s的内置资源，以及注册到 Scheme 的接口，这些资源比如：Pod、Service、Deployment、Namespace
- client-go 库，这个库依赖前两个库，提供了访问k8s 内置资源的 sdk，最常用的就是 clientSet。底层通过 http 请求访问k8s 的 api-server，从etcd获取资源信息

在剖析 client-go 本身之前，了解它的两个主要依赖项——  [`k8s.io/api`](https://github.com/kubernetes/api) 和 [`k8s.io/apimachinery`](https://github.com/kubernetes/apimachinery)  模块可能是个好主意。这两个模块被分离出来是有原因的——它们<u>不仅可以被客户端使用，也可以在服务器端使用，或者被任何其他处理 Kubernetes 对象的软件使用</u>。

#### 1. API Resources, Kinds, 和 Objects

理解下面这三个概念是很关键的：

- **Resource Type** - 也就是通过 Kubernetes API endpoint 提供的实体，供客户端调用，这里表示的<u>一类资源</u>。: `pods`, `deployments`, `configmaps` 等.
- **API Group** - *resource types* 资源类型，被组织成的一个个<u>逻辑分组</u>: `apps/v1`, `batch/v1`, `storage.k8s.io/v1beta1` 等.
- **Object** - a resource instance - 每个 API endpoint 处理某种资源类型的对象，也就是<u>资源的实例对象</u>.
- **Kind** - 又名 object schema， API 返回或接受的每个对象都必须符合的 object schema - 这里表示<u>某类资源的具体 schema 定义</u>: `Pod`, `Deployment`, `ConfigMap` 等.

下面是一个 Kubernetes 中的 API Resources 的大概情况：

![k8s_apis_info](E:\notes\云计算\pic\k8s开发\k8s_apis_info.PNG)

主要分为三类：

- kubernetes 内建的资源，包括 `pod`, `svc`, `crds`, 这里的crd表示的是 `customresourcedefintions`

- Custom Resource，包括了 crd 的具体某一类资源

- Aggregated Api（apiserver），扩展 Apiserver 的接口
1. **Resources and Verbs**

restful 资源接口与 Method，**Kubernetes API endpoints 被命名为资源类型（Resouce type）**，以避免与资源实例（Object）产生歧义。

可以通过 `kubectl api-resouces -o wide` 查看所有的 资源类型。

```shell
root@k8s-master:~# kubectl api-resources -o wide
NAME                              SHORTNAMES                                      APIVERSION                             NAMESPACED   KIND                             VERBS
bindings                                                                          v1                                     true         Binding                          [create]
componentstatuses                 cs                                              v1                                     false        ComponentStatus                  [get list]
configmaps                        cm                                              v1                                     true         ConfigMap                        [create delete deletecollection get list patch update watch]
endpoints                         ep                                              v1                                     true         Endpoints                        [create delete deletecollection get list patch update watch]
events                            ev                                              v1                                     true         Event                            [create delete deletecollection get list patch update watch]
limitranges                       limits                                          v1                                     true         LimitRange                       [create delete deletecollection get list patch update watch]
namespaces                        ns                                              v1                                     false        Namespace                        [create delete get list patch update watch]
nodes                             no                                              v1                                     false        Node                             [create delete deletecollection get list patch update watch]
persistentvolumeclaims            pvc                                             v1                                     true         PersistentVolumeClaim            [create delete deletecollection get list patch update watch]
persistentvolumes                 pv                                              v1                                     false        PersistentVolume                 [create delete deletecollection get list patch update watch]
pods                              po                                              v1                                     true         Pod                              [create delete deletecollection get list patch update watch]

......
```

如果想要查看 api-resources 命令具体是怎么构建的，都调用了哪些 api，可以采用 `kubectl api-resources -v 6` 来查看：

```shell
root@k8s-master:~# kubectl api-resources -v 6
I1121 07:19:49.953180  833008 loader.go:372] Config loaded from file:  /root/.kube/config
I1121 07:19:49.961969  833008 round_trippers.go:553] GET https://10.0.0.105:6443/api?timeout=32s 200 OK in 7 milliseconds
I1121 07:19:49.966532  833008 round_trippers.go:553] GET https://10.0.0.105:6443/apis?timeout=32s 200 OK in 1 milliseconds
I1121 07:19:49.972025  833008 round_trippers.go:553] GET https://10.0.0.105:6443/apis/notification.kubesphere.io/v2beta1?timeout=32s 200 OK in 1 milliseconds
I1121 07:19:49.972667  833008 round_trippers.go:553] GET https://10.0.0.105:6443/apis/autoscaling/v2?timeout=32s 200 OK in 2 milliseconds
I1121 07:19:49.973303  833008 round_trippers.go:553] GET https://10.0.0.105:6443/apis/events.k8s.io/v1?timeout=32s 200 OK in 2 milliseconds
I1121 07:19:49.974760  833008 round_trippers.go:553] GET https://10.0.0.105:6443/api/v1?timeout=32s 200 OK in 3 milliseconds
I1121 07:19:49.975142  833008 round_trippers.go:553] GET https://10.0.0.105:6443/apis/authorization.k8s.io/v1?timeout=32s 200 OK in 4 milliseconds
I1121 07:19:49.975270  833008 round_trippers.go:553] GET https://10.0.0.105:6443/apis/apiregistration.k8s.io/v1?timeout=32s 200 OK in 4 milliseconds
I1121 07:19:49.975622  833008 round_trippers.go:553] GET https://10.0.0.105:6443/apis/authentication.k8s.io/v1?timeout=32s 200 OK in 4 milliseconds
I1121 07:19:49.979060  833008 round_trippers.go:553] GET https://10.0.0.105:6443/apis/apps/v1?timeout=32s 200 OK in 7 milliseconds
I1121 07:19:49.986431  833008 round_trippers.go:553] GET https://10.0.0.105:6443/apis/scheduling.k8s.io/v1?timeout=32s 200 OK in 13 milliseconds
I1121 07:19:49.986559  833008 round_trippers.go:553] GET https://10.0.0.105:6443/apis/discovery.k8s.io/v1?timeout=32s 200 OK in 13 milliseconds
I1121 07:19:49.986574  833008 round_trippers.go:553] GET https://10.0.0.105:6443/apis/cluster.kubesphere.io/v1alpha1?timeout=32s 200 OK in 13 milliseconds

......
```

注意：

- 所有的逻辑分组，Group 都是在 `/apis/<group-name>` 路径下

- 有一个特例，那就是 `/api` 这个是 kubernetes 遗留的问题，成为 Core 分组

如果想要调用这些 api ，那么也很简单：

```shell
# to bypass the auth step in subsequent queries:
$ kubectl proxy --port=8080 &

# List all known API paths
$ curl http://localhost:8080/
# List known versions of the `core` group
$ curl http://localhost:8080/api
# List known resources of the `core/v1` group
$ curl http://localhost:8080/api/v1
# Get a particular Pod resource
$ curl http://localhost:8080/api/v1/namespaces/default/pods/sleep-7c7db887d8-dkkcg

# List known groups (all but `core`)
$ curl http://localhost:8080/apis
# List known versions of the `apps` group 
$ curl http://localhost:8080/apis/apps
# List known resources of the `apps/v1` group
$ curl http://localhost:8080/apis/apps/v1
# Get a particular Deployment resource
$ curl http://localhost:8080/apis/apps/v1/namespaces/default/deployments/sleep
```

而对于 HTTP 请求的 Method verb：

- GET /<resourceNamePlural> - **Retrieve** a list of type <resourceName>, e.g. GET /pods returns a list of Pods.

- POST /<resourceNamePlural> - **Create** a new resource from the JSON object provided by the client.

- GET /<resourceNamePlural>/<name> - **Retrieves a single resource** with the given name, e.g. GET /pods/first returns a Pod named 'first'. Should be constant time, and the resource should be bounded in size.

- DELETE /<resourceNamePlural>/<name> -** Delete the single resource** with the given name. DeleteOptions may specify gracePeriodSeconds, the optional duration in seconds before the object should be deleted. Individual kinds may declare fields which provide a default grace period, and different kinds may have differing kind-wide default grace periods. A user provided grace period overrides a default grace period, including the zero grace period ("now").

- DELETE /<resourceNamePlural> - **Deletes a list of type** <resourceName>, e.g. DELETE /pods a list of Pods.

- PUT /<resourceNamePlural>/<name> - **Update or create the resource** with the given name with the JSON object provided by the client.

- PATCH /<resourceNamePlural>/<name> - **Selectively modify the specified fields of the resource**. See more information below.

- GET /<resourceNamePlural>?watch=true - **Receive a stream of JSON objects corresponding to changes made to any resource of the given kind over time**.
2. **Kinds 又名 object schema**

Kind 其实就是每个资源的 schema 定义，例如：

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata

...
```

3. **Kubernetes Objects**

Kinds 是定义，Objects 表示的是资源的实例对象，在 golang 中表示的就是 结构体实例，而在 etcd 中存储的就是一个个 json 文件。

不同种类的具体阶段如下图：

![k8s_apis_stage](E:\notes\云计算\pic\k8s开发\k8s_apis_stage.PNG)

#### 2. k8s.io/api

Kubernetes 中的 Pod、Deployment、ConfigMap 的 k8s 层面的结构体就是在 k8s.io/api 包中定义的。

例如：

```go
package main

import (
    "fmt"

    appsv1 "k8s.io/api/apps/v1"
    corev1 "k8s.io/api/core/v1"
)

func main() {
    deployment := appsv1.Deployment{
        Spec: appsv1.DeploymentSpec{
            Template: corev1.PodTemplateSpec{
                Spec: corev1.PodSpec{
                    Containers: []corev1.Container{
                        {Name: "web", Image: "nginx:1.21"},
                    },
                },
            },
        },
    }

    fmt.Printf("%#v", &deployment)
}
```

k8s.io/api 包定义了 json 和 protobuf 两种类型的编码格式：

- json 格式是通用的编码格式

- 自定义资源对象，不支持 protocol buffers 编码格式

#### 3. k8s.io/apimachinery

虽然 k8s.io/api 模块专注于具体的高级类型，如 Deployments、Secrets 或 Pod，但 **k8s.io/apimachinery 是低级但更通用的数据结构**。例如，Kubernetes 对象的所有这些公共属性：apiVersion、kind、name、uid、ownerReferences、creationTimestamp 等。

k8s.io/apimachinery/pkg/apis/meta 包定义了两个方便的结构：

- TypeMeta

- ObjectMeta

它们<u>可以嵌入到用户定义的结构中，使其看起来很像任何其他 Kubernetes 对象</u>。

此外，TypeMeta 和 ObjectMeta 结构实现了

- meta.Type 接口 

- meta.Object 接口

<u>可用于以通用方式指向任何兼容对象</u>。

k8s.io/apimachinery 和 k8s.io/api 的关系如下图：

![k8s_apimachinery](E:\notes\云计算\pic\k8s开发\k8s_apimachinery.PNG)

k8s.io/apimachinery 中一些有用的类型：

-    `pkg/runtime/interfaces.go` 中的 Object 接口，一个 runtime.Object 实例可以指向任何具有 kind 属性的对象定义如下：

```go
type Object interface {
    GetObjectKind() schema.ObjectKind
    DeepCopyObject() Object
}
```

- `pkg/apis/meta/v1/types.go` 中的 `PartialObjectMetadata` 结构体，meta.TypeMeta 和 meta.ObjectMeta 的组合作为用元数据表示任何对象的通用方式。

- `pkg/apis/meta/v1/types.go` 中的 `APIVersions`, `APIGroupList`, `APIGroup` 结构体， 这些结构常用来表示  Kubernetes API resources， 但不能作为 Kubernetes Object。例如，它们有 `kind` and `apiVersion` 属性，但是没有对象的元数据。

- `pkg/apis/meta/v1/types.go` 中的 `GetOptions`, `ListOptions`, `UpdateOptions` 等，这些结构表示相应客户端对资源的操作的参数。

- `pkg/apis/meta/v1/types.go` 中的 `GroupKind`, `GroupVersionKind`, `GroupResource`, [`GroupVersionResource`](https://github.com/kubernetes/apimachinery/blob/ea11419e6b79342dfdb688604cedc8c6ac84c5c3/pkg/runtime/schema/group_version.go#L96), 等结构体， 简单的数据传输对象——包含组、版本、种类或资源字符串的元组。

##### REST 映射

首先搞清楚两个概念：

- **GVK（GroupVersionKind）**
  
  - 每一种 GVK 对应一种 Go 语言的类型，但一种 Go 语言类型可以用于多个 GVK。
  
  - 采用 GVK 获取到一个具体的 存储结构体，也就是 GVK 的三个信息（group/verion/kind) 确定一个 Go type（结构体）
  
  - 编写 yaml 过程中，我们会写 apiversion 和 kind，其实就是 GVK
  
  - **GVK 不能与 HTTP 路径一一对应**。
  
  - 很多 GVK 都用于访问该型别对象的 HTTP REST 端点，但有些也没有对应 HTTP 端点，例如 `admission.k8s.io/v1beta1.AdmissionReview`，用于传递 Webhook 调用。
  
  - 还有些 GVK 可能会从多个 HTTP 端点返回，例如 `meta.k8s.io/v1.Status`

- **GVR（GroupVersionResource）**
  
  - **每一个 GVR 都对应一个 HTTP 路径**
  
  - GVR 用于表示 Kubernetes 的 Rest 端点
  
  - 例如，`apps/v1.deployments` 这个 GVK 映射为 GVR 是 `/apis/apps/v1/namespaces/NAMESPACE/deployments`
  
  - 客户端使用 这种映射来构造 HTTP 路径，以便访问 GVR

**GVK 与 GVR 之间的映射关系被称为 REST 映射。**

GVR 是由 GVK 转化而来 —— **通过REST映射的RESTMappers实现**

RestMapper 是一个 Golang 的接口，用于请求一个 GVK 所对应的 GVR。而在 client-go 中，调用的其实就是 `k8s.io/apimachinery` 中的 

```go
// k8s.io/client-go/restmapper/shortcut.go
type shortcutExpander struct {
    RESTMapper meta.RESTMapper
    discoveryClient discovery.DiscoveryInterface
}


// RESTMapping fulfills meta.RESTMapper
func (e shortcutExpander) RESTMapping(gk schema.GroupKind, versions ...string) (*meta.RESTMapping, error) {
    return e.RESTMapper.RESTMapping(gk, versions...)
}
```

在 `k8s.io/apimachinery` 中的 RESTMapping  可以指定一个 GVR（例如 daemonset 的这个例子），然后它返回对应的 GVK 以及支持的操作等。

```go
// k8s.io/apimachinery/pkg/api/meta/interfaces.go

type RESTMapper interface {
    // KindFor takes a partial resource and returns the single match.  Returns an error if there are multiple matches
    KindFor(resource schema.GroupVersionResource) (schema.GroupVersionKind, error)

    // KindsFor takes a partial resource and returns the list of potential kinds in priority order
    KindsFor(resource schema.GroupVersionResource) ([]schema.GroupVersionKind, error)

    // ResourceFor takes a partial resource and returns the single match.  Returns an error if there are multiple matches
    ResourceFor(input schema.GroupVersionResource) (schema.GroupVersionResource, error)

    // ResourcesFor takes a partial resource and returns the list of potential resource in priority order
    ResourcesFor(input schema.GroupVersionResource) ([]schema.GroupVersionResource, error)

    // RESTMapping identifies a preferred resource mapping for the provided group kind.
    RESTMapping(gk schema.GroupKind, versions ...string) (*RESTMapping, error)
    // RESTMappings returns all resource mappings for the provided group kind if no
    // version search is provided. Otherwise identifies a preferred resource mapping for
    // the provided version(s).
    RESTMappings(gk schema.GroupKind, versions ...string) ([]*RESTMapping, error)

    ResourceSingularizer(resource string) (singular string, err error)
}
```

这些函数就是将 GVK 与 GVR 相互转换：

- GVK -> GVR : ResourceFor, ResourcesFor

- GVR -> GVK : KindFor, KindsFor

注意，上面只是定义了接口中的一些方法，具体如何实现这些转换呢？**对于客户端来说，最重要的实现是基于发现机制的 `NewDeferredDiscoveryRESTMapper`**。

- 它使用来自 Kubernetes API 服务器的发现信息动态的创建 REST 映射。

- 也可以支持非核心的资源，例如自定义资源（CRD）

##### Scheme

scheme 位于 `k8s.io/apimachinery/pkg/runtime` 中，schme 的主要功能是将 Golang 类型与可能的 GVK 之间建立映射。

**Scheme 是通过 Go 语言中的反射机制来返回某个对象的类型，并将其与一个注册过该类型的 GVK 进行映射。**

scheme 的实现注册通过调用：

```go
scheme.AddKnownTypes(schema.GroupVersion{Group: "foo", Version: "v1beta1"}, &testapigroup.Carp{})
```

在 `k8s.io/apimachinery` 中的实现(使用反射机制)为：

```go
// AddKnownTypes registers all types passed in 'types' as being members of version 'version'.
// All objects passed to types should be pointers to structs. The name that go reports for
// the struct becomes the "kind" field when encoding. Version may not be empty - use the
// APIVersionInternal constant if you have a type that does not have a formal version.
func (s *Scheme) AddKnownTypes(gv schema.GroupVersion, types ...Object) {
    s.addObservedVersion(gv)
    for _, obj := range types {
        t := reflect.TypeOf(obj)
        if t.Kind() != reflect.Pointer {
            panic("All types must be pointers to structs.")
        }
        t = t.Elem()
        s.AddKnownTypeWithName(gv.WithKind(t.Name()), obj)
    }
}
```

## client-go 中的 Kubernetes 对象

上面介绍过 `k8s.io/apimachinery/pkg/runtime` 中的 Object 对象，Kubernetes 的所有对象都实现了 `runtime.Object` 接口：

```go
// Object interface must be supported by all API types registered with Scheme. Since objects in a scheme are
// expected to be serialized to the wire, the interface an Object must provide to the Scheme allows
// serializers to set the kind, version, and group the object is represented as. An Object may choose
// to return a no-op ObjectKindAccessor in cases where it is not expected to be serialized.
type Object interface {
    GetObjectKind() schema.ObjectKind
    DeepCopyObject() Object
}
```

 而上面 Object 接口中，又包含了获取 ObjectKind 接口，`schema.ObjectKind` 是另一个接口，位于`k8s.io/apimachinery/pkg/runtime/schema` 包中：

```go
// All objects that are serialized from a Scheme encode their type information. This interface is used
// by serialization to set type information from the Scheme onto the serialized version of an object.
// For objects that cannot be serialized or have unique requirements, this interface may be a no-op.
type ObjectKind interface {
    // SetGroupVersionKind sets or clears the intended serialized kind of an object. Passing kind nil
    // should clear the current setting.
    SetGroupVersionKind(kind GroupVersionKind)
    // GroupVersionKind returns the stored group, version, and kind of an object, or an empty struct
    // if the object does not expose or provide these fields.
    GroupVersionKind() GroupVersionKind
}
```

ObjectKind 主要：

- 用来设置或者清除，序列化后的对象

- 获取当前存储的对象的 group、version、kind 等信息

综上，Kubernetes 中的对象就是一个结构体，它可以：

- 返回或设置 GroupVersionKind（GVK）

- 可以被深拷贝，拷贝后的对象不共享内存

所有的 Kubernetes 对象结构，都是内嵌了 `k8s.io/apimachinery/meta/v1` 中的下面两种结构：

- `TypeMeta`

- `ObjectMeta`

下面以kubernetes 中的 Deplyment 为例：

```go
// 位于 k8s.io/api/apps/v1/types.go
type Deployment struct {
    metav1.TypeMeta `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty" protobuf:"bytes,1,opt,name=metadata"`
    Spec DeploymentSpec `json:"spec,omitempty" protobuf:"bytes,2,opt,name=spec"`
    Status DeploymentStatus `json:"status,omitempty" protobuf:"bytes,3,opt,name=status"`
}
```

 可以发现 Deployment 结构体内嵌了 TypeMeta 和 ObjectMeta，那么这两个结构体有什么用呢？（其实就是一些公共的数据）

1. TypeMeta
   
   - 版本信息存储在 ApiVersion 中，对应 yaml 的 apiVersion 字段
   
   - 型别存储在 Kind 中，对应 yaml 中的 kind 字段

```go
type TypeMeta struct {
    Kind string `json:"kind,omitempty" protobuf:"bytes,1,opt,name=kind"`
    APIVersion string `json:"apiVersion,omitempty" protobuf:"bytes,2,opt,name=apiVersion"`
}
```

2. ObjectMeta
   
   - ObjectMeta 中的字段都对应于 yaml 中的 metadata 下的不同字段
   
   - metadata 存放元数据信息，例如名字、命名空间、资源版本（乐观并发使用）、时间戳、通用的标签和注解等。

```go
type ObjectMeta struct {
    Name string `json:"name,omitempty" protobuf:"bytes,1,opt,name=name"`
    GenerateName string `json:"generateName,omitempty" protobuf:"bytes,2,opt,name=generateName"`
    Namespace string `json:"namespace,omitempty" protobuf:"bytes,3,opt,name=namespace"`
    SelfLink string `json:"selfLink,omitempty" protobuf:"bytes,4,opt,name=selfLink"`
    UID types.UID `json:"uid,omitempty" protobuf:"bytes,5,opt,name=uid,casttype=k8s.io/kubernetes/pkg/types.UID"`
    ResourceVersion string `json:"resourceVersion,omitempty" protobuf:"bytes,6,opt,name=resourceVersion"`
    Generation int64 `json:"generation,omitempty" protobuf:"varint,7,opt,name=generation"`
    CreationTimestamp Time `json:"creationTimestamp,omitempty" protobuf:"bytes,8,opt,name=creationTimestamp"`
    DeletionTimestamp *Time `json:"deletionTimestamp,omitempty" protobuf:"bytes,9,opt,name=deletionTimestamp"`
    DeletionGracePeriodSeconds *int64 `json:"deletionGracePeriodSeconds,omitempty" protobuf:"varint,10,opt,name=deletionGracePeriodSeconds"`
    Labels map[string]string `json:"labels,omitempty" protobuf:"bytes,11,rep,name=labels"`
    Annotations map[string]string `json:"annotations,omitempty" protobuf:"bytes,12,rep,name=annotations"`
    OwnerReferences []OwnerReference `json:"ownerReferences,omitempty" patchStrategy:"merge" patchMergeKey:"uid" protobuf:"bytes,13,rep,name=ownerReferences"`
    Finalizers []string `json:"finalizers,omitempty" patchStrategy:"merge" protobuf:"bytes,14,rep,name=finalizers"`
    ManagedFields []ManagedFieldsEntry `json:"managedFields,omitempty" protobuf:"bytes,17,rep,name=managedFields"`
}
```

3. Spec 和 Status
   
   - 所有的 kubernetes 顶级对象都需要包含
   
   - Spec 表示用户期望的对象状态
   
   - Status 表示对象的当前结果，通常由系统的控制器来填充信息。

## 客户端集合 ClientSet

通过 NewForConfig 生成一个 ClientSet，也就是客户端的集合，这个 clientSet 可以访问多个 API 组和资源，**ClientSet 几乎可以访问所有的资源，除了 APIService（用于聚合服务器） 和 CustomResourceDefination（crd 自定义资源）**。

而 Interface （`k8s.io/client-go/kubernetes/clientset.go`）定义了 ClientSet 的所有接口

```go
type Interface interface {
    Discovery() discovery.DiscoveryInterface
    AdmissionregistrationV1() admissionregistrationv1.AdmissionregistrationV1Interface
    AdmissionregistrationV1beta1() admissionregistrationv1beta1.AdmissionregistrationV1beta1Interface
    InternalV1alpha1() internalv1alpha1.InternalV1alpha1Interface
    AppsV1() appsv1.AppsV1Interface
    AppsV1beta1() appsv1beta1.AppsV1beta1Interface
    AppsV1beta2() appsv1beta2.AppsV1beta2Interface
    AuthenticationV1() authenticationv1.AuthenticationV1Interface
    AuthenticationV1beta1() authenticationv1beta1.AuthenticationV1beta1Interface
    AuthorizationV1() authorizationv1.AuthorizationV1Interface
    AuthorizationV1beta1() authorizationv1beta1.AuthorizationV1beta1Interface
    AutoscalingV1() autoscalingv1.AutoscalingV1Interface
    AutoscalingV2() autoscalingv2.AutoscalingV2Interface
    AutoscalingV2beta1() autoscalingv2beta1.AutoscalingV2beta1Interface
    AutoscalingV2beta2() autoscalingv2beta2.AutoscalingV2beta2Interface
    BatchV1() batchv1.BatchV1Interface
    BatchV1beta1() batchv1beta1.BatchV1beta1Interface
    CertificatesV1() certificatesv1.CertificatesV1Interface
    CertificatesV1beta1() certificatesv1beta1.CertificatesV1beta1Interface
    CoordinationV1beta1() coordinationv1beta1.CoordinationV1beta1Interface
    CoordinationV1() coordinationv1.CoordinationV1Interface
    CoreV1() corev1.CoreV1Interface
    DiscoveryV1() discoveryv1.DiscoveryV1Interface
    DiscoveryV1beta1() discoveryv1beta1.DiscoveryV1beta1Interface
    EventsV1() eventsv1.EventsV1Interface
    EventsV1beta1() eventsv1beta1.EventsV1beta1Interface
    ExtensionsV1beta1() extensionsv1beta1.ExtensionsV1beta1Interface
    FlowcontrolV1alpha1() flowcontrolv1alpha1.FlowcontrolV1alpha1Interface
    FlowcontrolV1beta1() flowcontrolv1beta1.FlowcontrolV1beta1Interface
    FlowcontrolV1beta2() flowcontrolv1beta2.FlowcontrolV1beta2Interface
    NetworkingV1() networkingv1.NetworkingV1Interface
    NetworkingV1alpha1() networkingv1alpha1.NetworkingV1alpha1Interface
    NetworkingV1beta1() networkingv1beta1.NetworkingV1beta1Interface
    NodeV1() nodev1.NodeV1Interface
    NodeV1alpha1() nodev1alpha1.NodeV1alpha1Interface
    NodeV1beta1() nodev1beta1.NodeV1beta1Interface
    PolicyV1() policyv1.PolicyV1Interface
    PolicyV1beta1() policyv1beta1.PolicyV1beta1Interface
    RbacV1() rbacv1.RbacV1Interface
    RbacV1beta1() rbacv1beta1.RbacV1beta1Interface
    RbacV1alpha1() rbacv1alpha1.RbacV1alpha1Interface
    SchedulingV1alpha1() schedulingv1alpha1.SchedulingV1alpha1Interface
    SchedulingV1beta1() schedulingv1beta1.SchedulingV1beta1Interface
    SchedulingV1() schedulingv1.SchedulingV1Interface
    StorageV1beta1() storagev1beta1.StorageV1beta1Interface
    StorageV1() storagev1.StorageV1Interface
    StorageV1alpha1() storagev1alpha1.StorageV1alpha1Interface
}
```

注意：

- 客户端集合还提供了客户端发现功能（这是 RESTMapper 需要的）

- 这里所有的接口，返回的其实就是对应的每个 GroupVersion 下的资源类型集合

例如，我们查看 `AppsV1` 这个 GroupVersion 下的集合：

```go
// k8s.io/client-go/kubernetes/clientset.go
// AppsV1 retrieves the AppsV1Client
func (c *Clientset) AppsV1() appsv1.AppsV1Interface {
    return c.appsV1
}


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

- 可以看到 AppsV1 这个 GroupVersion 下的所有资源包括，ControllerRevisions、DaemonSets、Deployments、ReglicaSets、StatefulSets。

- RESTClient 是一个通用的 REST 客户端，其中包含了 Post、Get、Patch 等 verbs

- 注意，**这里的 DeploymentsGetter 还是一个 Interface ，因此，可以直接调用其方法。例如，DeploymentsGetter 是一个接口，只定义了一个方法，就是  `Deployments(namespace string) DeploymentInterface`，而 DeploymentInterface 则定义了 deployments 的增删改查等操作**。

- 对着 `kubectl api-resources --api-group apps` 一看便知：
  
  ```shell
  root@k8s-master:~# kubectl api-resources --api-group apps
  NAME                  SHORTNAMES   APIVERSION   NAMESPACED   KIND
  controllerrevisions                apps/v1      true         ControllerRevision
  daemonsets            ds           apps/v1      true         DaemonSet
  deployments           deploy       apps/v1      true         Deployment
  replicasets           rs           apps/v1      true         ReplicaSet
  statefulsets          sts          apps/v1      true         StatefulSet
  ```

现在以 Deployments 为例，继续往下看：

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
```

- 这里便是 deployments 的具体的 增删改查等方法。

- 不同的资源使用的范围不同，也就是这里的具体的方法不同，有些是集群层面的、有些是命名空间层面的。

- DeploymentInterface 提供了该资源所支持的所有方法。

下面详细介绍其中的某些方法：

1. 状态子资源：`UpdateStatus`
   
   - `UpdateStatus` 专门为以 `/status` 结尾的 HTTP 请求提供服务，例如通过 `/apis/apps/v1/namespaces/ns/deployments/name/status` 查看修改该对象的状态字段。
   
   - 默认，client-gen 会生成 `UpdateStatus` 方法，但不意味着这个资源就可以支持状态子资源。

2. 列表与删除（`DeleteCollection`）
   
   - `DeleteCollection` 允许用户因此删除命名空间中的多个对象。
   
   - 利用参数 `ListOptions` 来选择使用 字段选择器（`FieldSelector`）还是 标签选择器（`LabelSelector`）

3. `Watch`
   
   - `Watch` 提供发现对象状态变化的机制。
   
   - `Watch` 方法返回的 `Watch.Interface` 中，包含两个方法，一个是 Stop 停止监听，另一个是从 Channel 中获取状态变化 `ResultChan() <-chan Event`
   
   - 由于 Informer 机制中的缓存的存在，在实践中，不建议直接使用 `Watch` 接口，Informer 机制也提供了监听的机制，更常使用。
   
   - watch 接口返回的 Channel 对象可以有下面几种状态：
     
     ```go
     // k8s.io/apimachinery/pkg/watch/watch.go
     const (
         Added    EventType = "ADDED"
         Modified EventType = "MODIFIED"
         Deleted  EventType = "DELETED"
         Bookmark EventType = "BOOKMARK"
         Error    EventType = "ERROR"
     )
     
     type Event struct {
         Type EventType
         Object runtime.Object
     }
     ```

4. 客户端扩展（`DeploymentExpansion`)
   
   - `DeploymentExpansion` 是一个空接口，用于添加自定义的客户端行为，但是使用较少，**取而代之的使用客户端生成器来添加生命式的自定义接口。**

## client-go 对象转换过程

![k8s_client-go_object_trans](E:\notes\云计算\pic\k8s开发\k8s_client-go_object_trans.PNG)

详解查看：

[How To Call Kubernetes API using Go - Types and Common Machinery](https://iximiuz.com/en/posts/kubernetes-api-go-types-and-common-machinery/)

## client-go 调用实例

使用 client-go 调用 kubernetes 接口的实例：

```go
package main

import (
    "context"
    "fmt"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/rest"
    "k8s.io/client-go/tools/clientcmd"
    "os"
    "path/filepath"
)

func main() {
    var config *rest.Config
    config, err := rest.InClusterConfig()
    if err != nil {
        kubeconfig := filepath.Join("/root", ".kube", "config")
        if envvar := os.Getenv("KUBECONFIG"); len(envvar) > 0 {
            kubeconfig = envvar
        }
        config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
        if err != nil {
            fmt.Printf("The kubeconfig cannot be loaded: %v\n", err)
        }
    }

    clientset, _ := kubernetes.NewForConfig(config)

    pod, _ := clientset.CoreV1().Pods("kubesphere-system").Get(context.Background(), "ks-apiserver-5d9fffd4f6-hrs6p", metav1.GetOptions{})
    fmt.Printf("%v\n", pod)
}
```

## client-go Informer 机制

原理如下图：

![k8s_informer_principle](E:\notes\云计算\pic\k8s开发\k8s_informer_principle.PNG)

这张图分为两部分，黄色图标是开发者需要自行开发的部分，而其它的部分是 client-go 已经提供的，直接使用即可。

1. **Reflector**：用于 Watch 指定的 Kubernetes 资源，当 watch 的资源发生变化时，触发变更的事件，比如 Added，Updated 和 Deleted 事件，并将资源对象存放到本地缓存 DeltaFIFO；

2. **DeltaFIFO**：拆开理解，FIFO 就是一个队列，拥有队列基本方法（ADD，UPDATE，DELETE，LIST，POP，CLOSE 等），Delta 是一个资源对象存储，保存存储对象的消费类型，比如 Added，Updated，Deleted，Sync 等；

3. **Indexer**：Client-go 用来存储资源对象并自带索引功能的本地存储，informer 从 DeltaFIFO 中将消费出来的资源对象存储到 Indexer，Indexer 与 Etcd 集群中的数据完全保持一致。从而 client-go 可以本地读取，减少 Kubernetes API 和 Etcd 集群的压力。

4. **client-go组件**
- `Reflector`：reflector用来watch特定的k8s API资源。具体的实现是通过`ListAndWatch`的方法，watch可以是k8s内建的资源或者是自定义的资源。当reflector通过watch API接收到有关新资源实例存在的通知时，它使用相应的列表API获取新创建的对象，并将其放入watchHandler函数内的Delta Fifo队列中。

- `Informer`：informer从Delta Fifo队列中弹出对象。执行此操作的功能是 processLoop。base controller 的作用是保存对象以供以后检索，并调用我们的控制器将对象传递给它。

- `Indexer`：索引器提供对象的索引功能。典型的索引用例是基于对象标签创建索引。 Indexer 可以根据多个索引函数维护索引。Indexer 使用线程安全的数据存储来存储对象及其键。 在 Store 中定义了一个名为`MetaNamespaceKeyFunc`的默认函数，该函数生成对象的键作为该对象的`<namespace> / <name>`组合。
2. **自定义controller组件**
- `Informer reference`：指的是Informer实例的引用，定义如何使用自定义资源对象。 自定义控制器代码需要创建对应的Informer。

- `Indexer reference`: 自定义控制器对Indexer实例的引用。自定义控制器需要创建对应的Indexser。

> client-go中提供`NewIndexerInformer`函数可以创建Informer 和 Indexer。

- `Resource Event Handlers`：资源事件回调函数，当它想要将对象传递给控制器时，它将被调用。 编写这些函数的典型模式是获取调度对象的key，并将该key排入工作队列以进行进一步处理。

- `Work queue`：任务队列。 编写资源事件处理程序函数以提取传递的对象的key并将其添加到任务队列。

- `Process Item`：处理任务队列中对象的函数， 这些函数通常使用Indexer引用或Listing包装器来重试与该key对应的对象。

### client-go 中的 informer

一个程序对每个 GVR（GroupVersionResource）只生成一个 Informer。可以通过使用**共享 Informer 工厂**来方便地实现对 Informer 的复用。<u>也就是要通过 共享 Informer 工厂来创建 Informer ，而不要手动创建。</u>

通过 REST 配置，也就是创建客户端集合，可以方便创建一个共享的 Informer 工厂，对于 Kubernentes 的标准资源，它们的 Informer 是作为 client-go 的一部分一起发布的。位于 `k8s.io/client-go/informers`

下面是一个创建 Informer 的实例：

```go
package main

import (
    "fmt"
    "k8s.io/apimachinery/pkg/util/wait"
    "k8s.io/client-go/informers"
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/rest"
    "k8s.io/client-go/tools/cache"
    "k8s.io/client-go/tools/clientcmd"
    "os"
    "path/filepath"
    "time"
)

func main() {
    var config *rest.Config
    config, err := rest.InClusterConfig()
    if err != nil {
        kubeconfig := filepath.Join("/root", ".kube", "config")
        if envvar := os.Getenv("KUBECONFIG"); len(envvar) > 0 {
            kubeconfig = envvar
        }
        config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
        if err != nil {
            fmt.Printf("The kubeconfig cannot be loaded: %v\n", err)
        }
    }

    clientset, _ := kubernetes.NewForConfig(config)

    // 创建 共享 Informer 工厂
    informerFactory := informers.NewSharedInformerFactory(clientset, time.Second*30)

    // 获取 对应 Pods GVR 的 informer
    podInformer := informerFactory.Core().V1().Pods()

    podInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc: func(obj interface{}) {
            fmt.Println("Add Pods Func")
        },
        UpdateFunc: func(oldObj, newObj interface{}) {
            fmt.Println("Update Pods Func")
        },
        DeleteFunc: func(obj interface{}) {
            fmt.Println("Delete Pods Func")
        },
    })

    informerFactory.Start(wait.NeverStop)
    informerFactory.WaitForCacheSync(wait.NeverStop)
    podInformer.Lister().Pods("kubesphere-system").Get("ks-apiserver-5d9fffd4f6-hrs6p ")
}
```

- 通过 Informer 可以添加、更新、删除三种事件处理函数，通常用于触发控制器中的业务逻辑运行，这些**事件处理函数通常只需要把修改过的对象放入一个工作队列中**

- 注册好事件后，启动共享 Informer 工厂，内部就是启动 GoRoutine 来访问 API 服务器。Start 方法用于启动这些 GoRoutine，Start 会返回一个表示停止状态的 Channel，用于控制生命周期。

- WaitForCacheSync() 方法用于让代码停下等待第一个向客户端发起的 List 请求返回。如果 控制器逻辑以来缓存填充完毕，那么 WaitForCacheSync 就非常重要

- 最后 通过 Lister 获取 Pod 是一个纯内存的操作，不会与 API 服务器交互。内存中的对象不能直接被修改，需要通过客户端集合（clientset）对资源进行修改，然后通过 Informer 从 API 服务器监听到事件，并且修改内存。

- 从 Lister 往事件处理器传送的任何对象都是 Informer 负责管理的，不要再 Informer 中修改对象。 

### 工作队列 WorkQueue

工作队列 Workqueue 其实就是一种优先队列结构，代码位于 `k8s.io/client-go/util/workqueue`

工作队列都基于同一个接口来实现：

```go
type Interface interface {
    Add(item interface{})
    Len() int
    Get() (item interface{}, shutdown bool)
    Done(item interface{})
    ShutDown()
    ShutDownWithDrain()
    ShuttingDown() bool
}
```

- Add - 添加元素

- Len - 返回队列长度

- Get - 返回具有最高优先级的一个元素（如果队列为空，则阻塞等待）

- Done - 所有通过 Get 方法返回的对象，都需要控制器在完成处理后，调用 Done 方法

下面是基于通用接口实现的队列类型：

1. DelayingInterface : 延迟优先队列
   
   - 可以方便的把处理失败的元素重新加入队列，不需要一个忙等待的循环
     
     ```go
     type DelayingInterface interface {
         Interface
         // AddAfter adds an item to the workqueue after the indicated duration has passed
         AddAfter(item interface{}, duration time.Duration)
     }
     ```

2. RateLimitingInterface : 限流优先队列
   
   - 对元素加入队列的频次进行限流，派生自 DelayingInterface
   
   - 限流算法可以通过 NewRateLimitingQueue 构造函数指定，有以下几种限流算法：
     
     - BucketRateLimiter
     
     - ItemExponentialFailureRateLimiter
     
     - ItemFastSlowRateLimiter
     
     - MaxOfRateLimiter
     
     ```go
     type RateLimitingInterface interface {
         DelayingInterface
     
         // AddRateLimited adds an item to the workqueue after the rate limiter says it's ok
         AddRateLimited(item interface{})
     
         // Forget indicates that an item is finished being retried.  Doesn't matter whether it's for perm failing
         // or for success, we'll stop the rate limiter from tracking it.  This only clears the `rateLimiter`, you
         // still have to call `Done` on the queue.
         Forget(item interface{})
     
         // NumRequeues returns back how many times the item was requeued
         NumRequeues(item interface{}) int
     }
     ```
