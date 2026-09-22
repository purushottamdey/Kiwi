# checkov:skip=CKV_DOCKER_7:Ensure the base image uses a non latest version tag
ARG RUNTIME_BASE=quay.io/centos/centos:stream10
FROM $RUNTIME_BASE AS runtime-base

RUN ln -s /usr/bin/microdnf /usr/bin/dnf 2>/dev/null || echo -n && \
    dnf -y --nodocs install python3.12 mariadb-connector-c libpq \
    nginx-core sscg tar glibc-langpack-en && \
    dnf -y --nodocs update && \
    dnf clean all

ENV PATH=/venv/bin:${PATH} \
    VIRTUAL_ENV=/venv

WORKDIR /Kiwi


FROM runtime-base AS buildroot
RUN dnf -y --nodocs install python3.12-devel gzip make \
    mariadb-connector-c-devel postgresql-devel libjpeg-turbo-devel \
    libffi-devel gcc gettext nodejs24-npm unzip which rust cargo findutils && \
    ln -s /usr/bin/npm-24 /usr/bin/npm && \
    ln -s /usr/bin/node-24 /usr/bin/node

COPY ./requirements/mariadb.pc /usr/lib64/pkgconfig/mariadb.pc
COPY . /Kiwi/

RUN python3.12 -m venv /venv && \
    pip3 install --no-cache-dir --upgrade pip setuptools twine wheel && \
    pip3 install --no-cache-dir -r requirements/mariadb.txt -r requirements/postgres.txt

RUN sed -i "s/tcms.settings.devel/tcms.settings.product/" manage.py

# compile tcms/static/js/bundle.js explicitly
RUN pushd tcms/ && npm install --include=dev && ./node_modules/.bin/webpack && popd

RUN ./tests/check-build && \
    pip3 install --no-cache-dir dist/kiwitcms-*.tar.gz


FROM scratch AS pkg-dist
COPY --from=buildroot /Kiwi/dist/ /


FROM runtime-base AS kiwitcms

HEALTHCHECK CMD curl --fail -k -H "Referer: healthcheck" https://127.0.0

EXPOSE 8080
EXPOSE 8443

COPY ./httpd-foreground /httpd-foreground
CMD /httpd-foreground

ENV LC_ALL=en_US.UTF-8     \
    LANG=en_US.UTF-8       \
    LANGUAGE=en_US.UTF-8

COPY --from=buildroot /venv/ /venv
COPY ./manage.py /Kiwi/

# Copy the built application source code folder into the final container
COPY --from=buildroot /Kiwi/tcms/ /Kiwi/tcms/

# create directories so we can properly set ownership for them
RUN mkdir -p /Kiwi/ssl /Kiwi/static /Kiwi/uploads /Kiwi/etc/cron.jobs
COPY ./etc/*.conf /Kiwi/etc/
COPY ./etc/cron.jobs/* /Kiwi/etc/cron.jobs/

# generate self-signed SSL certificate
RUN /usr/bin/sscg -v -f \
    --country BG --locality Sofia \
    --organization "Kiwi TCMS" \
    --organizational-unit "Quality Engineering" \
    --ca-file       /Kiwi/static/ca.crt     \
    --cert-file     /Kiwi/ssl/localhost.crt \
    --cert-key-file /Kiwi/ssl/localhost.key

RUN sed -i "s/tcms.settings.devel/tcms.settings.product/" /Kiwi/manage.py && \
    ln -s /Kiwi/ssl/localhost.crt /etc/pki/tls/certs/localhost.crt && \
    ln -s /Kiwi/ssl/localhost.key /etc/pki/tls/private/localhost.key

# collect static files
RUN /Kiwi/manage.py collectstatic --noinput --link

# ====================================================================
# CUSTOM RENDER PROXY BYPASS & STABILITY OVERRIDES
# ====================================================================

# 1. Force the internal Apache/uWSGI wrapper to completely disable HTTPS enforcement rules
RUN sed -i 's/RewriteEngine on/RewriteEngine off/g' /Kiwi/etc/kiwi-httpd.conf || true
RUN sed -i '/<IfModule mod_rewrite.c>/,/<\/IfModule>/d' /Kiwi/etc/kiwi-httpd.conf || true
RUN sed -i '/RewriteCond/d' /Kiwi/etc/kiwi-httpd.conf || true
RUN sed -i '/RewriteRule/d' /Kiwi/etc/kiwi-httpd.conf || true

# 2. Inject security whitelists directly inside the core framework configuration
RUN echo 'SECURE_SSL_REDIRECT = False' >> /Kiwi/tcms/settings/product.py
RUN echo 'SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")' >> /Kiwi/tcms/settings/product.py
RUN echo 'CSRF_TRUSTED_ORIGINS = ["https://onrender.com"]' >> /Kiwi/tcms/settings/product.py
RUN echo 'ALLOWED_HOSTS = ["://onrender.com", "localhost", "127.0.0.1"]' >> /Kiwi/tcms/settings/product.py

# Declare database arguments needed if re-verifying connections at build time
ARG KIWI_DB_ENGINE
ARG KIWI_DB_HOST
ARG KIWI_DB_NAME
ARG KIWI_DB_USER
ARG KIWI_DB_PASSWORD
ARG KIWI_DB_PORT
ARG SECRET_KEY

# Pass arguments to internal environment variables
ENV KIWI_DB_ENGINE=$KIWI_DB_ENGINE \
    KIWI_DB_HOST=$KIWI_DB_HOST \
    KIWI_DB_NAME=$KIWI_DB_NAME \
    KIWI_DB_USER=$KIWI_DB_USER \
    KIWI_DB_PASSWORD=$KIWI_DB_PASSWORD \
    KIWI_DB_PORT=$KIWI_DB_PORT \
    SECRET_KEY=$SECRET_KEY

# ====================================================================

# from now on execute as non-root
RUN chown -R 1001 /Kiwi/ /venv/
USER 1001
