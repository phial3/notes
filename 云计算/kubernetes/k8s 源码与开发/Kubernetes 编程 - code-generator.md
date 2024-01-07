# Kubernetes 编程 - code-generator

## code-generator

`k8s.io/client-go` 提供了对 k8s 原生资源的 informer 和 clientset 等等，但对于自定义资源的操作则相对低效，需要使用 rest api 和 dynamic client 来操作，并自己实现反序列化等功能。

`k8s.io/code-generator` 提供了以下工具用于为 k8s 中的资源生成相关代码。

```shell
root@k8s-master:~/workspace# git clone https://github.com/kubernetes/code-generator.git
Cloning into 'code-generator'...
remote: Enumerating objects: 11988, done.
remote: Counting objects: 100% (2189/2189), done.
remote: Compressing objects: 100% (314/314), done.
remote: Total 11988 (delta 1919), reused 2084 (delta 1865), pack-reused 9799
Receiving objects: 100% (11988/11988), 9.57 MiB | 7.83 MiB/s, done.
Resolving deltas: 100% (6868/6868), done.

root@k8s-master:~/workspace# cd code-generator/
root@k8s-master:~/workspace/code-generator# ls
cmd                 CONTRIBUTING.md  examples            generate-internal-groups.sh  go.sum  LICENSE  pkg        SECURITY_CONTACTS  tools.go
code-of-conduct.md  doc.go           generate-groups.sh  go.mod                       hack    OWNERS   README.md  third_party
root@k8s-master:~/workspace/code-generator#
```

这里最重要的几个脚本是：

- generate-groups.sh

- generate-internal-groups.sh

- hack/update-codegen.sh

- hack/verify-codegen.sh

```shell
root@k8s-master:~/workspace/code-generator# ./generate-groups.sh -h
Usage: generate-groups.sh <generators> <output-package> <apis-package> <groups-versions> ...

  <generators>        the generators comma separated to run (deepcopy,defaulter,client,lister,informer) or "all".
  <output-package>    the output package name (e.g. github.com/example/project/pkg/generated).
  <apis-package>      the external types dir (e.g. github.com/example/api or github.com/example/project/pkg/apis).
  <groups-versions>   the groups and their versions in the format "groupA:v1,v2 groupB:v1 groupC:v2", relative
                      to <api-package>.
  ...                 arbitrary flags passed to all generator binaries.


Examples:
  generate-groups.sh all             github.com/example/project/pkg/client github.com/example/project/pkg/apis "foo:v1 bar:v1alpha1,v1beta1"
  generate-groups.sh deepcopy,client github.com/example/project/pkg/client github.com/example/project/pkg/apis "foo:v1 bar:v1alpha1,v1beta1"
root@k8s-master:~/workspace/code-generator# ./generate-internal-groups.sh -h
Usage: generate-internal-groups.sh <generators> <output-package> <internal-apis-package> <extensiona-apis-package> <groups-versions> ...

  <generators>        the generators comma separated to run (deepcopy,defaulter,conversion,client,lister,informer,openapi) or "all".
  <output-package>    the output package name (e.g. github.com/example/project/pkg/generated).
  <int-apis-package>  the internal types dir (e.g. github.com/example/project/pkg/apis).
  <ext-apis-package>  the external types dir (e.g. github.com/example/project/pkg/apis or githubcom/example/apis).
  <groups-versions>   the groups and their versions in the format "groupA:v1,v2 groupB:v1 groupC:v2", relative
                      to <api-package>.
  ...                 arbitrary flags passed to all generator binaries.

Examples:
  generate-internal-groups.sh all                           github.com/example/project/pkg/client github.com/example/project/pkg/apis github.com/example/project/pkg/apis "foo:v1 bar:v1alpha1,v1beta1"
  generate-internal-groups.sh deepcopy,defaulter,conversion github.com/example/project/pkg/client github.com/example/project/pkg/apis github.com/example/project/apis     "foo:v1 bar:v1alpha1,v1beta1"
```

1. **generate-groups.sh**

所有的控制器项目中都会用类似的方法使用代码生成器。只不过是包名、组名、API 版本有所差异。

使用起来比较简单：

```shell
vendor/k8s.io/code-generator/generate-groups.sh \
  all \
  github.com/programming-kubernetes/cnat/cnat-client-go/pkg/generated \
  github.com/programming-kubernetes/cnat/cnat-client-go/pkg/apis \
  "cnat:v1alpha1 foo:v1" \
  --go-header-file hack/boilerplate.go.txt \
  --output-base "${GOPATH}/src"
```

- 第一个参数 - <generators> ：**调用指定的代码生成器**，例如：(deepcopy, defaulter, client, lister, informer) or "all"

- 第二个参数 - <output-package> ： 用于要指定要生成的客户端、Lister和 Informer 代码的**包名**，例如：github.com/example/project/pkg/generated

- 第三个参数 - <apis-package> ：**API 组的基础包名**，例如：github.com/example/api or github.com/example/project/pkg/apis

- 第四个参数 - <groups-versions> ：有空格隔开的 **API 组列表及其版本号**

- --go-header-file ：用于自定义生成的代码所使用的**版权信息头**

- --output-base：作为参数传递给所有生成器，用于**定义查找包的基础路径**
2. **generate-internal-groups.sh**

如果你想开发一个自己的 API 服务器、带版本的类型以外还要操作一些内部的类型或者需要自定义一些默认的函数，

这个脚本主要关心两个生成器：

- conversion-gen ：创建用于转换内部类型和外部类型的函数

- defaulter-gen ： 生成处理部分字段默认值的代码
3. hack/update-codegen.sh 和 hack/verify-codegen.sh

