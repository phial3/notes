# Kubernetes CNI 网络插件

## 更换 K8S CNI 插件

可以在Master节点上执行如下命令未替换网络插件为 flannel：

1. 笫一步，执行
   
   ```shell
   $ rm -rf /etc/cni/net.d/*
   ```

2. 笫二步，执行:
   
   ```shell
   $ kubectl delete -f "https://cloud.weave.works/k8s/net?k8s­version=l.11"
   ```

3. 第三步，再 `/etc/kubernetes/manifests/kube-controller-manager.yaml` 里为容器启动命令添加两个参数：
   
   ```shell
   --allocate-node-cidrs = true
   --cluster-cidr = 10.244.0.0/16
   ```

4. 重启所有 kubelet

5. 执行
   
   ```shell
   kubectl create -f https://xxxx/.../flannel.yaml
   ```
