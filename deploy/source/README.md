# ARL-Next 源码模式部署（A 模式：完全脱离容器）

本文档描述如何在 Linux 服务器上以**纯源码方式**运行 ARL-Next 全功能（扫描 / 截图渲染 / 备案查询 / 监控调度 / Web UI），不依赖 Docker。

> **范围说明**：按需求，本模式**不包含**「一键系统更新」与「数据备份恢复」两项功能，相关依赖（updater 守护进程、mongodb-database-tools）无需安装。

---

## 一、开始之前：三件必须先知道的事

### 1. 发行版支持与选择

`start-local.sh` 同时支持两类发行版，并已实测通过：

| 发行版族 | 实测环境 | 说明 |
| :--- | :--- | :--- |
| **dnf 系** | CentOS Stream 10 (x86_64, 1C/923MB) | 全流程实测通过，含扫描、截图、备案查询、监控调度 |
| **apt 系** | Debian / Ubuntu | 走官方源与发行版包，路径与容器最接近 |

**关于 Chromium 路径**：`backend/app/tools/puppeteer_server.js:102` **硬编码** `executablePath: '/usr/bin/chromium'`。各发行版的二进制位置不同——Debian 在 `/usr/bin/chromium`，EPEL 系在 `/usr/bin/chromium-browser`——脚本会自动创建软链补齐，无需手工处理。Ubuntu 的 `chromium` 是 snap 包装壳，路径行为不一致，建议改用 Debian 或 RHEL 系。

### 2. RHEL / CentOS 系的 SELinux 注意事项

若目标系统 SELinux 为 `Enforcing`（CentOS/RHEL 默认），脚本会自动处理以下四处，**手工部署时务必逐项确认**，否则会表现为「服务起不来但报错信息极具误导性」：

| 现象 | 真实原因 | 处理 |
| :--- | :--- | :--- |
| `systemctl start mongod` 报 `203/EXEC` / `Permission denied` | 经 `/tmp` 解压再 `mv` 的二进制带有 `user_tmp_t` 上下文 | `chcon -R -t bin_t` + `semanage fcontext` |
| `nginx -t` 报配置 `Permission denied` | 配置文件经 `/tmp` 中转，上下文为 `user_tmp_t` | 在目标目录内创建文件，再 `restorecon -F` |
| nginx 启动失败 / 无法监听 5173 | `http_port_t` 默认不含 5173 | `semanage port -a -t http_port_t -p tcp 5173` |
| 登录接口 **502 Bad Gateway** | `httpd_can_network_connect` 默认 `off`，nginx 不能反代本机后端 | `setsebool -P httpd_can_network_connect on` |

另需将前端产物与证书目录标记为 `httpd_sys_content_t`（脚本已自动完成）。

### 3. 服务以 root 运行（与容器一致）

`nmap` 的 SYN 扫描与 `massdns` 的 DNS 发包都需要 **raw socket 权限**。容器内是 root，非 root 运行会导致 nmap 静默降级为 TCP connect 扫描（更慢、结果更少），massdns 则直接失败。降权方案见文末「可选加固」。

### 4. Basic Auth 一键开关会失效（这是被低估的一项）

顶部导航栏的 Basic Auth 开关，前端调的是 `/update_stream/auth_status`（`frontend/src/views/Layout.vue:868`），由 **updater 守护进程**提供——和"一键更新"是同一个服务。不部署 updater 后：

- 开关会显示「Basic Auth 控制服务未连接」并置灰（前端已内置优雅降级，不会报错）
- Basic Auth 改为在 nginx 配置里静态开关，见第五节第 10 步

如果这个开关对你是必需的，需要在「保留 updater（但它同时会响应更新请求，点一下就会把源码部署换成容器）」和「自行把该接口搬到后端」之间二选一。

---

## 二、功能对照

| 功能 | 源码模式 | 说明 |
| :--- | :--- | :--- |
| Web UI / REST API / Swagger | ✅ | gunicorn + nginx |
| 任务扫描（端口 / 域名爆破 / 指纹 / PoC） | ✅ | 需原生 nmap + massdns + nuclei |
| 站点截图与 Web 指纹识别 | ✅ | 需 Node + Chromium |
| 备案查询 / 企业测绘（osint-service） | ✅ | 独立 Python 服务 |
| 监控任务调度与消息推送 | ✅ | `app.scheduler` + Celery Beat |
| GeoIP 归属地解析 | ✅ | `tools/fetch_geoip.py` |
| 一键系统更新 | ❌ 有意移除 | |
| 数据备份 / 恢复 | ❌ 有意移除 | 页面调用会报错，属预期 |
| Basic Auth 一键开关 | ❌ 随 updater 一起移除 | 改为 nginx 静态配置 |

