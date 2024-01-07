[toc]

# MySQL 8.0 的用户授权管理

## 1. 用户及安全管理



### 1.1 用户的组成

用户由用户名，允许用户访问的白名单地址，密码等组成

```mysql
用户名@'白名单'
oldguo@'%'              所有地址
oldguo@'10.0.0.1'
oldguo@'10.0.0.%'       24  掩码  1-254
oldguo@'10.0.0.5%'      50-59
oldguo@'localhost'      数据库本地socket
```

白名单：
- `%` : 通配符，允许所有地址
- `10.0.0.%` : 1-254
- `xxx.com` : 域名/别名/主机名
- `localhost/127.0.0.1`: 数据库本地， 也就是 socket 连接


### 1.2 用户的管理


1. 查询用户
    - user, 用户
    - host, 允许访问的白名单列表
    - authentication_string, 密码
    - plugin, 密码插件
```mysql
mysql> select user, host, authentication_string, plugin from mysql.user;
+------------------+-----------+------------------------------------------------------------------------+-----------------------+
| user             | host      | authentication_string                                                  | plugin                |
+------------------+-----------+------------------------------------------------------------------------+-----------------------+
| root             | %         | $A$005$B}f{N<cF[x4RaEqwwEUnUUw.eS5bqnnWgEhuyIRB/5kqL6fcwdVf0 | caching_sha2_password |
| mysql.infoschema | localhost | $A$005$THISISACOMBINATIONOFINVALIDSALTANDPASSWORDTHATMUSTNEVERBRBEUSED | caching_sha2_password |
| mysql.session    | localhost | $A$005$THISISACOMBINATIONOFINVALIDSALTANDPASSWORDTHATMUSTNEVERBRBEUSED | caching_sha2_password |
| mysql.sys        | localhost | $A$005$THISISACOMBINATIONOFINVALIDSALTANDPASSWORDTHATMUSTNEVERBRBEUSED | caching_sha2_password |
7 root             | localhost | $A$005$
.2}U3j=~ %      /{MUZBOmLLFhEuv/U5eG5UOCs/YwmEYZpeM0Nvmb/XMF5 | caching_sha2_password |
+------------------+-----------+------------------------------------------------------------------------+-----------------------+
5 rows in set (0.00 sec)


```

2. 创建用户
    - with mysql_native_password : 表示使用旧的密码策略
    - identified: 表示设置密码
    - 这里注意，密码插件可能会导致的潜在问题：
        - 主从
        - 高可用
        - 老版本开发工具
```mysql
# 新版本默认使用 caching_sha2_password 密码加密策略
mysql> create user gsh@'192.1168.0.*' identified by 'gsh123';
Query OK, 0 rows affected (0.30 sec)

# 老版本密码策略 mysql_native_password 
mysql> create user test@'%' identified with mysql_native_password by 'gsh123';
Query OK, 0 rows affected (0.00 sec)

```


3. 修改用户
    - 一般不建议修改用户名和用户白名单，建议删除用户重建
    - 但也有修改用户的方法，直接修改 mysql.user 表中的数据，这样会造成之前用户的权限有可能会丢失
    - 有修改密码的命令
```mysql
# 修改用户密码
mysql> alter user test@'%' identified by 'gsh123';
Query OK, 0 rows affected (0.00 sec)


# 修改用户密码及密码策略
mysql> alter user test@'%' identified with mysql_native_password by 'gsh123';
Query OK, 0 rows affected (0.01 sec)

```

4. 锁定用户
    - 用户锁定后，无法再登录
    - 查看用户是否锁定，通过 mysql.user 表中的 account_locked 字段
    - account unclok 解锁