hack/update-codegen.sh 是官方sample-controller项目的模板文件，用于填写code-generator中的相关变量

hack/verify-codegen.sh 调用update-codegen.sh，并检测代码变化的脚本，CI过程中非常重要

也就是 update-codegen.sh 会生成一份新代码，而 verify-codegen.sh 对比新老代码是否一样

## 通过标签选择控制代码生成器

### 全局标签与局部标签

- 全局标签：**会写在包的 doc.go 文件中**。
  
  - `//+groupName=foo.example.com` 定义了 API 组的全名，如果 Go 的父包名与组名不一致，可以通过这个标签来指定组名，这样才会生成正确的 HTTP 路径，`/apis/foo.example.com/` 
  
  - `//+groupName=CNAT` 用于定义 Go 的标识符（变量和类型的名字）。默认情况下，会使用父包名作为标识符的名字。在默认情况下，代码生成器会使用首字母大写的父包名作为标识符。

```go
// +k8s:deepcopy-gen=package
// +groupName=samplecontroller.k8s.io

// Package v1alpha1 is the v1alpha1 version of the API.
package v1alpha1 // import "k8s.io/sample-controller/pkg/apis/samplecontroller/v1alpha1"
```

- 局部标签：**可以直接写在 API 类型前的注释块中**。

```go
// +genclient
// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

// Foo is a specification for a Foo resource
type Foo struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty"`

    Spec   FooSpec   `json:"spec"`
    Status FooStatus `json:"status"`
}
```

### 代码生成器

code-generator 提供了以下工具用于为k8s中的资源生成相关代码，可以更加方便的操作自定义资源：

- `deepcopy-gen`: 生成深度拷贝对象方法
  
  使用方法：
  
  - 在文件中添加注释`// +k8s:deepcopy-gen=package`
  - 为单个类型添加自动生成`// +k8s:deepcopy-gen=true`
  - 为单个类型关闭自动生成`// +k8s:deepcopy-gen=false`
  - 生成其他 DeepCopyInterfaceName 方法 `// +k8s:deepcopy-gen:interfaces=k8s.io/kubernetes/runtime.Object,k8s.io/kubernetes/runtime.List`
  - 生成其他 DeepCopyObject 方法 `// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object`

- `client-gen`: 为资源生成标准的操作方法(get;list;watch;create;update;patch;delete)
  
  在pkg/apis/GROUP/{VERSION}/types.go中使用，使用// +genclient标记对应类型生成的客户端，
  如果与该类型相关联的资源不是命名空间范围的(例如PersistentVolume),
  则还需要附加// + genclient：nonNamespaced标记，
  
  - `// +genclient` - 生成默认的客户端动作函数（create, update, delete, get, list, update, patch, watch以及
    是否生成updateStatus取决于.Status字段是否存在）。
  
  - `// +genclient:nonNamespaced` - 所有动作函数都是在没有名称空间的情况下生成
  
  - `// +genclient:onlyVerbs=create,get` - 指定的动作函数被生成.
  
  - `// +genclient:skipVerbs=watch` - 生成watch以外所有的动作函数.
  
  - `// +genclient:noStatu`s - 即使.Status字段存在也不生成updateStatus动作函数
  
  - 在生成的 Create 方法中，只会执行创建动作，并返回一个 metav1.Status 对象
    
    ```go
    // +genclient:method=Create,verb=create,
    // result=k8s.io/apimachinery/pkg/apis/meta/v1.Status
    ```
  
  - 下面是为了资源增加扩容缩容的方法，第一个标签用于生成获取状态用的 GetScale 方法；第二个标签用于生成设置状态用的 UpdateScate 方法
    
    ```go
    // +genclient:method=GetScale,verb=get,subresource=scale, \
    //     result=k8s.io/api/autoscaling/v1.Scale
    // +genclient:method=UpdateScale,verb=update,subresource=scale, \
    //     intput=k8s.io/api/autoscaling/v1.Scale,result=k8s.io/api/autoscaling/v1.Scale 
    ```

- `informer-gen`: 生成informer，提供事件机制(AddFunc,UpdateFunc,DeleteFunc)来响应kubernetes的event

- `lister-gen`: 为get和list方法提供只读缓存层

- `conversion-gen`是用于自动生成在内部和外部类型之间转换的函数的工具
  
  一般的转换代码生成任务涉及三套程序包：
  
  - 一套包含内部类型的程序包，
  - 一套包含外部类型的程序包
  - 单个目标程序包（即，生成的转换函数所在的位置，以及开发人员授权的转换功能所在的位置）。包含内部类型的包在Kubernetes的常规代码生成框架中扮演着称为`peer package`的角色。
  
  使用方法：
  
  - 标记转换内部软件包 `// +k8s:conversion-gen=<import-path-of-internal-package>`
  - 标记转换外部软件包`// +k8s:conversion-gen-external-types=<import-path-of-external-package>`
  - 标记不转换对应注释或结构 `// +k8s:conversion-gen=false`

- `defaulter-gen` 用于生产Defaulter函数
  
  - 为包含字段的所有类型创建defaulters，`// +k8s:defaulter-gen=<field-name-to-flag>`
  - 所有都生成`// +k8s:defaulter-gen=true|false`

- `go-to-protobuf` 通过go struct生成pb idl

- `import-boss` 在给定存储库中强制执行导入限制

- `openapi-gen` 生成openAPI定义
  
  使用方法：
  
  - `+k8s:openapi-gen=true` 为指定包或方法开启
  - `+k8s:openapi-gen=false` 指定包关闭

- `register-gen` 生成register

- `set-gen`  