---

## 三、路径约定

全文以 **`/opt/arl-next`** 作为部署目录。装在别处时，把 `deploy/source/*.service` 与 `nginx-arl.conf` 里的该路径整体替换即可：

```bash
sed -i 's#/opt/arl-next#/your/path#g' deploy/source/*.service deploy/source/nginx-arl.conf
```

---

## 四、系统依赖与原生二进制

### 1. 编译工具链与运行库

```bash
apt-get update
apt-get install -y wget unzip bzip2 git curl tzdata ca-certificates \
    make gcc g++ automake autoconf libtool python3-dev \
    libxml2-dev libxslt1-dev zlib1g-dev libffi-dev libssl-dev libpcap-dev \
    python3 python3-pip python3-venv openssl nginx
```

> `libpcap-dev` 是 massdns 的编译依赖；`libssl/libxml2/libxslt/zlib/libffi` 是 Python 运行库依赖。

### 2. massdns（必须源码编译，无发行版包）

```bash
cd /tmp
wget -t 10 https://github.com/blechschmidt/massdns/archive/refs/tags/v1.1.0.tar.gz \
  || wget -t 10 https://gh-proxy.com/https://github.com/blechschmidt/massdns/archive/refs/tags/v1.1.0.tar.gz
tar xvf v1.1.0.tar.gz && cd massdns-1.1.0 && make -j"$(nproc)"
cp bin/massdns /usr/local/bin/ && cd /tmp && rm -rf massdns*
```

### 3. nmap

```bash
apt-get install -y nmap
```

代码通过 `backend/app/utils/nmap.py:80-84` 的搜索路径元组查找（含裸 `nmap`），发行版版本即可用。容器内是源码编译的 7.95，为的是「2500+ 服务指纹与 336 种现代 OS 指纹」；若你的发行版 nmap 偏旧且在意指纹覆盖率，可参照 `Dockerfile.prod:29-39` 自行编译 7.95。

### 4. nuclei + 模板

```bash
ARCH=$(dpkg --print-architecture)   # amd64 或 arm64
cd /tmp
wget -t 10 "https://github.com/projectdiscovery/nuclei/releases/download/v3.11.0/nuclei_3.11.0_linux_${ARCH}.zip" \
  || wget -t 10 "https://gh-proxy.com/https://github.com/projectdiscovery/nuclei/releases/download/v3.11.0/nuclei_3.11.0_linux_${ARCH}.zip"
unzip "nuclei_3.11.0_linux_${ARCH}.zip" && mv nuclei /usr/local/bin/ && chmod +x /usr/local/bin/nuclei
rm -rf /tmp/nuclei*
nuclei -update-templates
```

> **注意**：服务以 root 运行，模板会落在 `/root/nuclei-templates` —— 正是 `backend/app/services/nuclei_template_service.py:38` 的首选搜索路径，无需额外配置。若你改成非 root 运行，模板需放在该用户家目录的 `nuclei-templates` 下。

---

## 五、部署步骤

### 1. 获取代码

```bash
mkdir -p /opt && cd /opt
git clone https://github.com/owl234/ARL-Next.git arl-next
cd /opt/arl-next
```

### 2. MongoDB 7.0

```bash
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor
echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main" > /etc/apt/sources.list.d/mongodb-org-7.0.list
apt-get update && apt-get install -y mongodb-org
```

编辑 `/etc/mongod.conf`，与容器参数对齐（`docker-compose.prod.yml:138-143`）：

```yaml
net:
  port: 27017
  bindIp: 127.0.0.1          # 只监听本机，不对外暴露
storage:
  wiredTiger:
    engineConfig:
      cacheSizeGB: 1         # 对齐容器 --wiredTigerCacheSizeGB 1
```

先以无鉴权模式启动并创建管理员（对应容器的 `MONGO_INITDB_ROOT_USERNAME/PASSWORD=admin`）：

```bash
systemctl enable --now mongod
mongosh --quiet --eval '
db.getSiblingDB("admin").createUser({
  user: "admin", pwd: "admin",
  roles: [{ role: "root", db: "admin" }]
})'
```

然后启用鉴权并重启：

```yaml
security:
  authorization: enabled
```

```bash
systemctl restart mongod
mongosh "mongodb://admin:admin@127.0.0.1:27017/?authSource=admin" --quiet --eval 'db.runCommand({ping:1})'
```

