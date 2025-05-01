#!/bin/bash

# Variables
SRC_DIR="/opt/src"
INSTALL_DIR="/opt"
NGINX_VERSION="1.25.2"
MARIADB_VERSION="10.11.5"
PHP_VERSION="8.2.10"
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
apt-get install -y build-essential libpcre3-dev zlib1g-dev libssl-dev cmake libncurses5-dev bison libxml2-dev libcurl4-openssl-dev libjpeg-dev libpng-dev libxpm-dev libfreetype6-dev libmcrypt-dev libreadline-dev git wget tar

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

# Install PCRE from source (NGINX dependency)
install_pcre() {
    echo "Installing PCRE..."
    download_and_extract "https://ftp.pcre.org/pub/pcre/pcre-8.45.tar.gz" "pcre-8.45"
    ./configure --prefix="$INSTALL_DIR/pcre"
    make
    make install
    echo "PCRE installed."
}

# Install OpenSSL from source (NGINX dependency)
install_openssl() {
    echo "Installing OpenSSL..."
    download_and_extract "https://www.openssl.org/source/openssl-1.1.1u.tar.gz" "openssl-1.1.1u"
    ./config --prefix="$INSTALL_DIR/openssl"
    make
    make install
    echo "OpenSSL installed."
}

# Install NGINX
install_nginx() {
    echo "Installing NGINX..."
    download_and_extract "http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz" "nginx-$NGINX_VERSION"
    ./configure --prefix="$INSTALL_DIR/nginx" \
        --with-pcre="$INSTALL_DIR/pcre" \
        --with-zlib="$INSTALL_DIR/zlib" \
        --with-openssl="$INSTALL_DIR/openssl" \
        --with-http_ssl_module
    make
    make install
    "$INSTALL_DIR/nginx/sbin/nginx"
    echo "NGINX installed and started."
}

# Install MariaDB
install_mariadb() {
    echo "Installing MariaDB..."
    download_and_extract "https://downloads.mariadb.org/interstitial/mariadb-$MARIADB_VERSION/source/mariadb-$MARIADB_VERSION.tar.gz" "mariadb-$MARIADB_VERSION"
    cmake -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR/mariadb" .
    make
    make install
    "$INSTALL_DIR/mariadb/scripts/mysql_install_db" --user=mysql --basedir="$INSTALL_DIR/mariadb" --datadir="$INSTALL_DIR/mariadb/data"
    cp "$INSTALL_DIR/mariadb/support-files/mysql.server" /etc/init.d/mariadb
    service mariadb start
    "$INSTALL_DIR/mariadb/bin/mysql" -e "CREATE USER '$DB_USER'@'$REMOTE_IP' IDENTIFIED BY '$DB_PASSWORD'; GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'$REMOTE_IP'; FLUSH PRIVILEGES;"
    echo "MariaDB installed and configured."
}

# Install libxml2 from source (PHP dependency)
install_libxml2() {
    echo "Installing libxml2..."
    download_and_extract "http://xmlsoft.org/sources/libxml2-2.10.3.tar.gz" "libxml2-2.10.3"
    ./configure --prefix="$INSTALL_DIR/libxml2"
    make
    make install
    echo "libxml2 installed."
}

# Install zlib from source (PHP dependency)
install_zlib() {
    echo "Installing zlib..."
    download_and_extract "https://zlib.net/zlib-1.2.13.tar.gz" "zlib-1.2.13"
    ./configure --prefix="$INSTALL_DIR/zlib"
    make
    make install
    echo "zlib installed."
}

# Install PHP
install_php() {
    echo "Installing PHP..."
    download_and_extract "https://www.php.net/distributions/php-$PHP_VERSION.tar.gz" "php-$PHP_VERSION"
    ./configure --prefix="$INSTALL_DIR/php" \
        --with-mysqli="$INSTALL_DIR/mariadb/bin/mysql_config" \
        --with-zlib="$INSTALL_DIR/zlib" \
        --with-libxml-dir="$INSTALL_DIR/libxml2" \
        --with-curl --with-openssl --enable-mbstring \
        --with-freetype --with-jpeg --with-png --with-xpm \
        --with-mcrypt --with-readline --enable-fpm
    make
    make install
    cp php.ini-production "$INSTALL_DIR/php/lib/php.ini"
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

# Main installation steps
install_libxml2
install_zlib
install_pcre
install_openssl
install_nginx
install_mariadb
install_php
configure_nginx_php

# Test setup
echo "Testing setup..."
curl -s http://localhost/info.php | grep -q "PHP Version" && echo "LAMP stack installed successfully and is working!" || echo "LAMP stack installation failed."

echo "Installation complete."