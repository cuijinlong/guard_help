# 能源管理平台 · 单容器（all-in-one）镜像
#
# 一个容器里跑齐：PostgreSQL 16 + guard-server(Java 25) + ngx-ai(Python) + Nginx
# 适合：单机试用、边缘设备、不想维护多容器编排的场合。
#
# 与分容器模式的取舍：
#   单容器  —— 一条 docker run 就能起，端口只有一个；但无法单独重启某个组件，
#              镜像更大（约 3GB），升级要重建整个容器。
#   分容器  —— 各组件独立重启/扩容，镜像复用好；但需要 compose 编排。
#
# 基础镜像选 python:3.10-slim-bookworm 而不是 temurin：
#   开发环境的 Python 是 3.10，Prophet/cmdstanpy 在这套依赖上验证过；
#   Debian bookworm 的 apt 生态同时能装 nginx / PostgreSQL / JDK。
#   JDK 25 通过 Adoptium 官方 apt 源安装，版本与分容器模式一致。
#
# 构建上下文 = 部署目录（含 jar / data / ngxai-dist / ngxai-backend）。
# 由 docker-00-prepare.sh 生成，不要手工构造。

FROM python:3.10-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8

# ------------------------------------------------------------------ 系统依赖
# openjdk: Adoptium 官方源装 temurin-25-jre（Debian 自带只有 17）
# postgresql-16: PGDG 官方源（bookworm 自带 15）
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg wget tzdata \
        nginx supervisor \
        build-essential libpq-dev \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "Asia/Shanghai" > /etc/timezone \
    \
    && install -d /etc/apt/keyrings \
    && curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
         | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main" \
         > /etc/apt/sources.list.d/adoptium.list \
    \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
         | gpg --dearmor -o /etc/apt/keyrings/pgdg.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list \
    \
    && apt-get update && apt-get install -y --no-install-recommends \
        temurin-25-jre postgresql-16 postgresql-client-16 \
    && rm -rf /var/lib/apt/lists/* \
    \
    # Adoptium 的安装目录名带版本与架构（temurin-25-jre-amd64），
    # 不能写死路径。这里定位后统一软链到 /opt/java/openjdk，
    # 让 supervisord 与 entrypoint 用同一个稳定路径。
    && JAVA_BIN="$(find /usr/lib/jvm -maxdepth 4 -type f -name java | head -1)" \
    && test -n "$JAVA_BIN" \
    && mkdir -p /opt/java \
    && ln -s "$(dirname "$(dirname "$JAVA_BIN")")" /opt/java/openjdk \
    && /opt/java/openjdk/bin/java -version

# ------------------------------------------------------------------ ngx-ai 后端
WORKDIR /app
COPY ngxai-backend/requirements.txt ./
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install -r requirements.txt \
    # 构建期编译一次 Stan 模型，避免首次预测多等 40 秒
    && /opt/venv/bin/python -c "from prophet import Prophet; print('stan model cached')"

COPY ngxai-backend/ ./
RUN mkdir -p /app/data

# ------------------------------------------------------------------ 应用资源
# guard-server jar 与 install 数据目录
COPY guard-server-4.4.0.jar /opt/energy/guard-server-4.4.0.jar
COPY data/ /opt/energy/data/

# 前端静态产物（base=/ngxai/）
RUN rm -rf /usr/share/nginx/html/ngxai \
    && mkdir -p /usr/share/nginx/html/ngxai
COPY ngxai-dist/ /usr/share/nginx/html/ngxai/

# 网关配置：把 upstream 指到 127.0.0.1（同容器）
COPY nginx/energy.conf /etc/nginx/conf.d/default.conf
RUN rm -f /etc/nginx/sites-enabled/default \
    && sed -i 's/server energy-server:8090;/server 127.0.0.1:8090;/' /etc/nginx/conf.d/default.conf \
    && sed -i 's/server ngxai-backend:18801;/server 127.0.0.1:18801;/' /etc/nginx/conf.d/default.conf

# 替换主配置而不是放 conf.d：Debian 默认主配置里已有 [supervisord] 段，
# 再 include 一个同名段 supervisord 会直接报 "section already exists" 起不来。
COPY allinone/supervisord.conf /etc/supervisor/supervisord.conf
COPY allinone/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# ------------------------------------------------------------------ 运行时
# PostgreSQL 数据、SQLite、日志都放 /var/lib/energy，挂卷即可持久化
# /bin/sh 是 dash，不支持 {a,b,c} 展开，必须写全路径
RUN mkdir -p /var/lib/energy/pgdata /var/lib/energy/logs /var/lib/energy/run \
    # logs 也要给 postgres：pg_ctl -l 由 postgres 身份写日志文件
    && chown -R postgres:postgres /var/lib/energy/pgdata /var/lib/energy/run /var/lib/energy/logs

VOLUME ["/var/lib/energy"]

EXPOSE 80

# 健康检查：网关活着、且 Java 的 setup 接口有 JSON 响应
HEALTHCHECK --interval=20s --timeout=5s --start-period=180s --retries=15 \
  CMD curl -fsS http://127.0.0.1/api/noauth/setup/state | grep -q '"status"' || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
