#!/bin/bash

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
DB_PASSWORD="unix2025"
REMOTE_IP="10.1.0.73"

if [[ $EUID > 0 ]]
  then echo "This script must be run as root"
  exit
fi

# Install build dependencies
echo "Installing build dependencies..."
apt-get update
apt-get install -y build-essential pkg-config openssl libssl-dev cmake libncurses5-dev bison \
    libcurl4-openssl-dev libpng-dev libxpm-dev libfreetype6-dev libmcrypt-dev libreadline-dev \
    git wget tar python3.11-dev python3-pip libsqlite3-dev libonig-dev libzip-dev re2c autoconf \
    openjdk-17-jdk openjdk-17-jre groff libgnutls28-dev libsystemd-dev

# Create source directory
mkdir -p "$SRC_DIR"

# Function to download, extract, and navigate to source directory
download_and_extract() {
    local url=$1
    local dest_dir=$2
    local package_name=$(basename "$url")
    echo "Downloading $package_name..."
    wget -q "$url" -P "$SRC_DIR"
    echo "Extracting $package_name..."
    tar -xf "$SRC_DIR/$package_name" -C "$SRC_DIR"
    cd "$SRC_DIR/$dest_dir"
}

# Install PCRE2 from source (NGINX dependency)
install_pcre() {
    echo "Installing PCRE2..."
    download_and_extract "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" "pcre2-$PCRE2_VERSION"
    ./configure --prefix="$INSTALL_DIR/pcre2"
    make -j$(nproc)
    make install
    echo "PCRE2 installed."
}

# Install zlib from source (NGINX dependency)
install_zlib() {
    echo "Installing zlib..."
    download_and_extract "https://zlib.net/zlib-$ZLIB_VERSION.tar.gz" "zlib-$ZLIB_VERSION"
    ./configure --prefix="$INSTALL_DIR/zlib"
    make -j$(nproc)
    make install
    echo "zlib installed."
}

# Download OpenSSL from source (NGINX dependency)
install_openssl() {
    echo "Downloading OpenSSL..."
    download_and_extract "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" "openssl-$OPENSSL_VERSION"
    echo "OpenSSL downloaded and extracted."
}

# Install NGINX
install_nginx() {
    echo "Installing NGINX..."
    download_and_extract "http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz" "nginx-$NGINX_VERSION"
    # Takes directories with source code only , doesn't accept build libraries or only searches normal locations
    ./configure --prefix="$INSTALL_DIR/nginx" \
        --with-http_ssl_module \
        --with-pcre="$SRC_DIR/pcre2-$PCRE2_VERSION" \
        --with-openssl="$SRC_DIR/openssl-$OPENSSL_VERSION"
    make -j$(nproc)
    make install
    "$INSTALL_DIR/nginx/sbin/nginx"
    echo "NGINX installed and started."
}

# Install MariaDB
install_mariadb() {
    echo "Installing MariaDB..."
    download_and_extract "https://downloads.mariadb.org/interstitial/mariadb-$MARIADB_VERSION/source/mariadb-$MARIADB_VERSION.tar.gz" "mariadb-$MARIADB_VERSION"
    # Enable systemd support by requesting it via a CMake flag.
    cmake -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR/mariadb" -DWITH_SYSTEMD=yes .
    make -j$(nproc)
    make install
    "$INSTALL_DIR/mariadb/scripts/mysql_install_db" --user=mysql --basedir="$INSTALL_DIR/mariadb" --datadir="$INSTALL_DIR/mariadb/data"

    # Install the systemd service file or fall back to init.d if not available.
    if [ -f "$INSTALL_DIR/mariadb/support-files/mariadb.service" ]; then
        cp "$INSTALL_DIR/mariadb/support-files/mariadb.service" /etc/systemd/system/mariadb.service
        systemctl daemon-reload
        systemctl start mariadb
    else
        cp "$INSTALL_DIR/mariadb/support-files/mysql.server" /etc/init.d/mariadb
        service mariadb start
    fi
    "$INSTALL_DIR/mariadb/bin/mariadb" -e "CREATE USER '$DB_USER'@'$REMOTE_IP' IDENTIFIED BY '$DB_PASSWORD'; GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'$REMOTE_IP'; FLUSH PRIVILEGES;"
    echo "MariaDB installed and configured."
}