```mysql
# 锁定用户
mysql> alter user test@'%' account lock;
Query OK, 0 rows affected (0.00 sec)

mysql> select user, host, authentication_string, plugin, account_locked from mysql.user;
+------------------+--------------+------------------------------------------------------------------------+-----------------------+----------------+
| user             | host         | authentication_string                                                  | plugin                | account_locked |
+------------------+--------------+------------------------------------------------------------------------+-----------------------+----------------+
| root             | %            | $A$005$B}f{N<cF[x4RaEqwwEUnUUw.eS5bqnnWgEhuyIRB/5kqL6fcwdVf0 | caching_sha2_password | N              |
| test             | %            | *66098B1562EB53E0C33A6922F0640604C3B42B0A                              | mysql_native_password | Y              |
| gsh              | 192.1168.0.* | $A$005$H3
^ u,-m]uy9@Xe/Rw3cbF7/IQRAV8P6LgC8IXkjwYxs3wg9Wcxg1slc3 | caching_sha2_password | N              |
| mysql.infoschema | localhost    | $A$005$THISISACOMBINATIONOFINVALIDSALTANDPASSWORDTHATMUSTNEVERBRBEUSED | caching_sha2_password | Y              |
| mysql.session    | localhost    | $A$005$THISISACOMBINATIONOFINVALIDSALTANDPASSWORDTHATMUSTNEVERBRBEUSED | caching_sha2_password | Y              |
| mysql.sys        | localhost    | $A$005$THISISACOMBINATIONOFINVALIDSALTANDPASSWORDTHATMUSTNEVERBRBEUSED | caching_sha2_password | Y              |
7 root             | localhost    | $A$005$
.2}U3j=~ %      /{MUZBOmLLFhEuv/U5eG5UOCs/YwmEYZpeM0Nvmb/XMF5 | caching_sha2_password | N              |
+------------------+--------------+------------------------------------------------------------------------+-----------------------+----------------+
7 rows in set (0.00 sec)


# 解锁用户
mysql> alter user test@'%' account unlock;
Query OK, 0 rows affected (0.00 sec)

```


5. 设置用户密码过期时间
    - 通过 password expire 命令修改
```mysql
# 修改用户密码过期时间
mysql> alter user test@'%' password expire interval 10 day;
Query OK, 0 rows affected (0.00 sec)


# 或者可以在创建用户时设置
mysql> CREATE USER 'test'@'localhost' PASSWORD EXPIRE NEVER;


# 修改全局变量，设置默认的密码过期时间
mysql> select @@default_password_lifetime;
+-----------------------------+
| @@default_password_lifetime |
+-----------------------------+
|                           0 |
+-----------------------------+
1 row in set (0.00 sec)

mysql> SET PERSIST default_password_lifetime = 180;
```

6. 设置用户登录错误重试次数
    - 通过 failed_login_attempts 设置
```mysql
# 设置用户登录错误重试次数
mysql> alter user test@'%' failed_login_attempts 10;
Query OK, 0 rows affected (0.00 sec)

```

6. 其他修改用户，可以通过 `help create user;` 命令查看

7. 删除用户
    - 这里需要注意，用户名和白名单唯一标识一个用户。
```mysql
# 删除用户
mysql> drop user test@'%';
Query OK, 0 rows affected (0.00 sec)
```

### 1.3 root 密码忘记处理

原理，在mysql启动的时候，在连接层，不让mysql加载认证授权表，关闭验证功能。

1. 关闭数据库
```shell
/etc/init.d/mysqld stop
```
2. 安全模式启动数据库
    - --skip-grant-tables: 关闭授权表的加载
    - --skip-networking: 禁止远程网络连接(tcp/ip)，只能本地 socket 连接
```shell
[root@localhost data]# mysqld_safe --skip-grant-tables --skip-networking &
```
3. 登陆数据库
```shell
mysql
```
4. 刷新授权表
    - 因为启动mysql的时候没有加载授权表，因此不能修改用户密码
    - 使用 flush privileges 加载授权表
```mysql
flush privileges;
```
5. 修改密码
```mysql
mysql> alter user root@'localhost' identified with mysql_native_password by '123';
```
6. 重启数据库到正常模式
```shell
[root@localhost data]# /etc/init.d/mysqld restart
```


### 1.4 8.0 新特性


1. 密码插件,在8.0中替换为了 sha2模式
2. 在8.0中不支持grant直接创建用户并授权，必须先建用户后grant授权。



