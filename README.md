# LNMP Stack Custom Installer

This project provides a fully automated Bash script to build and install a custom LNMP stack (NGINX, MariaDB, PHP) from source, including all major dependencies. All components are installed under `/opt` due requirements.

## Features
- Compiles and installs all major components from source
- Installs dependencies in `/opt` due requirements
- Systemd integration for PHP-FPM, MariaDB, and NGINX
- Symlinks created for easy access to custom binaries

## Components & Versions
- **NGINX**: 1.27.5
- **MariaDB**: 11.7.2
- **PHP**: 8.4.5
- **zlib**: 1.3.1
- **libjpeg**: 9f
- **libxml2**: 2.9.14
- **pcre2**: 10.44
- **OpenSSL**: 3.5.0
- **jemalloc**: 5.3.0
- **Boost**: 1.86.0

## Usage
1. **Clone or download this repository.**
2. **Review and edit `lamp_install.sh` as needed.**
3. **Run the installer as root:**
   ```bash
   sudo bash lamp_install.sh
   ```
4. **Monitor installation logs:**
   ```bash
   tail -f install.log
   ```

## Environment Variables
The script sets `CPPFLAGS`, `LDFLAGS`, `PKG_CONFIG_PATH`, and `LD_LIBRARY_PATH` after each dependency is built to ensure all software is linked against the custom libraries in `/opt`.

## Systemd Integration
- Custom systemd unit files are created for MariaDB, PHP-FPM, and NGINX for service management.

## Symlinks
- Symlinks are created in `/usr/local/bin` for `nginx`, `php`, `php-fpm`, and `mysql` (MariaDB client) for command-line access.

## Requirements
- Debian-based Linux system
- Basic build tools (`build-essential`, `pkg-config`, etc.)

## Customization
- Edit version variables at the top of `lamp_install.sh` to use different versions.
- Add or remove dependencies as needed for your use case.