> **上线前请改掉 admin/admin**，并同步修改 `backend/config.yaml` 的 `MONGO.URI`。

### 3. RabbitMQ

```bash
apt-get install -y rabbitmq-server
```

**关键一步**——容器通过 `RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS` 设置了超长消费超时（`docker-compose.prod.yml:161`）。**不设置这一项，长时间扫描任务会被 broker 以 ack 超时强制中断**：

```bash
cat > /etc/rabbitmq/rabbitmq.conf <<'EOF'
consumer_timeout = 2592000000
EOF
systemctl enable --now rabbitmq-server
```

创建账号（对应容器的 `RABBITMQ_DEFAULT_USER/PASS=admin`）：

```bash
rabbitmqctl add_user admin admin
rabbitmqctl set_user_tags admin administrator
rabbitmqctl set_permissions -p / admin ".*" ".*" ".*"
rabbitmqctl status | head -5
```

### 4. Node.js 与 Chromium（截图渲染服务）

```bash
apt-get install -y nodejs npm chromium \
    libnss3 libatk-bridge2.0-0 libgtk-3-0 libx11-xcb1 libxcb-dri3-0 \
    libxcomposite1 libxdamage1 libxrandr2 libgbm1 libasound2 \
    libxshmfence1 libdrm2 libxkbcommon0 libatspi2.0-0 libcups2 \
    fontconfig fonts-wqy-zenhei fonts-wqy-microhei

npm install -g puppeteer-core@10.4.0

# 校验：容器内同样依赖这两个绝对路径
/usr/bin/chromium --version
npm root -g          # 应输出 /usr/local/lib/node_modules；不同则改 arl-puppeteer.service 的 NODE_PATH
```

> 中文字体（`fonts-wqy-*`）不能省——否则站点截图里的中文会变成方块。

### 5. Python 环境

**后端主环境：**

```bash
cd /opt/arl-next/backend
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt
.venv/bin/pip install -e ARL-NPoC/
```

**osint-service 独立环境：**

```bash
cd /opt/arl-next/backend/osint_service
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt
```

> **Python 版本提示**：容器使用 Python 3.13，Debian 12 自带的是 3.11。`requirements.txt` 里的若干旧 pin（`psutil==5.7.2`、`mmh3==3.0.0`、`pyOpenSSL==22.1.0`）在 3.11 上没有预编译 wheel，会走源码构建——第四节第 1 步已装 `gcc` 与 `python3-dev`，通常可以顺利编译。若某个包构建失败，再考虑单独安装 Python 3.13 对齐容器。

### 6. GeoIP 数据

三个库文件约 88MB，不入版本库，需按需获取（无需 Docker）：

```bash
cd /opt/arl-next
python3 tools/fetch_geoip.py --dir backend/GeoLite2
# 如需精确城市级解析，追加 MaxMind 许可 key：
# MAXMIND_LICENSE_KEY=<你的key> python3 tools/fetch_geoip.py --dir backend/GeoLite2
```

> 无 MaxMind key 时 GeoLite2 会跳过，服务降级运行（ip2region 仍可用），不阻断扫描。

### 7. 主机名别名（关键：零代码改动）

源码中有 3 处硬编码的容器主机名，用 `/etc/hosts` 别名即可全部覆盖，**不需要改任何源码**：

```bash
cat >> /etc/hosts <<'EOF'

# ARL-Next 源码模式：兼容源码中硬编码的容器主机名
127.0.0.1 mongodb osint-service arl-puppeteer
EOF
```

| 硬编码位置 | 别名作用 |
| :--- | :--- |
| `backend/osint_service/clients/job_runner.py:12` | `mongodb:27017` |
| `backend/app/routes/icp.py:23` | `http://osint-service:16181` |
| `backend/app/services/siteScreenshot.py:10`、`webAnalyze.py:9` | `http://arl-puppeteer:5005` 默认值 |

### 8. 生成配置文件

```bash
cd /opt/arl-next
cp backend/config.yaml.example backend/config.yaml
```

模板里是**容器路径与容器发布端口**，需改 7 处：

```bash
sed -i \
  -e 's#127.0.0.1:27018#127.0.0.1:27017#g' \
  -e 's#127.0.0.1:5673#127.0.0.1:5672#g' \
  -e 's#/code/backend/GeoLite2/#/opt/arl-next/backend/GeoLite2/#g' \
  -e 's#/code/backend/app/dicts/#/opt/arl-next/backend/app/dicts/#g' \
  backend/config.yaml
```

