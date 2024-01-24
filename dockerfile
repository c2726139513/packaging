ARG PYTHON_VERSION=3.11.6
ARG DEBIAN_BASE=bookworm
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_BASE} AS base

ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG WKHTMLTOPDF_DISTRO=bookworm
ARG NODE_VERSION=18.18.2
ENV NVM_DIR=/home/frappe/.nvm
ENV PATH ${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/:${PATH}

RUN useradd -ms /bin/bash frappe \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
    curl \
    git \
    vim \
    nginx \
    gettext-base \
    # weasyprint dependencies
    libpango-1.0-0 \
    libharfbuzz0b \
    libpangoft2-1.0-0 \
    libpangocairo-1.0-0 \
    libatomic1 \
    # For backups
    restic \
    # MariaDB
    mariadb-client \
    # Postgres
    libpq-dev \
    postgresql-client \
    # For healthcheck
    wait-for-it \
    jq \
    # NodeJS
    && mkdir -p ${NVM_DIR} \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash \
    && . ${NVM_DIR}/nvm.sh \
    && nvm install ${NODE_VERSION} \
    && nvm use v${NODE_VERSION} \
    && npm install -g yarn \
    && nvm alias default v${NODE_VERSION} \
    && rm -rf ${NVM_DIR}/.cache \
    && echo 'export NVM_DIR="/home/frappe/.nvm"' >>/home/frappe/.bashrc \
    && echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm' >>/home/frappe/.bashrc \
    && echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion' >>/home/frappe/.bashrc \
    # Install wkhtmltopdf with patched qt
    && if [ "$(uname -m)" = "aarch64" ]; then export ARCH=arm64; fi \
    && if [ "$(uname -m)" = "armv7l" ]; then export ARCH=armhf; fi \
    && if [ "$(uname -m)" = "x86_64" ]; then export ARCH=amd64; fi \
    && downloaded_file=wkhtmltox_${WKHTMLTOPDF_VERSION}.${WKHTMLTOPDF_DISTRO}_${ARCH}.deb \
    && curl -sLO https://github.com/c2726139513/packaging/releases/download/$WKHTMLTOPDF_VERSION/$downloaded_file \
    && apt-get install -y ./$downloaded_file \
    && rm $downloaded_file \
    # Clean up
    && rm -rf /var/lib/apt/lists/* \
    && rm -fr /etc/nginx/sites-enabled/default \
    && pip3 install frappe-bench \
    # Fixes for non-root nginx and logs to stdout
    && sed -i '/user www-data/d' /etc/nginx/nginx.conf \
    && ln -sf /dev/stdout /var/log/nginx/access.log && ln -sf /dev/stderr /var/log/nginx/error.log \
    && touch /run/nginx.pid \
    && chown -R frappe:frappe /etc/nginx/conf.d \
    && chown -R frappe:frappe /etc/nginx/nginx.conf \
    && chown -R frappe:frappe /var/log/nginx \
    && chown -R frappe:frappe /var/lib/nginx \
    && chown -R frappe:frappe /run/nginx.pid

COPY resources/nginx-template.conf /templates/nginx/frappe.conf.template
COPY resources/nginx-entrypoint.sh /usr/local/bin/nginx-entrypoint.sh

FROM base AS builder

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    # For frappe framework
    wget \
    # For psycopg2
    libpq-dev \
    # Other
    libffi-dev \
    liblcms2-dev \
    libldap2-dev \
    libmariadb-dev \
    libsasl2-dev \
    libtiff5-dev \
    libwebp-dev \
    redis-tools \
    rlwrap \
    tk8.6-dev \
    cron \
    # For pandas
    gcc \
    build-essential \
    libbz2-dev \
    # For build cryptography in armhf but has error, so use the prebuilt wheels from piwheels.org
    libxslt-dev libxml2-dev libssl-dev python3-dev cargo\
    # For canvas in arm64 and armhf
    && if [ `dpkg --print-architecture` != "amd64" ]; then apt-get install --no-install-recommends -y libcairo2-dev libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev; fi \
    && rm -rf /var/lib/apt/lists/* \
    # For cryptography in armhf
    && if [ `dpkg --print-architecture` = "armhf" ]; then printf "[global]\nextra-index-url=https://www.piwheels.org/simple\n" > /etc/pip.conf ; fi
    

USER frappe

ARG FRAPPE_BRANCH=version-15
ARG FRAPPE_PATH=https://github.com/frappe/frappe
ARG ERPNEXT_REPO=https://github.com/frappe/erpnext
ARG ERPNEXT_BRANCH=version-15
RUN bench init \
  --frappe-branch=${FRAPPE_BRANCH} \
  --frappe-path=${FRAPPE_PATH} \
  --no-procfile \
  --no-backups \
  --skip-redis-config-generation \
  --verbose \
  /home/frappe/frappe-bench && \
  cd /home/frappe/frappe-bench && \
  bench get-app --branch=${ERPNEXT_BRANCH} --resolve-deps erpnext ${ERPNEXT_REPO} && \
  bench get-app https://gitee.com/yuzelin/erpnext_chinese.git && \
  bench get-app --branch=${ERPNEXT_BRANCH} https://gitee.com/yuzelin/erpnext_oob.git && \
  bench get-app payments && \
  bench set-config -gp socketio_port 9000 && \
  bench get-app --branch=v15.4.0 hrms && \
  bench get-app print_designer && \
  bench get-app https://github.com/c2726139513/my_erpnext && \
  bench get-app https://gitee.com/yuzelin/zelin_ac && \
  echo "{}" > sites/common_site_config.json && \
  find apps -mindepth 1 -path "*/.git" | xargs rm -fr

FROM base as erpnext

USER root

RUN     apt-get update && \
        apt-get install ttf-wqy-zenhei -y && \
        apt-get install ttf-wqy-microhei -y

USER frappe

COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

VOLUME [ \
  "/home/frappe/frappe-bench/sites", \
  "/home/frappe/frappe-bench/sites/assets", \
  "/home/frappe/frappe-bench/logs" \
]

CMD [ \
  "/home/frappe/frappe-bench/env/bin/gunicorn", \
  "--chdir=/home/frappe/frappe-bench/sites", \
  "--bind=0.0.0.0:8000", \
  "--threads=4", \
  "--workers=2", \
  "--worker-class=gthread", \
  "--worker-tmp-dir=/dev/shm", \
  "--timeout=120", \
  "--preload", \
  "frappe.app:application" \
]