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
JEMALLOC_VERSION="5.3.0"
BOOST_VERSION="1.86.0"
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
    ./config --prefix="$INSTALL_DIR/openssl" \
             --openssldir="$INSTALL_DIR/openssl" \
             shared \
             zlib-dynamic \
             no-ssl3 \
             no-ssl3-method \
             no-comp \
             -O3
    make -j$(nproc)
    make install
}

install_jemalloc() {
    echo "Installing jemalloc version $JEMALLOC_VERSION..."
    local jemalloc_archive="jemalloc-$JEMALLOC_VERSION.tar.bz2"
    download_and_extract "https://github.com/jemalloc/jemalloc/releases/download/$JEMALLOC_VERSION/$jemalloc_archive" "jemalloc-$JEMALLOC_VERSION"
    ./configure --prefix="/opt/jemalloc"
    make -j$(nproc)
    make install
}

install_boost() {
    echo "Installing Boost version $BOOST_VERSION..."
    boost_dir="boost_$(echo $BOOST_VERSION | tr '.' '_')"
    boost_archive="${boost_dir}.tar.gz"
    download_and_extract "https://archives.boost.io/release/$BOOST_VERSION/source/$boost_archive" "$boost_dir"
    cd "$SRC_DIR/$boost_dir"
    ./bootstrap.sh --prefix="/opt/boost"
    ./b2 install
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
    chown -R www-data:www-data /opt/nginx/conf
    chmod -R 755 /opt/nginx/conf
}

install_mariadb() {
    echo "Installing MariaDB..."
    download_and_extract "https://mirror.mariadb.org/mariadb-$MARIADB_VERSION/source/mariadb-$MARIADB_VERSION.tar.gz" "mariadb-$MARIADB_VERSION"
    cmake -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR/mariadb" \
          -DWITH_JEMALLOC=ON \
          -DJEMALLOC_LIBRARY="/opt/jemalloc/lib/libjemalloc.so" \
          -DBOOST_ROOT="/opt/boost" .
    make -j$(nproc)
    make install

    # Setup user
    getent group mysql || groupadd mysql
    getent passwd mysql || useradd -r -g mysql -s /bin/false mysql

    "$INSTALL_DIR/mariadb/scripts/mariadb-install-db" --user=mysql --basedir="$INSTALL_DIR/mariadb" --datadir="$INSTALL_DIR/mariadb/data"

    cat > /etc/systemd/system/mariadb.service <<-EOF
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

    # Create php.ini
    cp php.ini-development "$INSTALL_DIR/php/lib/php.ini" || true

    # Ensure the PHP-FPM configuration directory exists
    mkdir -p "$INSTALL_DIR/php/etc"

    # Copy the main PHP-FPM configuration file if it doesn't exist
    if [ ! -f "$INSTALL_DIR/php/etc/php-fpm.conf" ]; then
        cp "$SRC_DIR/php-$PHP_VERSION/sapi/fpm/php-fpm.conf" "$INSTALL_DIR/php/etc/php-fpm.conf"
    fi

    # Create PHP-FPM pool configuration
    if [ ! -f "$INSTALL_DIR/php/etc/php-fpm.d/www.conf" ]; then
        mkdir -p "$INSTALL_DIR/php/etc/php-fpm.d"
        cp "$SRC_DIR/php-$PHP_VERSION/sapi/fpm/www.conf" "$INSTALL_DIR/php/etc/php-fpm.d/www.conf"
        sed -i 's/user = nobody/user = www-data/' "$INSTALL_DIR/php/etc/php-fpm.d/www.conf"
        sed -i 's/group = nobody/group = www-data/' "$INSTALL_DIR/php/etc/php-fpm.d/www.conf"
    fi

    # Create log directory and adjust its permissions so www-data can write the error log
    mkdir -p "$INSTALL_DIR/php/var/log"
    chown -R www-data:www-data "$INSTALL_DIR/php/var/log"
    chmod -R 755 "$INSTALL_DIR/php/var/log"

    # Create a systemd service unit for PHP-FPM
    cat > /etc/systemd/system/php-fpm.service <<-EOF
[Unit]
Description=PHP-FPM Service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/php/sbin/php-fpm --nodaemonize
ExecReload=/bin/kill -USR2 \$MAINPID
User=www-data
Group=www-data
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable php-fpm
    systemctl start php-fpm

    # Wait until PHP-FPM is active before proceeding
    while ! systemctl is-active --quiet php-fpm; do
        echo "Waiting for PHP-FPM to start..."
        sleep 1
    done
    echo "PHP-FPM is now active."
}

configure_nginx_php() {
    echo "Configuring NGINX with PHP support..."
    cat > "$INSTALL_DIR/nginx/conf/nginx.conf" <<-EOF
user www-data;
worker_processes 1;
pid /run/nginx.pid;
events { worker_connections 1024; }

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;

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

    cat > /etc/systemd/system/nginx.service <<-EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/opt/nginx/sbin/nginx -t
ExecStart=/opt/nginx/sbin/nginx
ExecReload=/opt/nginx/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable nginx
    systemctl start nginx

    while ! systemctl is-active --quiet nginx; do
        echo "Waiting for NGINX to start..."
        sleep 1
    done
    echo "NGINX is now active."
}

# Environment
export LD_LIBRARY_PATH=""
export CPPFLAGS=""
export LDFLAGS=""
export PKG_CONFIG_PATH=""
export LIBRARY_PATH=""

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
export CPPFLAGS="-I$INSTALL_DIR/openssl/include"
export LDFLAGS="-L$INSTALL_DIR/openssl/lib"
export LD_LIBRARY_PATH="$INSTALL_DIR/openssl/lib:$LD_LIBRARY_PATH"

install_jemalloc
export LD_LIBRARY_PATH="$INSTALL_DIR/jemalloc/lib:$LD_LIBRARY_PATH"

install_boost
export CPPFLAGS="-I$INSTALL_DIR/boost/include $CPPFLAGS"
export LIBRARY_PATH="$INSTALL_DIR/boost/lib:$LIBRARY_PATH"

# Web server user
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
ln -sf /opt/mariadb/bin/mariadb /usr/local/bin/mysql

# Test setup
echo "Testing LNMP setup..."
if curl -s http://localhost/info.php | grep -q "PHP Version"; then
    echo "LNMP stack installed successfully!"
else
    echo "LNMP stack installation failed."
fi

echo "Installation complete."
exit 0