# OpenResty

[toc]

## 概述



>  OpenResty is a full-fledged web application server by bundling the standard nginx core, lots of 3rd-party nginx modules, as well as most of their external dependencies.

OpenResty 是一个基于 nginx core 的 web 应用服务器，依赖很多第三方的 nginx 模块。

- OpenResty 其实就是 nginx 添加了 oepnresty 的模块，主要是 [lua-nginx-module](https://github.com/openresty/lua-nginx-module) （七层 http） 和 [stream-lua-nginx-module](https://github.com/openresty/stream-lua-nginx-module)（四层 tcp/udp）
- 使用了 luajit 来优化性能，OpenResty 本质上是将 LuaJIT 的虚拟机嵌入到 Nginx 的管理进程和工作进程中，同一个进程内的所有协程都会共享这个虚拟机，并在虚拟机中执行 Lua 代码
- 集成了大量精良的 Lua 库、第三方模块以及大多数的依赖项，并且自己重新写了 [lua-resty-core](https://github.com/openresty/lua-resty-core) 等 lua 库
- 最终运行的进程还是 nginx



openresty 性能高的原因有几个方面：

1. **LuaJIT**，LuaJIT 的运行环境除了一个汇编实现的 Lua 解释器外，还有一个可以直接生成机器码的 JIT 编译器。LuaJIT 要比官方的编译器快上不少。
2. **LuJIT 的 FFI （Foreign Function Interface） 特性**，可以直接在 Lua 代码中调用外部的 C 函数或者 C 数据结构。
   - openresty 自己实现的 lua-resty-core 库就是完全基于 FFI 特性，调用的 linux 内核系统函数实现的
3. **cosocket**，cosocket 不仅需要 Lua 协程特性的支持，也需要 Nginx 中非常重要的事件机制的支持，这两者结合在一 起，最终实现了非阻塞网络 I/O
   -  Lua 协程，就是在一个线程下也可以拥有多个协程，拥有独立的堆栈、独立的局部变量、独立的指令指针，同时又与其他协同程序共享全局变量等。与 Goroutine 类似。



## 原理

Nginx 将 HTTP 请求的处理过程划分为 11 个阶段：

请求进来后的 rewrite 阶段：

1. POST_READ：在 read 完请求的头部之后，在没有对头部做任何处理之前，想要获取到一些原始的值，就应该在这个阶段进行处理。这里面会涉及到一个 realip 模块。
2. SERVER_REWRITE：和下面的 REWRITE 阶段一样，都只有一个模块叫 rewrite 模块，一般没有第三方模块会处理这个阶段。
3. FIND_CONFIG：做 location 的匹配，暂时没有模块会用到。
4. REWRITE：对 URL 做一些处理。
5. POST_WRITE：处于 REWRITE 之后，也是暂时没有模块会在这个阶段出现。

接下来是确认用户访问权限的三个模块：

1. PREACCESS：是在 ACCESS 之前要做一些工作，例如并发连接和 QPS 需要进行限制，涉及到两个模块：limt_conn 和 limit_req
2. ACCESS：核心要解决的是用户能不能访问的问题，例如 auth_basic 是用户名和密码，access 是用户访问 IP，auth_request 根据第三方服务返回是否可以去访问。
3. POST_ACCESS：是在 ACCESS 之后会做一些事情，同样暂时没有模块会用到。

最后的三个阶段处理响应和日志：

1. PRECONTENT：在处理 CONTENT 之前会做一些事情，例如会把子请求发送给第三方的服务去处理，try_files 模块也是在这个阶段中。
2. CONTENT：这个阶段涉及到的模块就非常多了，例如 index, autoindex, concat 等都是在这个阶段生效的。
3. LOG：记录日志 access_log 模块。



OpenRestry 基于 Nginx 也制定了 相应的 11 个 `*_by_lua` 指令，它们和 Nginx 的 11 个执行阶段有很大的关联性。

![OpenRestry-11阶段](./assets/OpenRestry-11阶段.png)

其中：

- **`init_by_lua`** 只会在 Master 进程被创建时执行
- **`init_worker_by_lua`** 只会在每个 Worker 进程被创建时执行。
- **`_by_lua`** 指令则是由终端请求触发，会被反复执行。

**在 11 个 HTTP 阶段中嵌入 Lua 代码**

`set_by_lua*` 将 Lua 代码添加到 Nginx 官方 ngx_http_rewrite_module 模块中的脚本指令中执行

`rewrite_by_lua*` 将 Lua 代码添加到 11 个阶段中的 rewrite 阶段中，作为独立模块为每个请求执行相应的 Lua 代码。此阶段可以实现很多功能，比如调用外部服务、转发和重定向处理等。

`access_by_lua*`: 将 Lua 代码添加到 11 个阶段中的 access 阶段中执行，与`rewrite_by_lua*`类似，也是作为独立模块为每个请求执行相应的 Lua 代码。 此阶段的 Lua 代码可以进行 API 调用，并在独立的全局环境(即沙箱)中作为一个新生成的协程执行。一般用于访问控制、权限校验等。

`content_by_lua*`: 在 11 个阶段的 content 阶段以独占方式为每个请求执行相应的 Lua 代码，用于生成返回内容。

`log_by_lua`: 将 Lua 代码添加到 11 个阶段中的 log 阶段中执行，它不会替换当前请求的 access 日志，但会在其之前运行，一般用于请求的统计及日志记录。

**在负载均衡时嵌入 Lua 代码**

`balance_by_lua*` : 将 Lua 代码添加到反向代理模块、生成上游服务地址的 init_upstream 回调方法中，用于 upstream 负载均衡控制

**在过滤响应时嵌入 Lua 代码**

`header_filter_by_lua*：`将 Lua 代码嵌入到响应头部过滤阶段中，用于应答头过滤处理。

`body_filter_by_lua*：`将 Lua 代码嵌入到响应包体过滤阶段中，用于应答体过滤处理。需要注意的是，此阶段可能在一个请求中被调用多次，因为响应体可能以块的形式传递。因此，该指令中指定的 Lua 代码也可以在单个 HTTP 请求的生命周期内运行多次。



## OpenResty 相关命令



### 1. openresty

openresty 命令，其实就是 nginx 的命令，最常用的有：

```shell
# 1. 启动，-p 指定运行根目录，-c 指定 nginx conf 文件
openresty -p /to/home/ -c /to/home/xx.conf

# 2. 给 nginx 进程发送信号：stop, quit, reopen, reload
openresty -p /to/home/ -c /to/home/xx.conf -s reload

# 3. 检查配置文件
openresty -p /to/home/ -c /to/home/xx.conf -t
```





### 2. resty

resty 可以把它作为 Lua 语言的解释器（但运行在 OpenResty 环境里）。

resty 的工作原理是启动了一个 “无服务” 的 Nginx 示例，禁用了 daemn 等大多数指令，也没有配置监听端口，只是在 worker 集成里用定时器让 Lua 代码在 Nginx 里执行。

```shell
my @cmd = ($nginx_path,                                                     
           '-g', '# ' . $label,                                                 
           '-p', "$prefix_dir/", '-c', "conf/nginx.conf");
```

- `-g` 后面接的指令会作为全局配置语句插入到配置文件的顶层作用域中，指令是一条或多条 Nginx 配置指令，多个指令之间用分号（`;`）分隔



**实例  hello world：**

```shell
# lua 测试脚本
$ cat /tmp/lua/test.lua 
local _M = {}

function _M.hello() 
	print("Hello World") 
end

return _M


# 执行 lua 脚本
$ resty -I /tmp/lua/ -e 'require "test".hello()'
Hello World
```



**实例 LuaJIT 测试性能：**

```shell
# 循环加法
$ echo 'local a = 0 for i = 1, 1e8 do a = a + 1 end print(a)' > /tmp/lua/bench.lua

# 禁用 LuaJIT 运行程序的执行时间
$ time resty -joff /tmp/lua/bench.lua
100000000

real	0m0.399s
user	0m0.393s
sys	0m0.007s

# 默认开启 LuaJIT 
$ time resty /tmp/lua/bench.lua
100000000

real	0m0.078s
user	0m0.065s
sys	0m0.013s


# 可以看出，优化还是很明显的
```





### restydoc

restydoc 是一个文档查询命令，类似 man

```shell
$ restydoc -s ffi.cdef
```





### opm

`opm` 是官方的 OpenResty 包管理器，类似 npm

```shell
# 搜索
$ opm search lru cache
openresty/lua-resty-lrucache                      Lua-land LRU Cache based on LuaJIT FFI
aptise/lua-resty-peter_sslers                     OpenResty SSL Certificate routines for the peter_sslers SSL Certificate manager
aptise/peter_sslers-lua-resty                     openresty ssl certificate routines for peter_sslers SSL Certificate manager
thenam153/lua-resty-acme                          Automatic Let's Encrypt certificate serving and Lua implementation of ACME procotol
fffonion/lua-resty-acme                           Automatic Let's Encrypt certificate serving and Lua implementation of ACME procotol
fffonion/lua-resty-worker-events                  ua-resty-worker-events
thibaultcha/lua-resty-mlcache                     Layered caching library for OpenResty
hamishforbes/lua-resty-tlc                        General two level cache (lrucache + shared dict)
jxskiss/simplessl                                 Auto SSL cert issue and renewal with Let's Encrypt
jxskiss/ssl-cert-server                           Auto SSL cert issue and renewal with Let's Encrypt
toruneko/lua-resty-upstream                       pure lua nginx upstream management for OpenResty/LuaJIT

# 安装
$ opm get openresty/lua-resty-lrucache
* Fetching openresty/lua-resty-lrucache  
  Downloading https://opm.openresty.org/api/pkg/tarball/openresty/lua-resty-lrucache-0.08.opm.tar.gz
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100 12359  100 12359    0     0  16154      0 --:--:-- --:--:-- --:--:-- 16176
Package openresty/lua-resty-lrucache 0.08 installed successfully under /usr/local/openresty/site/ .

# 查询
$ opm list
openresty/lua-resty-lrucache                                 0.08
```





## 开发应用 

注意：

- `xxx_by_lua_block` 将 lua 代码嵌入到 nginx conf 文件中

- `xxx_by_lua_file` 指定运行的文件
- 如果使用“-c/-p”参数启动了OpenResty，那么在使用“-s”时也必须使用“-c/-p”参数，告诉OpenResty使用的是哪个配置文件。
- openresty -s 可以传递信号给 nginx 进程：
  - stop - 停止服务，未完成的请求立即结束
  - quit - 停止服务，但必须处理完当前所有的请求
  - reload - 重启服务，重新加载配置文件和 lua 代码，服务不中断
  - reopen - 只重新打开日志文件，服务不中断，常用于切分日志



### 1. 目录结构

目录结构如下：

```shell
$ tree gsh_demo/
gsh_demo/
├── conf									# nginx 配置文件，可以再区分 http 和 stream
├── logs									# 日志
└── service									# 自定义 lua 代码
    ├── http
    ├── stream
    └── utils
```



在启动 openresty 时，一定要通过 `openresty -p /gsh_demo/ -c /gsh_demo/conf/nginx.conf `   命令，指定 openresty 的运行根目录。





### 2. 编写 nginx conf 配置文件

在 OpenResty 里 ngx_lua 和 stream_lua 分别属于两个不同的子系统，但指令的功能和格式基本相同。



在 nginx config 文件中有几个根 lua 脚本相关的配置需要修改：

1. **`lua_package_path`** - Lua库依赖的查找路径
2. **`lua_package_cpath`** - so库的查找路径，

其中，文件名使用 `? `作为通配符，多个路径使用 `;` 分隔，默认的查找路径用 `; ;`。指令里还可以使用特殊变量 ` $prefix `，表示 OpenResty 启动时的工作目录（即“-p”参数指定的目录）。



在该示例中，添加：

```cmd
http {                                                                                      
    lua_package_path "$prefix/service/?.lua ;;";                                            
    lua_package_cpath "$prefix/lib/?.so ;;";
    ...
    
}
```

上面的指令告诉 OpenResty 在工作目录的 service 里查找 Lua 库和 *.so 库



还有一个配置：`lua_code_cache on|off` 。这个指令会启用 OpenResty 的 Lua 代码缓存功能

在调试时我们会经常修改 Lua 代码，如果 lua_code_cache 是 on 状态，因为代码已经在应用启动时读取并缓存，修改后的代码就不会被 OpenResty 载入，修改也不会生效，只能使用 “-s reload” 的方式强制让 OpenResty 重新加载代码。



### 3. 编写 lua 脚本

应用实现了基本的时间服务，具体功能是：

- 只支持GET和POST方法；
- 只支持HTTP 1.1/2协议；
- 只允许某些用户访问服务；
- GET方法获取当前时间，以http时间格式输出；
- POST方法在请求体里传入时间戳，服务器转换为http时间格式输出；
- 可以使用URI参数“need_encode=1”，输出会做Base64编码。



在 nginx.conf 中添加配置：

```cmd
http {                                                                                                             
    lua_package_path "$prefix/service/?.lua ;;";                                                                   
    lua_package_cpath "$prefix/lib/?.so ;;";                                                                       
    include       mime.types;                                                                                       
    default_type  application/octet-stream;
    server {                                                                                                       
        listen 31234;                                                                                               
        server_name  localhost;                                                                                                    
        location = /demo {                                                                                         
            rewrite_by_lua_file service/http/rewrite_demo.lua;                                                     
            access_by_lua_file service/http/access_demo.lua;                                                       
            content_by_lua_file service/http/content_demo.lua;                                                     
            body_filter_by_lua_file service/http/body_filter_demo.lua;                                             
        }                                                                        
    } 
    ....
    
}
```



1. `rewrite_demo.lua`

```lua
-- rewrite_demo.lua

-- 1. only support get or post method
local method = ngx.req.get_method()

if method ~= "GET" and method ~= "POST" then
    ngx.header["Allow"] = "GET, POST"
    ngx.exit(405)
end


-- 2. only support above http 1.1 version
local ver = ngx.req.http_version()
if ver < 1.1 then
    ngx.exit(400)
end

-- 3. get need_encode var save in ngx.ctx
ngx.ctx.encode = ngx.var.arg_need_encode
ngx.header.content_length = nil

```



2. `access_demo.lua`

```lua
-- access_demo.lua

-- 1. ip white list
local white_list = {...}
white_list["127.0.0.1"] = true
white_list["localhost"] = true

-- 2. get remote_addr from client
local client_ip = ngx.var.remote_addr

-- 3. client_ip in white_list?
if not white_list[client_ip] then
    ngx.log(ngx.ERR, client_ip, " is blocked.")
    ngx.exit(403)
end 

```



3. `content_demo.lua`

```lua
-- content_demo.lua

-- 1. POST and GET handler
local function action_get()
    ngx.req.discard_body()
    locat t = ngx.time()
    ngx.say(ngx.http_time(t))
end

local function action_post()
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    local num = tonumber(data)
    if not num then
        ngx.log(ngx.ERR, "post body is not number")
        ngx.exit(400)
    end
    ngx.say(ngx.http_time(num))
end


-- 2. method and handler map
local actions = {
    GET = action_get,
    POST = action_post
}

-- 3. exec handler func for method
local method = ngx.req.get_method()
actions[method]()

```



4. `body_filter_demo.lua`

```lua
-- body_filter_demo.lua

-- encode if need
if ngx.status ~= ngx.HTTP_OK then
    return
end

if ngx.ctx.encode then
    -- write to response
    ngx.arg[1] = ngx.encode_base64(ngx.arg[1])
end
```



### 4. 启动验证

启动 oepnresty :

```shell
$ openresty -c /gsh_demo/conf/nginx.conf -p /gsh_demo/
```



验证：

```shell
$ curl localhost:31234/demo
Sat, 30 Nov 2024 15:13:53 GMT
$ curl localhost:31234/demo -X DELETE
<html>
<head><title>405 Not Allowed</title></head>
<body>
<center><h1>405 Not Allowed</h1></center>
<hr><center>openresty/1.27.1.1</center>
</body>
</html>
$ curl localhost:31234/demo -X POST -d 1732979711
Sat, 30 Nov 2024 15:15:11 GMT

```