| 配置项 | 原值 | 改为 |
| :--- | :--- | :--- |
| `CELERY.BROKER_URL` | `...@127.0.0.1:5673/` | `...@127.0.0.1:5672/` |
| `MONGO.URI` | `...@127.0.0.1:27018/...` | `...@127.0.0.1:27017/...` |
| `GEOIP.CITY` / `ASN` / `IP2REGION` | `/code/backend/GeoLite2/...` | `/opt/arl-next/backend/GeoLite2/...` |
| `ARL.DOMAIN_DICT` | `/code/backend/app/dicts/...` | `/opt/arl-next/backend/app/dicts/...` |
| `ARL.FILE_LEAK_DICT` | 同上 | 同上 |

> 其余 `backend/app/dicts`、`tmp`、`tmp_screenshot` 等路径在 `backend/app/config.py:134-185` 中均由 `basedir` 推导，**源码模式下天然正确，无需改动**。

### 9. 构建前端

前端用 **pnpm**（仓库内有 `pnpm-lock.yaml`，与 `frontend/Dockerfile.prod` 一致）：

```bash
cd /opt/arl-next/frontend
npm install -g pnpm@9
pnpm install --frozen-lockfile
pnpm run build          # 产物在 frontend/dist，同时生成 .gz 供 nginx gzip_static 使用
```

### 10. SSL 证书

```bash
cd /opt/arl-next
mkdir -p ssl-certs
openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -subj "/C=CN/ST=GD/L=SZ/O=ARL/CN=localhost" \
    -keyout ./ssl-certs/arl.key -out ./ssl-certs/arl.crt
chmod 644 ./ssl-certs/arl.key ./ssl-certs/arl.crt
```

> 有真实域名证书时，重命名为 `arl.crt` / `arl.key` 放入该目录即可。
> Basic Auth 凭据文件（仅在开启时需要）：
> ```bash
> echo "admin:$(openssl passwd -apr1 '你的密码')" > frontend/.htpasswd
> ```

### 11. Nginx

```bash
cp /opt/arl-next/deploy/source/nginx-arl.conf /etc/nginx/conf.d/arl.conf
nginx -t && systemctl enable --now nginx && systemctl reload nginx
```

> `gzip_static` 需要 `ngx_http_gzip_static_module`：Debian/Ubuntu 与 nginx.org 官方源均默认包含；RHEL 系若报 unknown directive 需安装对应模块包。
> 防火墙放行：`ufw allow 5173/tcp` 或 `firewall-cmd --permanent --add-port=5173/tcp && firewall-cmd --reload`。

### 12. systemd 服务

```bash
cp /opt/arl-next/deploy/source/*.service /etc/systemd/system/
chmod +x /opt/arl-next/deploy/source/start-worker.sh
systemctl daemon-reload

systemctl enable --now arl-web arl-worker arl-osint arl-puppeteer
```

### 13. 验证

```bash
# 服务状态（4 个都应为 active (running)）
systemctl status arl-web arl-worker arl-osint arl-puppeteer --no-pager

# 原生二进制（massdns 无 --version，用 command -v 确认可执行）
nmap --version | head -1
nuclei -version 2>&1 | head -1
command -v massdns && echo "massdns OK"
/usr/bin/chromium --version

# 后端 API 与前端网关
curl -s http://127.0.0.1:5000/ >/dev/null && echo "后端 OK"
curl -k -s -o /dev/null -w "网关 HTTP %{http_code}\n" https://127.0.0.1:5173/

# 依赖连通性
mongosh "mongodb://admin:admin@127.0.0.1:27017/?authSource=admin" --quiet --eval 'db.runCommand({ping:1})'
rabbitmqctl list_users
```

浏览器访问 `https://<服务器IP>:5173`，默认账号 `admin` / `arlpass`。

---

## 六、日常运维

```bash
systemctl restart arl-web arl-worker arl-osint arl-puppeteer   # 重启全栈
systemctl restart arl-worker                                   # 只重启扫描侧
journalctl -u arl-worker -f                                    # 跟踪日志
journalctl -u arl-web -n 100 --no-pager
```

- **改并发**：登录后在「系统设置 → 性能与并发配置」调整，worker 看门狗会自动重载（与容器模式一致）。
- **改前端/后端代码**：后端 `systemctl restart arl-web`（或 `arl-worker`）；前端重新 `pnpm run build` 后 `systemctl reload nginx`。
- **修改 nginx 配置**：`nginx -t && systemctl reload nginx`。

---

## 七、可选加固：降权运行

