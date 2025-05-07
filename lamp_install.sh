#!/bin/bash
set -euo pipefail

# Variables
SRC_DIR="/opt/src"
INSTALL_DIR="/opt"
NGINX_VERSION="1.27.5"
MARIADB_VERSION="11.7.2"
PHP_VERSION="8.4.5"
PCRE2_VERSION="10.45"
LIBXML2_VERSION="2.9.14"
ZLIB_VERSION="1.3.1"
OPENSSL_VERSION="3.5.0"
LIBJPEG_VERSION="9f"
DB_USER="dbadmin"
DB_PASSWORD="Unix2025"
REMOTE_IP="10.1.0.73"

# Root check
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root."
  exit 1
fi

# Install system build dependencies
apt-get update
apt-get install -y build-essential pkg-config cmake bison git wget tar \
    libncurses5-dev libcurl4-openssl-dev libpng-dev libxpm-dev libfreetype6-dev \
    libmcrypt-dev libreadline-dev libonig-dev libzip-dev re2c autoconf openssl libssl-dev \
    python3.11-dev python3-pip openjdk-17-jdk libsqlite3-dev libgnutls28-dev libsystemd-dev xz-utils

# Create source directory
mkdir -p "$SRC_DIR"

download_and_extract() {
    local url=$1
    local dir=$2
    local archive="$SRC_DIR/$(basename "$url")"
    echo "Downloading $(basename "$url")..."
    wget -q -O "$archive" "$url"
    echo "Extracting $(basename "$url")..."
    tar -xf "$archive" -C "$SRC_DIR"
    cd "$SRC_DIR/$dir"
}

install_zlib() {
    echo "Installing zlib..."
    download_and_extract "https://zlib.net/zlib-$ZLIB_VERSION.tar.gz" "zlib-$ZLIB_VERSION"
    ./configure --prefix="$INSTALL_DIR/zlib"
    make -j$(nproc)
    make install
}

install_libjpeg() {
    echo "Installing libjpeg..."
    download_and_extract "https://www.ijg.org/files/jpegsrc.v$LIBJPEG_VERSION.tar.gz" "jpeg-$LIBJPEG_VERSION"
    ./configure --prefix="$INSTALL_DIR/libjpeg"
    make -j$(nproc)
    make install
}

install_libxml2() {
    echo "Installing libxml2..."
    local short=$(echo "$LIBXML2_VERSION" | cut -d. -f1,2)
    download_and_extract "https://download.gnome.org/sources/libxml2/$short/libxml2-$LIBXML2_VERSION.tar.xz" "libxml2-$LIBXML2_VERSION"
    ./configure --prefix="$INSTALL_DIR/libxml2"
    make -j$(nproc)
    make install
}

install_pcre() {
    echo "Installing PCRE2..."
    download_and_extract "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" "pcre2-$PCRE2_VERSION"
    ./configure --prefix="$INSTALL_DIR/pcre2"
    make -j$(nproc)
    make install
}

install_openssl() {
    echo "Installing OpenSSL..."
    download_and_extract "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" "openssl-$OPENSSL_VERSION"
}

install_nginx() {
    echo "Installing NGINX..."
    download_and_extract "http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz" "nginx-$NGINX_VERSION"
    ./configure --prefix="$INSTALL_DIR/nginx" \
        --with-http_ssl_module \
        --with-pcre="$SRC_DIR/pcre2-$PCRE2_VERSION" \
        --with-openssl="$SRC_DIR/openssl-$OPENSSL_VERSION"
    make -j$(nproc)
    make install
}

install_mariadb() {
    echo "Installing MariaDB..."
    download_and_extract "https://mirror.mariadb.org/mariadb-$MARIADB_VERSION/source/mariadb-$MARIADB_VERSION.tar.gz" "mariadb-$MARIADB_VERSION"
    cmake -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR/mariadb" .
    make -j$(nproc)
    make install

    # Setup user
    getent group mysql || groupadd mysql
    getent passwd mysql || useradd -r -g mysql -s /bin/false mysql

    "$INSTALL_DIR/mariadb/scripts/mariadb-install-db" --user=mysql --basedir="$INSTALL_DIR/mariadb" --datadir="$INSTALL_DIR/mariadb/data"

    cat > /etc/systemd/system/mariadb.service <<EOF
[Unit]
Description=MariaDB
After=network.target

[Service]
User=mysql
Group=mysql
ExecStart=$INSTALL_DIR/mariadb/bin/mysqld_safe --datadir=$INSTALL_DIR/mariadb/data
ExecStop=$INSTALL_DIR/mariadb/bin/mysqladmin shutdown
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mariadb
    systemctl start mariadb
    echo "Waiting for MariaDB to be ready..."
    while ! "$INSTALL_DIR/mariadb/bin/mysqladmin" ping --silent --host=127.0.0.1; do
        sleep 1
    done
    "$INSTALL_DIR/mariadb/bin/mariadb" -e "CREATE USER '$DB_USER'@'$REMOTE_IP' IDENTIFIED BY '$DB_PASSWORD'; GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'$REMOTE_IP'; FLUSH PRIVILEGES;"
}

