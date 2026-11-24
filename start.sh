
#!/bin/bash
set -e

export HOME=/home/frappe

printf '[client]\nskip-ssl\n' > /home/frappe/.my.cnf

cd /home/frappe/frappe-bench

echo "Waiting for MariaDB on 127.0.0.1:3306..."

until (echo > /dev/tcp/127.0.0.1/3306) 2>/dev/null; do
    sleep 3
done

echo "Creating site..."

bench new-site crm.localhost \
    --force \
    --mariadb-root-password 123 \
    --admin-password admin \
    --no-mariadb-socket

bench --site crm.localhost install-app crm

bench --site crm.localhost set-config mute_emails 1

bench use crm.localhost

bench set-config -g default_site crm.localhost

echo "Starting Frappe CRM..."

exec bench start