若不愿以 root 运行，需要同时满足三个条件，缺一会静默降级：

```ini
# 在 .service 中把 User=root 替换为：
User=arl
AmbientCapabilities=CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_BIND_SERVICE
```

```bash
useradd -r -s /usr/sbin/nologin arl
chown -R arl:arl /opt/arl-next/backend/app/tmp /opt/arl-next/backend/app/tmp_screenshot \
                  /opt/arl-next/backend/app/dicts /opt/arl-next/backend/ARL-NPoC/xing/plugins \
                  /opt/arl-next/backend/ARL-NPoC/xing/dicts
```

同时 nuclei 模板需放到 `/home/arl/nuclei-templates`（否则模板搜不到），osint-service 的 IPv6 地址池功能需要额外的 `CAP_NET_ADMIN`。

---

## 八、后续升级成本（务必知悉）

容器模式升级是一条命令；源码模式每次跟进上游都需要：

```bash
cd /opt/arl-next && git pull
# 处理冲突：backend/config.yaml（未入库，不冲突）、deploy/source/*（本目录为本地新增）
cd backend && .venv/bin/pip install -r requirements.txt && .venv/bin/pip install -e ARL-NPoC/
cd ../frontend && pnpm install --frozen-lockfile && pnpm run build
systemctl restart arl-web arl-worker arl-osint arl-puppeteer && systemctl reload nginx
```

注意 `backend/config.yaml` 已被 `.gitignore` 忽略，`git pull` 不会覆盖它——但**上游新增的配置项不会自动出现在你的文件里**，升级后需对照 `config.yaml.example` 补差。

---

## 九、验证状态

**已在 CentOS Stream 10（x86_64，1 核 / 923MB 内存 / SELinux Enforcing）上完成端到端实测**，`start-local.sh` 全流程跑通：

- 环境体检 22 项全部 ✅
- 7 个服务（arl-web / arl-worker / arl-osint / arl-puppeteer / nginx / mongod / rabbitmq-server）均 active 且 0 次重启
- 经 nginx 网关登录成功，带 Token 调用任务列表 API 返回 200
- Celery 三队列（arltask_heavy / arltask_light / arlgithub）全部 online 并响应 ping
- 截图渲染服务返回 41KB base64 JPEG（Node + Chromium 链路完整）
- nuclei 模板 14434 个、GeoIP ip2region 库经 sha256 校验落盘

首次实测中暴露并已修复的问题（均已固化进脚本，详见 `git log`）：

| # | 问题 | 修复 |
| :--- | :--- | :--- |
| 1 | 脚本硬拒绝非 apt 发行版 | 增加 dnf 系完整支持 |
| 2 | MongoDB 7.0 仓库密钥 SHA1 自签名被加密策略拒绝 | 改用官方 tarball + SHA256 校验，不改动系统加密策略 |
| 3 | `mongodb-org-tools` 依赖缺失导致整包安装失败 | 仅装 server + mongosh（备份功能本就不在范围内） |
| 4 | mongod 二进制带 `user_tmp_t` 上下文，systemd 报 203/EXEC | `chcon` + `semanage fcontext` 修正 |
| 5 | nginx 读配置文件 Permission denied | 目标目录内创建 + `restorecon` |
| 6 | nginx 无法监听 5173 | `semanage port` 放行 |
| 7 | 登录接口 502 | `setsebool -P httpd_can_network_connect on` |
| 8 | worker 反复崩溃（`wait-for-it.sh` Permission denied） | 补齐执行位（该脚本会以 `timeout $0` 重执行自身） |
| 9 | pip/npm 直连官方源连接重置 | 默认走国内镜像，失败回退官方源 |
| 10 | 低内存机器 vite 构建 `Reached heap limit` | 按物理内存+Swap 动态放宽 Node 堆上限 |
| 11 | nuclei 模板拉取失败（GitHub 被重置） | 自动探测本机 SOCKS5 代理重试 |
| 12 | GeoIP 官方直链 SSL 重置、内置镜像返回损坏内容 | 增加镜像兜底通道并强制 sha256 校验 |
| 13 | `--check-only` 会重启 MongoDB（违反只读契约） | 体检模式改为纯只读探测 |

**apt 系路径尚未实测**（依据 Dockerfile 与发行版惯例推导），首次在 Debian/Ubuntu 上部署时建议先执行 `--check-only` 核对。

> 提示：本节所述 1 核 / 923MB 属于**低于推荐配置**（README 建议 4 核 4G）的极端环境，能跑通依赖 2GB Swap。生产环境请按推荐配置规划。

