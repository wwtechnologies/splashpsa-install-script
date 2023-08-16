#!/bin/bash

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\033[0;31mThis script must be run as root.\e[0m"
        exit 1
    fi
}

check_os() {
    if ! grep -E "22.04|12" "/etc/"*"release" &>/dev/null; then
        echo -e "\033[0;31mThis script will only work on Ubuntu 22.04 or Debian 12\e[0m"
        exit 1
    fi
}

get_domain() {
    while [[ $domain != *[.]*[.]* ]]; do
        echo -ne "Enter your Fully Qualified Domain -- example (itflow.domain.com): "
        read domain
    done
}

generate_passwords() {
    mariadbpwd=$(tr -dc 'A-Za-z0-9' < /dev/urandom | fold -w 20 | head -n 1)
    cronkey=$(tr -dc 'A-Za-z0-9' < /dev/urandom | fold -w 20 | head -n 1)
}

install_packages() {
    apt-get update && apt-get -y upgrade
    apt-get install -y apache2 mariadb-server php libapache2-mod-php php-intl php-mysqli php-curl php-imap php-mailparse rewrite libapache2-mod-md certbot python3-certbot-apache git sudo

    mariadb_secure_installation

    a2enmod md
    a2enmod ssl
}

modify_php_ini() {
    local PHP_INI_PATH="/etc/php/php.ini"
    sed -i 's/^;\?upload_max_filesize =.*/upload_max_filesize = 500M/' $PHP_INI_PATH
    sed -i 's/^;\?post_max_size =.*/post_max_size = 500M/' $PHP_INI_PATH
}

setup_firewall() {
    # Uncomment the lines below if you want to enable UFW
    # ufw allow OpenSSH
    # ufw allow 'Apache Full'
    # ufw enable
}

setup_webroot() {
    mkdir -p /var/www/${domain}
    chown -R www-data:www-data /var/www/
}

setup_apache() {
    apache2_conf="<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    ServerName ${domain}
    DocumentRoot /var/www/${domain}
    ErrorLog /\${APACHE_LOG_DIR}/error.log
    CustomLog /\${APACHE_LOG_DIR}/access.log combined
</VirtualHost>"

    echo "${apache2_conf}" > /etc/apache2/sites-available/${domain}.conf

    a2ensite ${domain}.conf
    a2dissite 000-default.conf
    systemctl restart apache2

    certbot --apache --non-interactive --agree-tos --register-unsafely-without-email --domains ${domain}
}

clone_itflow() {
    git clone https://github.com/itflow-org/itflow.git /var/www/${domain}
}

setup_cronjobs() {
    (crontab -l 2>/dev/null; echo "0 2 * * * sudo -u www-data php /var/www/${domain}/cron.php ${cronkey}") | crontab -
    (crontab -l 2>/dev/null; echo "* * * * * sudo -u www-data php /var/www/${domain}/cron_ticket_email_parser.php ${cronkey}") | crontab -
    (crontab -l 2>/dev/null; echo "* * * * * sudo -u www-data php /var/www/${domain}/cron_mail_queue.php ${cronkey}") | crontab -
}

generate_cronkey_file() {
    mkdir -p /var/www/${domain}/uploads/tmp
    echo "<?php" > /var/www/${domain}/uploads/tmp/cronkey.php
    echo "\$itflow_install_script_generated_cronkey = \"${cronkey}\";" >> /var/www/${domain}/uploads/tmp/cronkey.php
    echo "?>" >> /var/www/${domain}/uploads/tmp/cronkey.php
    chown -R www-data:www-data /var/www/
}

setup_mysql() {
    mysql -e "CREATE DATABASE itflow /*\!40100 DEFAULT CHARACTER SET utf8 */;"
    mysql -e "CREATE USER itflow@localhost IDENTIFIED BY '${mariadbpwd}';"
    mysql -e "GRANT ALL PRIVILEGES ON itflow.* TO 'itflow'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
}

print_final_instructions() {
    echo "Please go to https://${domain} to finish setting up ITFlow"
    echo ""
    echo "In database setup section enter the following:"
    echo "Database User: itflow"
    echo "Database Name: itflow"
    echo "Database Password: ${mariadbpwd}"
}

# Execution begins here
check_root
check_os
get_domain
generate_passwords
install_packages
modify_php_ini
setup_firewall
setup_webroot
setup_apache
clone_itflow
setup_cronjobs
generate_cronkey_file
setup_mysql
print_final_instructions
