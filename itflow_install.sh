#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status.

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log file path
LOG_FILE="/var/log/itflow_install.log"
# Clear previous installation log
rm -f "$LOG_FILE"  # Delete the previous log file

# Function to log messages
log() {
    echo "$(date): $1" >> "$LOG_FILE"
}

# Function to show progress messages
show_progress() {
    echo -e "${GREEN}$1${NC}"
}

# Check if the user is root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "Error: This script must be run as root."
        echo -e "${RED}Error: This script must be run as root.${NC}"
        exit 1
    fi
}

# Check if the OS is supported
check_os() {
   if ! grep -E "22.04|24.04|12" "/etc/"*"release" &>/dev/null; then
        log "Error: This script only supports Ubuntu 24.04 or Debian 12."
        echo -e "${RED}Error: This script only supports Ubuntu 22.04 and 24.04 or Debian 12.${NC}"
        exit 1
    fi
}

# Function to install required packages
install_packages() {
    log "Installing packages"
    show_progress "1. Installing packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get -y upgrade >> "$LOG_FILE" 2>&1
    apt-get install -y apache2 mariadb-server \
    php libapache2-mod-php php-intl php-mysqli php-gd \
    php-curl php-imap php-mailparse php-mbstring libapache2-mod-md \
    certbot python3-certbot-apache git sudo whois cron dnsutils expect >> "$LOG_FILE" 2>&1
    echo -e "${GREEN}Packages installed.${NC}"
}

# Function to check for required binaries
check_required_binaries() {
    log "Checking packages"
    show_progress "2. Checking packages..."

    local binaries=("dpkg-reconfigure" "a2ensite" "a2dissite" "a2enmod")

    for bin in "${binaries[@]}"; do
        if ! command -v $bin &> /dev/null; then
            if [ -x "/usr/sbin/$bin" ]; then
                export PATH="$PATH:/usr/sbin"
            else
                log "Error: $bin not found in PATH or /usr/sbin"
                echo -e "${RED}Error: $bin not found. Please make sure it is installed and in your PATH or in /usr/sbin.${NC}"
                exit 1
            fi
        fi
    done
    echo -e "${GREEN}All required binaries are present.${NC}"
}

# Set the correct timezone
set_timezone() {
    log "Configuring timezone"
    show_progress "3. Configuring timezone..."

    # Prompt user for timezone
    read -p "$(echo -e "${YELLOW}Please enter your timezone (e.g., 'America/New_York'): ${NC}")" user_timezone

    # Validate the timezone
    if [ -f "/usr/share/zoneinfo/$user_timezone" ]; then
        ln -sf "/usr/share/zoneinfo/$user_timezone" /etc/localtime
        echo "$user_timezone" > /etc/timezone
        echo -e "${GREEN}Timezone set to $user_timezone.${NC}"
    else
        echo -e "${RED}Invalid timezone. Please make sure the timezone is correct.${NC}"
        exit 1
    fi
}

# Get domain name from user
get_domain() {
    while true; do
        read -p "$(echo -e "${YELLOW}4. Enter your Fully Qualified Domain Name (e.g., itflow.domain.com): ${NC}")" domain
        if [[ $domain == *.*.* ]]; then
            break
        else
            echo -e "${RED}Invalid domain. Please enter a valid Fully Qualified Domain Name.${NC}"
        fi
    done
    log "Domain set to: $domain"
    echo -e "${GREEN}Domain set to: $domain${NC}"
}

# Generate random passwords
generate_passwords() {
    log "Generating passwords"
    show_progress "5. Generating passwords..."
    MARIADB_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
    mariadbpwd=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
    cronkey=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
    echo -e "${GREEN}Passwords generated.${NC}"
}

# Modify PHP configuration
modify_php_ini() {
    log "Modifying php.ini"
    show_progress "6. Configuring PHP..."
    # Get the PHP version
    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    
    # Set the PHP_INI_PATH
    PHP_INI_PATH="/etc/php/${PHP_VERSION}/apache2/php.ini"

    sed -i 's/^;\?upload_max_filesize =.*/upload_max_filesize = 500M/' $PHP_INI_PATH
    sed -i 's/^;\?post_max_size =.*/post_max_size = 500M/' $PHP_INI_PATH
    echo -e "${GREEN}PHP configuration updated.${NC}"
}

# Setup web root directory
setup_webroot() {
    log "Setting up webroot"
    show_progress "7. Setting up webroot..."
    mkdir -p /var/www/${domain}
    chown -R www-data:www-data /var/www/
    echo -e "${GREEN}Webroot set up at /var/www/${domain}.${NC}"
}

# Configure Apache
setup_apache() {
    log "Configuring Apache"
    show_progress "8. Configuring Apache..."
    a2enmod md >> "$LOG_FILE" 2>&1
    a2enmod ssl >> "$LOG_FILE" 2>&1
    
    apache2_conf="<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    ServerName ${domain}
    DocumentRoot /var/www/${domain}
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>"

    echo "${apache2_conf}" > /etc/apache2/sites-available/${domain}.conf

    a2ensite ${domain}.conf >> "$LOG_FILE" 2>&1
    a2dissite 000-default.conf >> "$LOG_FILE" 2>&1
    systemctl restart apache2 >> "$LOG_FILE" 2>&1

    certbot --apache --non-interactive --agree-tos --register-unsafely-without-email --domains ${domain} >> "$LOG_FILE" 2>&1
    echo -e "${GREEN}Apache configured and SSL certificate obtained.${NC}"
}

