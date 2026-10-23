# Sub-Store 管理面板

给 [Sub-Store](https://github.com/sub-store-org/Sub-Store) 的 Docker 部署套一个中文交互菜单：安装、更新、重启、卸载、CORS 配置，一条命令搞定。

不用记 docker 命令，也不用每次改 `docker-compose.yml`。

## 一键安装

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/YOURNAME/sub-store-manager@main/install.sh | sudo bash
```

装完直接输入：

```bash
substore
```

> 国内直连 `raw.githubusercontent.com` 常常超时，所以默认走 jsDelivr。
> 想锁定某个版本，把 `@main` 换成 commit hash，例如 `@a1b2c3d`。

## 菜单

```
  ╭──────────────────────────────────────────────╮
  │        Sub-Store  管理面板                   │
  ╰──────────────────────────────────────────────╯

   状态   ● 运行中  v2.43.1
   前端   http://1.2.3.4:3001/
   后端   http://1.2.3.4:3001/yNpTkeKuHN4SCyGi
   目录   /opt/sub-store

────────────────────────────────────────────────────
   1) 安装 / 重新部署
   2) 更新到最新版
   3) 重启服务
   4) 卸载
   5) 查看状态与地址
   6) 实时日志    (Ctrl+C 返回)
   7) 前端域名设置 (解决 403 CORS 报错)
   0) 退出
────────────────────────────────────────────────────
```

## 子命令

| 命令 | 说明 |
|---|---|
| `substore` | 打开交互菜单 |
| `substore install` | 安装或重新部署（会自动装 Docker） |
| `substore update` | 拉取最新镜像并重建容器，显示版本变化 |
| `substore restart` | 重启容器 |
| `substore uninstall` | 卸载，默认保留数据 |
| `substore status` | 打印状态、版本、前后端地址 |
| `substore logs` | 实时日志 |
| `substore cors` | 设置允许访问后端的前端来源 |
| `substore setup` | 把本脚本安装到 `/usr/local/bin/substore` |

## 它做了什么

- 数据目录固定在 `/opt/sub-store/data`，重装、升级都不会丢配置
- 端口和后端路径自动从现有 `docker-compose.yml` 读取
- 首次安装会生成 16 位随机后端路径，避免后台被扫描
- 卸载分两级确认：先删容器（保留数据），要连数据一起删必须手动输入 `yes`

## 常见问题

**前端报 `403 CORS origin not allowed`**

自建前端的域名不在白名单里。执行 `substore cors`，填入你在浏览器地址栏看到的完整来源（协议、域名、端口都要一致），脚本会重建容器并实测验证。

**页面打不开，`curl` 返回 `(52) Empty reply from server`**

说明端口映射到了容器内没有进程监听的端口。Sub-Store 开启 `SUB_STORE_BACKEND_MERGE=true` 时，前后端都在容器内的 **3000** 端口，所以映射必须是 `"3001:3000"`，写成 `"3001:3001"` 就会这样。

**容器反复重启**

先看 `substore logs`。常见原因是数据目录权限，或镜像架构与机器不符（ARM 机器上出现 `exec format error`）。

## 安全提示

这个脚本以 root 身份管理 Docker 容器和服务目录，安装前建议先看一眼源码：

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/YOURNAME/sub-store-manager@main/manage.sh | less
```

后端路径（`/opt/sub-store/.backend-path`）等同于后台密码，不要提交到任何仓库或截图外发。

## License

MIT
