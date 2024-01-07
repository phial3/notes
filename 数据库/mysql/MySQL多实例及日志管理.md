[toc]

# MySQL 多实例及日志管理



## MySQL 多实例



### 多实例概述

实例：MySQL 数据库由后台线程及一个共享内存区组成，数据库实例才是真正用于操作数据库文件的程序集，是一个动态概念。Mysql被设计成一个单进程多线程架构的数据库，所以在操作系统上表现就是一个进程。



多实例

- **一台服务器上开启多个不同的服务端口（默认3306），运行多个 mysql 的服务进程**，
- 此服务进程通过不同的 socket 监听不同的服务端口来提供各在的服务
- 所有实例之间共同使用一套 MySQL 的安装程序，但各自使用不同的配置文件、启动程序、数据文件，在逻辑上是相对独立的。

  多实例主要作用是：**充分利用现有的服务器硬件资源，为不同的服务提供数据服务，但是如果某个实例并发比较高的，同样是会影响到其它实例的性能。**



**多实例的优缺点：**

- 优点：
    - 可以有效利用服务器资源，当单个服务器资源富裕时，可以充分利用资源提供更多的服务。
    - 节约服务器资源，若公司资金不是充裕，又想数据库能独立提供服务，还想用主从复制等技术，那么只能选择多实例部署方式。
- 缺点：
    - 存在资源互享抢占的问题，当某个数据库实例并发很高且 SQL 查询耗时，那整个实例会消耗大量的系统资源，包括CPU、磁盘IO等，导致同一个服务器的其它数据库实例可能响应慢，毕竟它不会像虚拟机一样做到完全隔离。





### 多实例部署

多实例也就是在同一台机器上，运行多个 mysqld 进程，不同的 mysqld 进程需要以下方面的配置的不同：

- `datadir`: 数据存储目录必须不同
- `socket`: 监听的 Socket 必须不同
- `port`: 监听的端口必须不同
- `server_id`: mysqld 进程的 id 不同，用于主从

注意：<u>也可以在同一台机器上，进行不同版本mysql的多实例部署</u>

1. 准备配置文件，起多少个实例，需要准备多少个 mysql 的配置文件。
    - 这一步需要注意，datadir 数据目录，mysql 用户必须有读写的权限。`chown -R mysql.mysql /data`

```shell
# 实例1 
cat > /data/3307/my.cnf <<EOF
[mysqld]  
user=mysql  
basedir=/usr/local/mysql  
datadir=/data/3307/data
socket=/tmp/mysql3307.sock
server_id=7
port=3307
EOF

# 实例2
cat > /data/3308/my.cnf <<EOF
[mysqld]  
user=mysql  
basedir=/usr/local/mysql  
datadir=/data/3308/data
socket=/tmp/mysql3308.sock
server_id=8
port=3308
EOF

....
```



2. 启动 mysqld 进程

 - 初始化

    ```shell
    [root@localhost ~]# mysqld --defaults-file=/etc/my3307.cnf --initialize-insecure
    [root@localhost ~]# mysqld --defaults-file=/etc/my3308.cnf --initialize-insecure
    ```

 - 启动

    ```shell
    [root@localhost ~]# mysqld_safe --defaults-file=/etc/my3307.cnf &
    [root@localhost ~]# mysqld_safe --defaults-file=/etc/my3308.cnf &
    ```

    

## MySQL 日志管理

MySQL 一共有四种日志，分别是：

- **error log** ： 错误日志
- **genernal log** ： 普通日志
- **binlog** ： 二进制日志
- **slow log** ： 慢日志

### 1. 错误日志

作用：**从启动开始，发生过的error，warning，note信息**。

主要用来 定位数据库问题：

- 错误日志：

- 启动故障
- 主从故障
- 死锁
- 数据库hang时的堆栈信息



错误日志的配置 `log_error`：

