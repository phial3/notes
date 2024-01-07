# debug

思路：

1. go 远程开发需要 dlv 工具，goland 使用 go remote 连接调试

2. dlv 需要放入到 docker image 中，启动使用 dlv 启动，而且在编译时需要带参数 `-gcflags="all=-N -l"`

3. 查看 kubesphere 的 make 打包命令，添加 dev 开发编译命令

4. 修改 gobuild.sh ，添加 go build 编译参数

5. 改写 dockerfile：
   
   - 编译时使用 dev 编译命令
   
   - 将 dlv 命令 copy 到镜像中

```shell
- dlv
- --listen=:2345
- --headless=true
- --accept-multiclient
- --api-version=2
- exec
- /usr/local/bin/ks-apiserver
- --
- --logtostderr=true
```

```shell
 $ dlv --listen=:2345 --headless=true --accept-multiclient --api-version=2 --log attach 1
```
