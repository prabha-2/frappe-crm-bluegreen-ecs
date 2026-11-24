FROM frappe/bench:latest

WORKDIR /home/frappe
RUN bench init --skip-redis-config-generation --version version-15 frappe-bench

WORKDIR /home/frappe/frappe-bench
RUN bench set-mariadb-host 127.0.0.1 \
 && bench set-redis-cache-host redis://127.0.0.1:6379 \
 && bench set-redis-queue-host redis://127.0.0.1:6379 \
 && bench set-redis-socketio-host redis://127.0.0.1:6379 \
 && sed -i '/redis/d;/watch/d' Procfile \
 && bench get-app crm --branch main

COPY --chown=frappe:frappe start.sh /home/frappe/start.sh

EXPOSE 8000
CMD ["bash", "/home/frappe/start.sh"]