```shell
[root@localhost ~]# cat /etc/my.cnf
[mysql]
socket=/tmp/mysql.sock
[mysqld]
user=mysql
basedir=/usr/local/mysql
datadir=/data/3306/data
server_id=51
port=3306
socket=/tmp/mysql.sock
log_error=/data/3306/log/mysql-err.log
```



<u>默认 log_error 的错误日志是存在 datadir 目录下的</u>。

这里注意，如果换了日志目录，需要给日志目录设置权限：

```shell
[root@localhost ~]# touch /data/3306/log/mysql-err.log
[root@localhost ~]# chown -R mysql.mysql /data/
```



错误日志当然是主要关注错误信息，也就是 [ERROR] 格式的信息：

```tex
主要关注： [ERROR]
[ERROR] [MY-000068] [Server] unknown option  ---》 配置文件有问题
```



错误日志的级别，一共有三种级别：

- `1` : 错误信息
- `2` : 错误信息和告警信息
- `3` : 错误信息、告警信息、通知信息

```mysql
mysql> show variables like '%log_error%';
+----------------------------+----------------------------------------+
| Variable_name       		 | Value                 				  |
+----------------------------+----------------------------------------+
| binlog_error_action    	 | ABORT_SERVER              			  |
| log_error         		 | /data/3306/log/mysql-err.log      	  |
| log_error_services     	 | log_filter_internal; log_sink_internal |
| log_error_suppression_list |                    					  |
| log_error_verbosity    	 | 2                    				  |
+----------------------------+----------------------------------------+
5 rows in set (0.00 sec)

mysql> set global log_error_verbosity=3;
```



### 2. 二进制日志（binlog）

**记录了MySQL 发生过的修改的操作的日志。除了show select ,修改操作都会记录 binlog**

可以用来：

- 数据恢复
- 主从
- SQL 问题排查
- 审计（需要工具，binlog2sql，my2sql）



配置binlog:

1. 8.0默认开启binlog 
2. <u>默认在 datadir 配置的目录下，文件名如 binlog.0000001</u>
3. 建议日志和数据分开存储
4. 配置参数：`server_id `(必须设置)与 `log_bin `

```shell
[root@localhost ~]# cat /etc/my.cnf
[mysql]
socket=/tmp/mysql.sock
[mysqld]
user=mysql
basedir=/usr/local/mysql
datadir=/data/3306/data
server_id=51
port=3306
socket=/tmp/mysql.sock
log_error=/data/3306/log/mysql-err.log
log_bin=/data/3306/log/mysql-bin
```





### 3. 慢日志（slow log）

**记录MySQL工作中，运行较慢的语句。用来定位SQL语句性能问题。**



- 开关：（默认没有打开），配置文件设置：

    ```mysql
    slow_query_log=1
    slow_query_log_file=/path/log/
    ```

    

- 维度:

    ```mysql
    # 开关
    set global slow_query_log=1
    # 运行超过多长时间，则记录，单位秒，一般 0.1-10s
    set global long_query_time=0.5
    # 把不用索引的语句记录下来
    set global log_queries_not_using_indexes=1
    # 只记录就近的 1000 个没有用索引的语句
    set global log_throttle_queries_not_using_indexes=1000;
    ```

    

### 4. general_log

**普通日志，会记录所有数据库发生的事件及语句**。



配置：（参数：`general_log `, `general_log_file`）

```shell
[root@localhost ~]# cat /etc/my.cnf
[mysql]
socket=/tmp/mysql.sock
[mysqld]
user=mysql
basedir=/usr/local/mysql
datadir=/data/3306/data
server_id=51
port=3306
socket=/tmp/mysql.sock
log_error=/data/3306/log/mysql-err.log
log_bin=/data/3306/log/mysql-bin
slow_query_log=1
slow_query_log_file=/data/3306/log/slow.log
long_query_time=0.5
log_queries_not_using_indexes=1
log_throttle_queries_not_using_indexes=1000
general_log=on
general_log_file=/data/3306/log/genlog
```