当前，关于密码插件sha2带来的坑？
- 客户端工具，navicat 、 sqlyog工具不支持（无法连接）
- 主从复制，MGR ，不支持新的密码插件的用户 
- 老的驱动无法连接数据库

解决方法：
- `create with mysql_native_password`
- `alter with mysql_native_password`
- 修改默认密码插件：`vim /etc/my.cnf`
    - 修改 `default_authentication_plugin=mysql_native_password`




## 2. 权限设置

权限设置的命令：
```mysql
GRANT 权限 ON 权限级别 TO 用户;
```




### 2.1 权限级别

mysql 中定义了四种权限级别：
- `*.*` : 全库级别，一般是管理员操作，存储位置在 mysql.user 表
- `test.*` : 单库级别，一般是业务层面，存储位置在 mysql.db 表
- `test.t1` : 单表级别，不常用，存储位置在 mysql.tables_priv 表
- `select(id,name) on test.t1` : 列级别，不常用，存储位置在 mysql.columns_priv 表


### 2.2 权限 & 角色(role)

mysql 8.0 加入了角色的概念，角色就是一系列权限的集合。


查看权限列表：`show privileges`
```mysql
mysql> show privileges;
+------------------------------+---------------------------------------+-------------------------------------------------------+
| Privilege                    | Context                               | Comment                                               |
+------------------------------+---------------------------------------+-------------------------------------------------------+
| Alter                        | Tables                                | To alter the table                                    |
| Alter routine                | Functions,Procedures                  | To alter or drop stored functions/procedures          |
| Create                       | Databases,Tables,Indexes              | To create new databases and tables                    |
| Create routine               | Databases                             | To use CREATE FUNCTION/PROCEDURE                      |
| Create role                  | Server Admin                          | To create new roles                                   |
| Create temporary tables      | Databases                             | To use CREATE TEMPORARY TABLE                         |
| Create view                  | Tables                                | To create new views                                   |
| Create user                  | Server Admin                          | To create new users                                   |
| Delete                       | Tables                                | To delete existing rows                               |
| Drop                         | Databases,Tables                      | To drop databases, tables, and views                  |
| Drop role                    | Server Admin                          | To drop roles                                         |
| Event                        | Server Admin                          | To create, alter, drop and execute events             |
| Execute                      | Functions,Procedures                  | To execute stored routines                            |
| File                         | File access on server                 | To read and write files on the server                 |
| Grant option                 | Databases,Tables,Functions,Procedures | To give to other users those privileges you possess   |
| Index                        | Tables                                | To create or drop indexes                             |
| Insert                       | Tables                                | To insert data into tables                            |
....
| ENCRYPTION_KEY_ADMIN         | Server Admin                          |                                                       |
+------------------------------+---------------------------------------+-------------------------------------------------------+
68 rows in set (0.00 sec)

```


生产中用户权限类型规范：

- 管理员: `All`
- 开发: `Create, Create routine,  Create temporary tables, Create view, Delete, Event, Execute, References, Insert, Select, Show databases, Show view, Trigger, Update`
- 监控: `Select, Replication slave, Replication client, Super`
- 备份: `Select, Show databases, Reload, Process, Lock tables`
- 主从: `Replication slave, Replication client`
- 业务: `insert, update, delete, select`

注意，一般除了管理员，都没有 drop 权限。




### 2.3 授权管理命令


1. 普通权限授权
    - 权限级别：全库级别
    ```mysql
    mysql> grant all on *.* to test@'%';
    Query OK, 0 rows affected (0.01 sec)
    ```
    - 权限级别：单库级别
    ```mysql
    mysql> grant select, update, delete, insert on test.* to test@'%';
    Query OK, 0 rows affected (0.00 sec)
    ```
    - 权限级别：单表级别
    ```mysql
    mysql> grant select, update, delete, insert on test.user to test@'%';
    Query OK, 0 rows affected (0.00 sec)
    ```
    - 权限级别：列级别
    ```mysql
    mysql> grant select(id) on test.user to test@'%';
    Query OK, 0 rows affected (0.01 sec)
    ```
    - 注意，all 权限其实是没有分配权限的权限的，可以通过 with grant_option 添加：`grant all on *.*  to test@'%' with grant option;`
    
    
    
