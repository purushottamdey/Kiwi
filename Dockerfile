# checkov:skip=CKV_DOCKER_7:Ensure the base image uses a non latest version tag
ARG RUNTIME_BASE=quay.io/centos/centos:stream10

FROM $RUNTIME_BASE AS runtime-base

RUN ln -s /usr/bin/microdnf /usr/bin/dnf 2>/dev/null || true && \
    dnf -y --nodocs install \
        python3.12 \
        mariadb-connector-c \
        libpq \
        nginx-core \
        sscg \
        tar \
        glibc-langpack-en \
        curl && \
    dnf -y --nodocs update && \
    dnf clean all

ENV PATH=/venv/bin:${PATH} \
    VIRTUAL_ENV=/venv

WORKDIR /Kiwi


FROM runtime-base AS buildroot

RUN dnf -y --nodocs install \
        python3.12-devel \
        gzip \
        make \
        mariadb-connector-c-devel \
        postgresql-devel \
        libjpeg-turbo-devel \
        libffi-devel \
        gcc \
        gettext \
        nodejs24-npm \
        unzip \
        which \
        rust \
        cargo \
        findutils && \
    ln -s /usr/bin/npm-24 /usr/bin/npm && \
    ln -s /usr/bin/node-24 /usr/bin/node

COPY ./requirements/mariadb.pc /usr/lib64/pkgconfig/mariadb.pc
COPY . /Kiwi/

RUN python3.12 -m venv /venv && \
    pip3 install --no-cache-dir --upgrade pip setuptools twine wheel && \
    pip3 install --no-cache-dir \
        -r requirements/mariadb.txt \
        -r requirements/postgres.txt

RUN sed -i "s/tcms.settings.devel/tcms.settings.product/" manage.py

# Compile the JavaScript bundle.
RUN cd tcms && \
    npm install --include=dev && \
    ./node_modules/.bin/webpack

RUN ./tests/check-build && \
    pip3 install --no-cache-dir dist/kiwitcms-*.tar.gz


FROM scratch AS pkg-dist

COPY --from=buildroot /Kiwi/dist/ /


FROM runtime-base AS kiwitcms

ENV LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8

WORKDIR /Kiwi

COPY ./httpd-foreground /httpd-foreground
COPY --from=buildroot /venv/ /venv
COPY ./manage.py /Kiwi/

# Copy the application source and configuration.
COPY --from=buildroot /Kiwi/tcms/ /Kiwi/tcms/
COPY ./etc/*.conf /Kiwi/etc/
COPY ./etc/cron.jobs/* /Kiwi/etc/cron.jobs/

# Create required directories.
RUN mkdir -p \
        /Kiwi/ssl \
        /Kiwi/static \
        /Kiwi/uploads \
        /Kiwi/etc/cron.jobs \
        /venv/lib/python3.12/site-packages/tcms_settings_dir

# Generate a self-signed certificate required by the Kiwi image.
RUN /usr/bin/sscg -v -f \
    --country BG \
    --locality Sofia \
    --organization "Kiwi TCMS" \
    --organizational-unit "Quality Engineering" \
    --ca-file /Kiwi/static/ca.crt \
    --cert-file /Kiwi/ssl/localhost.crt \
    --cert-key-file /Kiwi/ssl/localhost.key

RUN sed -i "s/tcms.settings.devel/tcms.settings.product/" /Kiwi/manage.py && \
    ln -s /Kiwi/ssl/localhost.crt /etc/pki/tls/certs/localhost.crt && \
    ln -s /Kiwi/ssl/localhost.key /etc/pki/tls/private/localhost.key

# Runtime settings.
# Set KIWI_CSRF_TRUSTED_ORIGINS and KIWI_ALLOWED_HOSTS in Render if your
# hostname is different from kiwi-j2b3.onrender.com.
RUN cat > /venv/lib/python3.12/site-packages/tcms_settings_dir/custom_settings.py <<'PY'
import os

SECURE_SSL_REDIRECT = False
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")

CSRF_TRUSTED_ORIGINS = [
    origin.strip()
    for origin in os.environ.get(
        "KIWI_CSRF_TRUSTED_ORIGINS",
        "https://kiwi-j2b3.onrender.com",
    ).split(",")
    if origin.strip()
]

ALLOWED_HOSTS = [
    host.strip()
    for host in os.environ.get(
        "KIWI_ALLOWED_HOSTS",
        "kiwi-j2b3.onrender.com,localhost,127.0.0.1",
    ).split(",")
    if host.strip()
]

if os.environ.get("KIWI_SECRET_KEY"):
    SECRET_KEY = os.environ["KIWI_SECRET_KEY"]
PY

# Render terminates HTTPS. Nginx serves HTTP internally on port 8080.
# uWSGI listens on /tmp/kiwitcms.sock according to etc/uwsgi.conf.
RUN cat > /Kiwi/etc/nginx.conf <<'NGINX'
worker_processes auto;

error_log /dev/stderr info;
pid /tmp/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    access_log /dev/stdout;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 4096;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    client_max_body_size 10m;
    large_client_header_buffers 4 10k;

    upstream kiwitcms {
        server unix:///tmp/kiwitcms.sock;
    }

    map $request_uri $limit_key {
        default "";
        ~^/accounts/ $binary_remote_addr;
    }

    limit_req_zone $limit_key zone=ten-per-sec:10m rate=10r/s;
    limit_req_status 429;

    server {
        listen 8080;
        listen [::]:8080;
        server_name _;

        location = /favicon.ico {
            alias /Kiwi/static/images/favicon.ico;
        }

        location = /robots.txt {
            alias /Kiwi/static/robots.txt;
        }

        location /static/ {
            alias /Kiwi/static/;
        }

        location / {
            include /etc/nginx/uwsgi_params;
            uwsgi_pass kiwitcms;

            limit_req zone=ten-per-sec burst=20 nodelay;
        }
    }
}
NGINX

# Collect static files after the product settings are available.
RUN /Kiwi/manage.py collectstatic --noinput --link

# Health check that does not require a database query.
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
    CMD curl --fail http://127.0.0.1:8080/robots.txt || exit 1

EXPOSE 8080

ENTRYPOINT ["/httpd-foreground"]

# Run as a non-root user.
RUN chown -R 1001:0 /Kiwi /venv /tmp
USER 1001
