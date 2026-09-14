# zhenxun_bot Linux 一键部署脚本

面向当前版 [zhenxun_bot](https://github.com/zhenxun-org/zhenxun_bot) 的交互式 Linux 部署与管理脚本。

脚本使用系统 Python 3.11 或更高版本、uv、项目虚拟环境和 systemd，不再使用旧版的 Python 3.8/3.9、Poetry、`bot.py` 或 go-cqhttp 集成。

## Windows 一键包

本仓库的 `install.sh` 仅用于 Linux。Windows 用户请使用官方 [Windows 一键整合包与安装教程](https://zhenxun-org.github.io/zhenxun_bot/beginner/)，按照页面说明下载整合包并运行 `启动与管理.bat`。Windows 一键包需要电脑已安装 Python 3.11 或更高版本。

## 主要特性

- 检测系统 Python，要求版本不低于 3.11。
- 首次部署默认从阿里云 Codeup 克隆代码，也可以选择 GitHub 公共仓库。
- 使用 `uv sync --frozen --no-dev --inexact` 创建和同步 `.venv`。
- 使用 `uv run zx` 启动当前版真寻。
- 创建 `zhenxun-bot.service`，支持启动、停止、重启、日志和开机启动。
- 启动和重启时不会自动拉取代码；只有选择“手动更新代码”才会更新。
- 首次生成 `.env.dev`，并将监听地址设为 `0.0.0.0`，便于从服务器外访问首次配置页面。
- 默认使用 SQLite。PostgreSQL、MySQL、Redis 和 QQ 协议端均按需单独部署。
- 全流程使用 UTF-8，并为 uv 使用复制模式，避免跨文件系统硬链接警告。

## 支持环境

- 使用 systemd 的 Linux 发行版。
- Debian / Ubuntu。
- RHEL / CentOS Stream / Rocky Linux / AlmaLinux / Fedora。
- Arch Linux / Manjaro。
- `x86_64` 或 `aarch64`。
- Python 3.11 或更高版本，并包含 `venv` 模块。

推荐使用 Ubuntu 24.04 或 Debian 12。脚本需要 root 权限来安装系统依赖和创建 systemd 服务，但真寻进程默认使用独立的 `zhenxun` 系统账号运行。

## 使用方法

服务器以 root 用户登录时，可以直接使用在线入口：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhenxun-org/zhenxun_bot-deploy/master/install.sh)
```

这种方式只会先载入 `install.sh`。选择 Codeup 后，安装器会自动下载并校验同一仓库中的 `init_codeup.py`，再由系统 Python 运行解析器完成鉴权拉取。

也可以先下载并检查脚本：

```bash
curl -fL https://raw.githubusercontent.com/zhenxun-org/zhenxun_bot-deploy/master/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

也可以在已经下载的仓库中运行：

```bash
cd zhenxun_bot-deploy
sudo bash install.sh
```

首次运行选择：

```text
1. 首次部署 / 修复环境
```

首次部署随后会询问代码源：

```text
1. 阿里云 Codeup（默认，国内推荐）
2. GitHub 公共仓库
```

选择 Codeup 时，部署脚本会调用仓库内配套的 `init_codeup.py`。该脚本沿用一键包的仓库映射和 Base64 编码访问令牌，解析后完成 Git 初始化及拉取；用户无需手动输入 Codeup 地址或令牌。若只单独下载了 `install.sh`，安装器会先下载同仓库中的配套解析器。

`init_codeup.py` 不会把明文令牌写入 `.git/config`，远端地址保持为不含凭证的 Codeup URL。需要注意，Base64 只是编码而不是加密；将带有内置令牌的仓库公开前，应确认该令牌允许公开分发并具备最小只读权限。

默认安装目录为：

```text
/opt/zhenxun/zhenxun_bot
```

安装完成后打开：

```text
http://服务器IP:8080/#/configure
```

脚本会根据 `.env.dev` 显示实际端口，并保留部署日志和配置地址，不会在返回主菜单时清屏。在配置页完成数据库、超级用户等基础配置；页面提示重启后，回到脚本选择“重启真寻”。

> 首次配置期间需要从可信网络访问 8080 端口。请使用防火墙限制来源，或通过 SSH 端口转发访问，不建议直接长期暴露到公网。

## 管理菜单

```text
1. 首次部署 / 修复环境
2. 启动真寻
3. 停止真寻
4. 重启真寻
5. 查看状态
6. 查看实时日志
7. 编辑 .env.dev
8. 依赖管理
9. 手动更新代码
10. 设置开机启动
11. 卸载真寻
0. 退出
```

脚本不会在普通启动、重启或重新打开菜单时执行 `git pull`。手动更新时，Codeup 仓库仍由 `init_codeup.py` 完成鉴权并执行快进更新，GitHub 仓库采用 `git fetch` 和 `git merge --ff-only`；如果目录存在无法快进的本地修改，更新会停止而不是覆盖文件。

## systemd 管理

安装完成后也可以直接使用：

```bash
sudo systemctl status zhenxun-bot
sudo systemctl restart zhenxun-bot
sudo journalctl -u zhenxun-bot -n 100 -f
```

服务文件位于：

```text
/etc/systemd/system/zhenxun-bot.service
```

部署配置保存在：

```text
/etc/zhenxun-bot-deploy.conf
```

## 可选环境变量

运行脚本前可以覆盖部分默认值：

```bash
sudo ZHENXUN_WORK_DIR=/srv/zhenxun \
     ZHENXUN_USER=zhenxun \
     UV_INDEX_URL=https://pypi.org/simple \
     bash install.sh
```

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ZHENXUN_WORK_DIR` | `/opt/zhenxun` | 工作目录 |
| `ZHENXUN_USER` | `zhenxun` | systemd 运行账号 |
| `ZHENXUN_GROUP` | `zhenxun` | 首次创建账号时使用的组 |
| `ZHENXUN_REPO` | 官方公共 GitHub 仓库 | 代码仓库地址 |
| `UV_INDEX_URL` | 阿里云 PyPI 镜像 | Python 包索引 |

## 数据与卸载

重要数据主要位于：

```text
/opt/zhenxun/zhenxun_bot/.env.dev
/opt/zhenxun/zhenxun_bot/data
/opt/zhenxun/zhenxun_bot/resources
```

卸载选项要求输入 `DELETE` 二次确认，并会删除整个 `zhenxun_bot` 目录。卸载前请先备份上述内容。

卸载不会删除：

- 系统安装的软件包。
- `zhenxun` 系统账号。
- 外部 PostgreSQL、MySQL 或 Redis 数据。
- 防火墙和反向代理配置。

## 与旧版脚本的区别

- 删除已停止维护的 go-cqhttp 下载与管理逻辑；请自行选择当前可用的 OneBot V11 协议端。
- 删除固定 PostgreSQL 用户、数据库和密码，当前版默认可使用 SQLite。
- 删除根目录旧版 `config.yaml` 示例；当前插件配置在首次启动后生成到 `data/config.yaml`。
- 删除远程自更新脚本逻辑，避免运行时覆盖本地管理脚本。
- 不再通过 `pgrep` 和 `kill -9` 猜测进程，统一交给 systemd 管理。
- 不再自动覆盖 `.env.dev` 或用户数据。

## 常见问题

### 找不到 Python 3.11+

请先使用发行版包管理器安装 Python 3.11 或更高版本及对应的 venv 包。例如 Debian 12：

```bash
sudo apt update
sudo apt install python3 python3-venv
```

### 服务启动失败

运行：

```bash
sudo journalctl -u zhenxun-bot -n 100 --no-pager
```

重点检查 `.env.dev`、数据库地址、端口占用和 Playwright 依赖。

### 后台无法访问

检查以下项目：

- `.env.dev` 中的 `HOST` 是否为 `0.0.0.0`。
- 云服务器安全组和系统防火墙是否允许 TCP 8080。
- 服务是否正在运行：`systemctl status zhenxun-bot`。
- 若不希望开放端口，可使用 SSH 转发：`ssh -L 8080:127.0.0.1:8080 user@server`。