# Install libxml2 from source (PHP dependency)
install_libxml2() {
    echo "Installing libxml2..."
    local major_minor=$(echo "$LIBXML2_VERSION" | cut -d. -f1,2)
    download_and_extract "https://download.gnome.org/sources/libxml2/$major_minor/libxml2-$LIBXML2_VERSION.tar.xz" "libxml2-$LIBXML2_VERSION"
    ./configure --prefix="$INSTALL_DIR/libxml2"
    make -j$(nproc)
    make install
    echo "libxml2 installed."
}

# Install libjpeg from source (PHP dependency)
install_libjpeg() {
    echo "Installing libjpeg..."
    download_and_extract "https://www.ijg.org/files/jpegsrc.v$LIBJPEG_VERSION.tar.gz" "jpeg-$LIBJPEG_VERSION"
    ./configure --prefix="$INSTALL_DIR/libjpeg"
    make -j$(nproc)
    make install
    echo "libjpeg installed."
}

# Install PHP
install_php() {
    echo "Installing PHP..."
    download_and_extract "https://www.php.net/distributions/php-$PHP_VERSION.tar.gz" "php-$PHP_VERSION"
    ./configure --prefix="$INSTALL_DIR/php" \
        --with-mysqli \
        --with-zlib="$INSTALL_DIR/zlib" \
        --with-curl --with-openssl --enable-mbstring \
        --with-freetype --with-jpeg --with-xpm \
        --with-readline --enable-fpm
    make -j$(nproc)
    make install
    
    # After installation, check if php-fpm.conf exists; if not, create it
    if [ ! -f "$INSTALL_DIR/php/etc/php-fpm.d/www.conf" ]; then
        echo "www.conf not found. Copying default pool configuration..."
        cp "$INSTALL_DIR/php/etc/php-fpm.d/www.conf.default" "$INSTALL_DIR/php/etc/php-fpm.d/www.conf"
    fi

    "$INSTALL_DIR/php/sbin/php-fpm"
    echo "PHP installed and started."
}

# Configure NGINX to use PHP
configure_nginx_php() {
    echo "Configuring NGINX to use PHP..."
    cat > "$INSTALL_DIR/nginx/conf/nginx.conf" <<EOF
worker_processes  1;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    sendfile        on;

    server {
        listen       80;
        server_name  localhost;

        root /var/www/html;
        index index.php index.html;

        location ~ \.php$ {
            fastcgi_pass   127.0.0.1:9000;
            fastcgi_index  index.php;
            include        fastcgi.conf;
        }
    }
}
EOF
    mkdir -p /var/www/html
    echo "<?php phpinfo(); ?>" > /var/www/html/info.php
    "$INSTALL_DIR/nginx/sbin/nginx" -s reload
    echo "NGINX configured to use PHP."
}

# In case they don't exist yet
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export CPPFLAGS="${CPPFLAGS:-}"
export LDFLAGS="${LDFLAGS:-}"
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"

# Main installation steps
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

# Create a mysql user with no login shell and assign it to the mysql group
getent group mysql || groupadd mysql
getent passwd mysql || useradd -r -g mysql -s /bin/false mysql

install_nginx
install_mariadb
export PATH="/opt/mariadb/bin:$PATH"
install_php
configure_nginx_php

export PATH="/opt/php/bin:/opt/php/sbin:/opt/nginx/sbin:$PATH"

# Test setup
echo "Testing setup..."
curl -s http://localhost/info.php | grep -q "PHP Version" && echo "LAMP stack installed successfully and is working!" || echo "LAMP stack installation failed."

echo "Installation complete."