install_php() {
    echo "Installing PHP..."
    download_and_extract "https://www.php.net/distributions/php-$PHP_VERSION.tar.gz" "php-$PHP_VERSION"
    ./configure --prefix="$INSTALL_DIR/php" \
        --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
        --with-zlib="$INSTALL_DIR/zlib" \
        --with-jpeg-dir="$INSTALL_DIR/libjpeg" \
        --with-libxml-dir="$INSTALL_DIR/libxml2" \
        --with-openssl \
        --enable-mbstring \
        --enable-fpm
    make -j$(nproc)
    make install

    # Create config
    cp php.ini-development "$INSTALL_DIR/php/lib/php.ini" || true
    if [ ! -f "$INSTALL_DIR/php/etc/php-fpm.conf" ]; then
        cp "$SRC_DIR/php-$PHP_VERSION/sapi/fpm/php-fpm.conf" "$INSTALL_DIR/php/etc/php-fpm.conf"
    fi
    if [ ! -f "$INSTALL_DIR/php/etc/php-fpm.d/www.conf" ]; then
        mkdir -p "$INSTALL_DIR/php/etc/php-fpm.d"
        cp "$SRC_DIR/php-$PHP_VERSION/sapi/fpm/www.conf" "$INSTALL_DIR/php/etc/php-fpm.d/www.conf"
        sed -i 's/user = nobody/user = www-data/' "$INSTALL_DIR/php/etc/php-fpm.d/www.conf"
        sed -i 's/group = nobody/group = www-data/' "$INSTALL_DIR/php/etc/php-fpm.d/www.conf"
    fi

    "$INSTALL_DIR/php/sbin/php-fpm"
}

configure_nginx_php() {
    echo "Configuring NGINX with PHP support..."
    cat > "$INSTALL_DIR/nginx/conf/nginx.conf" <<EOF
worker_processes 1;
events { worker_connections 1024; }

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;

    server {
        listen 80;
        server_name localhost;

        root /var/www/html;
        index index.php index.html;

        location ~ \.php\$ {
            fastcgi_pass   127.0.0.1:9000;
            fastcgi_index  index.php;
            include        fastcgi.conf;
        }
    }
}
EOF

    mkdir -p /var/www/html
    echo "<?php phpinfo(); ?>" > /var/www/html/info.php
    "$INSTALL_DIR/nginx/sbin/nginx"
}

# Environment
export LD_LIBRARY_PATH=""
export CPPFLAGS=""
export LDFLAGS=""
export PKG_CONFIG_PATH=""

# Install steps with env chaining
install_zlib
export CPPFLAGS="$CPPFLAGS -I$INSTALL_DIR/zlib/include"
export LDFLAGS="$LDFLAGS -L$INSTALL_DIR/zlib/lib"
export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$INSTALL_DIR/zlib/lib/pkgconfig"
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$INSTALL_DIR/zlib/lib"

install_libjpeg
export CPPFLAGS="$CPPFLAGS -I$INSTALL_DIR/libjpeg/include"
export LDFLAGS="$LDFLAGS -L$INSTALL_DIR/libjpeg/lib"
export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$INSTALL_DIR/libjpeg/lib/pkgconfig"
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$INSTALL_DIR/libjpeg/lib"

install_libxml2
export CPPFLAGS="$CPPFLAGS -I$INSTALL_DIR/libxml2/include"
export LDFLAGS="$LDFLAGS -L$INSTALL_DIR/libxml2/lib"
export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$INSTALL_DIR/libxml2/lib/pkgconfig"
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$INSTALL_DIR/libxml2/lib"

install_pcre
export CPPFLAGS="$CPPFLAGS -I$INSTALL_DIR/pcre2/include"
export LDFLAGS="$LDFLAGS -L$INSTALL_DIR/pcre2/lib"
export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$INSTALL_DIR/pcre2/lib/pkgconfig"
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$INSTALL_DIR/pcre2/lib"

install_openssl

# Web user
getent group www-data || groupadd www-data
getent passwd www-data || useradd --system --no-create-home --gid www-data www-data
install_nginx
install_mariadb
install_php
configure_nginx_php

# Path updates and symlinks
export PATH="/opt/nginx/sbin:/opt/php/bin:/opt/php/sbin:/opt/mariadb/bin:$PATH"
ln -sf /opt/nginx/sbin/nginx /usr/local/bin/nginx
ln -sf /opt/php/bin/php /usr/local/bin/php
ln -sf /opt/php/sbin/php-fpm /usr/local/bin/php-fpm
ln -sf /opt/mariadb/bin/mysql /usr/local/bin/mysql

# Test setup
echo "Testing LNMP setup..."
if curl -s http://localhost/info.php | grep -q "PHP Version"; then
    echo "LNMP stack installed successfully!"
else
    echo "LNMP stack installation failed."
fi

echo "Installation complete."