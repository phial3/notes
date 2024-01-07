realm 表

- id - 自增 - primary Key
- create_time - 创建时间
- update_time - 更新时间
- name - realm 名称，公司或者组织名称
- display_name - realm 全称
- enabled - 允许禁用
- uuid - realm uuid
- password_policy - text 密码策略
- registration_allowed - bit(1) 是否允许登录页显示注册
- reset_password_allowed - 是否允许用户在登录页重置密码
- edit_username_allowed - 是否允许编辑用户名
- remember_me - 在登录页面上显示复选框以允许用户在浏览器重新启动之间保持登录状态，直到会话过期。
- verify_email - 要求用户在首次登录后或提交地址更改后验证其电子邮件地址。
- login_with_email_allowed - 允许用户使用他们的电子邮件地址登录。
- reg_email_as_username - 允许用户将电子邮件设置为用户名
- default_role - 默认的角色

realm-attributes

- realm_id - realm uuid
- name - 属性名
- value - 属性值

