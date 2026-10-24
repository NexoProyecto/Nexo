#!/bin/bash

BACKUP="/backup"
FECHA=$(date +"%Y-%m-%d_%H-%M")

case "$1" in

    segunda_entrega2mk)
        cp -r /var/www/segunda_entrega2mk "$BACKUP/segunda_entrega2mk/segunda_entrega2mk_$FECHA"
        echo "Respaldo de segunda_entrega2mk realizado correctamente."
        ;;

    apache)
        cp -r /etc/httpd "$BACKUP/apache/httpd_$FECHA"
        echo "Respaldo de Apache realizado correctamente."
        ;;

    mysql)
        cp -r /etc/my.cnf "$BACKUP/mysql/my.cnf_$FECHA"
        cp -r /etc/my.cnf.d "$BACKUP/mysql/my.cnf.d_$FECHA"

        mysqldump -u root -p primera_entrega2mk > "$BACKUP/mysql/segunda_entrega2mk_$FECHA.sql"

        echo "Respaldo de MySQL/MariaDB realizado correctamente."
        ;;

    cron)
        cp -r /etc/cron.d "$BACKUP/cron/cron_$FECHA"
        cp /etc/crontab "$BACKUP/cron/crontab_$FECHA"

        echo "Respaldo de Cron y Crontab realizado correctamente."
        ;;

    docker)
        cp -r /etc/docker "$BACKUP/docker/docker_$FECHA"
        echo "Respaldo de Docker realizado correctamente."
        ;;

    *)
        echo "Uso: $0 {segunda_entrega2mk|apache|mysql|cron|docker}"
        exit 1
        ;;
esac


# ELIMINACIÓN DE RESPALDOS ANTIGUOS


find "$BACKUP/segunda_entrega2mk/" -mindepth 1 -mtime +14 -exec rm -rf {} \;
find "$BACKUP/apache/" -mindepth 1 -mtime +14 -exec rm -rf {} \;
find "$BACKUP/mysql/" -mindepth 1 -mtime +14 -exec rm -rf {} \;
find "$BACKUP/cron/" -mindepth 1 -mtime +14 -exec rm -rf {} \;
find "$BACKUP/docker/" -mindepth 1 -mtime +14 -exec rm -rf {} \;

echo "Respaldos con más de 14 días eliminados."