# Clone ITFlow repository
clone_itflow() {
    log "Cloning ITFlow"
    show_progress "9. Cloning ITFlow..."
    git clone https://github.com/itflow-org/itflow.git /var/www/${domain} >> "$LOG_FILE" 2>&1
    chown -R www-data:www-data /var/www/${domain}
    echo -e "${GREEN}ITFlow cloned to /var/www/${domain}.${NC}"
}

# Setup cron jobs
setup_cronjobs() {
    log "Setting up cron jobs"
    show_progress "10. Setting up cron jobs..."

    CRON_FILE="/etc/cron.d/itflow"

    # Find the PHP binary
    PHP_BIN=$(command -v php)

    if [ -z "$PHP_BIN" ]; then
        log "PHP binary not found!"
        echo -e "${RED}PHP binary not found!${NC}"
        exit 1
    fi

    # Write the cron entries into the file
    echo "0 2 * * * www-data ${PHP_BIN} /var/www/${domain}/cron.php ${cronkey}" > $CRON_FILE
    echo "* * * * * www-data ${PHP_BIN} /var/www/${domain}/cron_ticket_email_parser.php ${cronkey}" >> $CRON_FILE
    echo "* * * * * www-data ${PHP_BIN} /var/www/${domain}/cron_mail_queue.php ${cronkey}" >> $CRON_FILE

    # Ensure the cron file has the correct permissions
    chmod 644 $CRON_FILE

    # Set ownership to root
    chown root:root $CRON_FILE

    log "Cron jobs added to /etc/cron.d/itflow"
    echo -e "${GREEN}Cron jobs added to /etc/cron.d/itflow.${NC}"
}

# Generate cron key file
generate_cronkey_file() {
    log "Generating cron key file"
    show_progress "11. Generating cron key file..."
    mkdir -p /var/www/${domain}/uploads/tmp
    echo "<?php" > /var/www/${domain}/uploads/tmp/cronkey.php
    echo "\$itflow_install_script_generated_cronkey = \"${cronkey}\";" >> /var/www/${domain}/uploads/tmp/cronkey.php
    echo "?>" >> /var/www/${domain}/uploads/tmp/cronkey.php
    chown -R www-data:www-data /var/www/
    echo -e "${GREEN}Cron key file generated.${NC}"
}

# Setup MariaDB
setup_mariadb() {
    log "MariaDB installation"
    show_progress "12. MariaDB installation..."

    if ! dpkg -l | grep -q mariadb-server || ! systemctl is-active --quiet mariadb; then
        log "Error: MariaDB is not installed or not running."
        echo -e "${RED}Error: MariaDB is not installed or not running.${NC}"
        exit 1
    fi

    # Use expect to automate mysql_secure_installation
    expect <<EOF >> "$LOG_FILE" 2>&1
spawn mysql_secure_installation
expect "Enter current password for root (enter for none):"
send "\r"
expect "Switch to unix_socket authentication \[Y/n\]"
send "n\r"
expect "Change the root password? \[Y/n\]"
send "Y\r"
expect "New password:"
send "$MARIADB_ROOT_PASSWORD\r"
expect "Re-enter new password:"
send "$MARIADB_ROOT_PASSWORD\r"
expect "Remove anonymous users? \[Y/n\]"
send "Y\r"
expect "Disallow root login remotely? \[Y/n\]"
send "Y\r"
expect "Remove test database and access to it? \[Y/n\]"
send "Y\r"
expect "Reload privilege tables now? \[Y/n\]"
send "Y\r"
expect eof
EOF

    # Create the database and itflow user
    mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "
    CREATE DATABASE IF NOT EXISTS itflow CHARACTER SET utf8;
    CREATE USER IF NOT EXISTS 'itflow'@'localhost' IDENTIFIED BY '${mariadbpwd}';
    GRANT ALL PRIVILEGES ON itflow.* TO 'itflow'@'localhost';
    FLUSH PRIVILEGES;" >> "$LOG_FILE" 2>&1

    if [ $? -ne 0 ]; then
        log "Error: Failed to configure MariaDB."
        echo -e "${RED}Error: Failed to configure MariaDB.${NC}"
        exit 1
    fi

    log "MariaDB secured and configured."
    echo -e "${GREEN}MariaDB secured and configured.${NC}"
}

# Welcome Message
clear
echo -e "${GREEN}#############################################${NC}"
echo -e "${GREEN}# Welcome to the ITFlow Installation Script #${NC}"
echo -e "${GREEN}#############################################${NC}"
echo
echo -e "${YELLOW}Please follow the prompts to complete the installation.${NC}"
echo

# Execution begins here
check_root
check_os
install_packages
check_required_binaries
set_timezone
get_domain
generate_passwords
modify_php_ini
setup_webroot
setup_apache
clone_itflow
setup_cronjobs
generate_cronkey_file
setup_mariadb

# Final message with instructions
echo
echo -e "${GREEN}######################################################${NC}"
echo -e "${GREEN}# Installation Completed Successfully!               #${NC}"
echo -e "${GREEN}######################################################${NC}"
echo
echo -e "Visit: ${GREEN}https://${domain}${NC} to complete the ITFlow setup."
echo
echo "Database setup details:"
echo -e "Database User: ${GREEN}itflow${NC}"
echo -e "Database Name: ${GREEN}itflow${NC}"
echo -e "Database Password: ${GREEN}${mariadbpwd}${NC}"
echo
echo -e "Database ROOT Password: ${GREEN}${MARIADB_ROOT_PASSWORD}${NC}"
echo
echo -e "A detailed log file is available at: ${GREEN}$LOG_FILE${NC}"