2. 查看用户权限
    - `show grants for [USER]`
    ```mysql
    mysql> show grants for test@'%';
    +------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
    | Grants for test@%                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
    +------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
    | GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, RELOAD, SHUTDOWN, PROCESS, FILE, REFERENCES, INDEX, ALTER, SHOW DATABASES, SUPER, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, REPLICATION SLAVE, REPLICATION CLIENT, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, CREATE USER, EVENT, TRIGGER, CREATE TABLESPACE, CREATE ROLE, DROP ROLE ON *.* TO `test`@`%` WITH GRANT OPTION                                                                                                                                                                                                                                                                                                                                                                 |
    | GRANT APPLICATION_PASSWORD_ADMIN,AUDIT_ABORT_EXEMPT,AUDIT_ADMIN,AUTHENTICATION_POLICY_ADMIN,BACKUP_ADMIN,BINLOG_ADMIN,BINLOG_ENCRYPTION_ADMIN,CLONE_ADMIN,CONNECTION_ADMIN,ENCRYPTION_KEY_ADMIN,FIREWALL_EXEMPT,FLUSH_OPTIMIZER_COSTS,FLUSH_STATUS,FLUSH_TABLES,FLUSH_USER_RESOURCES,GROUP_REPLICATION_ADMIN,GROUP_REPLICATION_STREAM,INNODB_REDO_LOG_ARCHIVE,INNODB_REDO_LOG_ENABLE,PASSWORDLESS_USER_ADMIN,PERSIST_RO_VARIABLES_ADMIN,REPLICATION_APPLIER,REPLICATION_SLAVE_ADMIN,RESOURCE_GROUP_ADMIN,RESOURCE_GROUP_USER,ROLE_ADMIN,SENSITIVE_VARIABLES_OBSERVER,SERVICE_CONNECTION_ADMIN,SESSION_VARIABLES_ADMIN,SET_USER_ID,SHOW_ROUTINE,SYSTEM_USER,SYSTEM_VARIABLES_ADMIN,TABLE_ENCRYPTION_ADMIN,XA_RECOVER_ADMIN ON *.* TO `test`@`%` WITH GRANT OPTION |
    | GRANT SELECT, INSERT, UPDATE, DELETE ON `test`.* TO `test`@`%`
    ```
    - 也可以根据不同的权限级别，查找不同的表



3. 回收权限
    - `revoke [权限] on [权限级别] from [USER]`
```mysql
mysql> revoke delete on test.* from test@'%';
Query OK, 0 rows affected (0.00 sec)

```

4. 角色创建及授权
    - 角色创建：`create role [ROLE_NAME]`，这里的 ROLE_NAME 于用户类似，表示为：`role@'ip'`
    ```mysql
    mysql> create role dev@'%';
    Query OK, 0 rows affected (0.01 sec)
    ```
    - 给角色分配权限：`grant [权限] on [权限级别] to [ROLE_NAME]`，于给用户分配角色类似
    ```mysql
    mysql> grant select on *.* to dev@'%';
    Query OK, 0 rows affected (0.00 sec)
    ```
    - 给用户授予角色：`grant [ROLE_NAME] to [USER]`
    ```mysql
    mysql> grant dev to test@'%';
    Query OK, 0 rows affected (0.00 sec)
    ```
    - 查询角色：`select * from mysql.role_edges;`
    ```mysql
    mysql> select * from mysql.role_edges;
    +-----------+-----------+---------+---------+-------------------+
    | FROM_HOST | FROM_USER | TO_HOST | TO_USER | WITH_ADMIN_OPTION |
    +-----------+-----------+---------+---------+-------------------+
    | %         | dev       | %       | test    | N                 |
    +-----------+-----------+---------+---------+-------------------+
    1 row in set (0.00 sec)
    ```



