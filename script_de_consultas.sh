#!/bin/bash

# ====================================================
# PROYECTO NEXO - SGDM
# TERCERA ENTREGA - SISTEMAS OPERATIVOS
# CONSULTAS Y MONITOREO DE MARIADB
# SISTEMA OPERATIVO: ALMALINUX 9.8
# ====================================================

set -u

# Cambiar por el nombre real de la base de datos
BASE_DATOS="CupCore"

# Cliente MariaDB
DB=(mariadb --batch)

titulo() {
    clear
    echo "========================================="
    echo "        MONITOREO MARIADB - NEXO"
    echo "========================================="
    echo
}

pausa() {
    echo
    read -r -p "Presione ENTER para continuar..."
}

consulta() {
    "DB[@]"-e"1"
}

verificar_conexion() {
    if ! command -v mariadb >/dev/null 2>&1; then
        echo "ERROR: cliente MariaDB no encontrado."
        return 1
    fi

    if ! consulta "SELECT 1;" >/dev/null 2>&1; then
        echo "ERROR: no se pudo conectar a MariaDB."
        echo "Revise las credenciales y el servicio."
        return 1
    fi
}

estado_servicio() {
    titulo
    echo "1. ESTADO DEL SERVICIO MARIADB"
    echo

    systemctl status mariadb --no-pager || true
    pausa
}

listar_bases() {
    titulo
    echo "2. BASES DE DATOS DISPONIBLES"
    echo

    consulta "SHOW DATABASES;"
    pausa
}

listar_tablas() {
    titulo
    echo "3. TABLAS DE LA BASE DE DATOS"
    echo

    "DB[@]""BASE_DATOS" -e "SHOW TABLES;"
    pausa
}

conexiones() {
    titulo
    echo "4. CONEXIONES DE MARIADB"
    echo

    consulta "SHOW GLOBAL STATUS LIKE 'Threads_connected';"
    consulta "SHOW GLOBAL STATUS LIKE 'Max_used_connections';"
    consulta "SHOW GLOBAL VARIABLES LIKE 'max_connections';"

    pausa
}

procesos() {
    titulo
    echo "5. PROCESOS ACTIVOS"
    echo

    consulta "SHOW FULL PROCESSLIST;"
    pausa
}

tamano_bd() {
    titulo
    echo "6. TAMANO DE LA BASE DE DATOS"
    echo

    consulta "
    SELECT
        table_schema AS base_datos,
        ROUND(
            SUM(data_length + index_length)
            / 1024 / 1024, 2
        ) AS tamano_mb
    FROM information_schema.tables
    WHERE table_schema = '${BASE_DATOS}'
    GROUP BY table_schema;
    "

    pausa
}

estadisticas() {
    titulo
    echo "7. ESTADISTICAS GENERALES"
    echo

    consulta "SHOW GLOBAL STATUS LIKE 'Uptime';"
    consulta "SHOW GLOBAL STATUS LIKE 'Questions';"
    consulta "SHOW GLOBAL STATUS LIKE 'Slow_queries';"
    consulta "SHOW GLOBAL STATUS LIKE 'Aborted_connects';"

    pausa
}

version() {
    titulo
    echo "8. VERSION DE MARIADB"
    echo

    consulta "SELECT VERSION();"
    pausa
}

registros() {
    titulo
    echo "9. REGISTROS DEL SERVICIO"
    echo

    journalctl -u mariadb -n 30 --no-pager || true
    pausa
}

reporte() {
    titulo
    echo "10. REPORTE GENERAL - MARIADB NEXO"
    echo

    echo "Fecha: $(date)"
    echo

    echo "VERSION:"
    consulta "SELECT VERSION();"

    echo
    echo "CONEXIONES:"
    consulta "SHOW GLOBAL STATUS LIKE 'Threads_connected';"

    echo
    echo "CONSULTAS LENTAS:"
    consulta "SHOW GLOBAL STATUS LIKE 'Slow_queries';"

    echo
    echo "ERRORES DE CONEXION:"
    consulta "SHOW GLOBAL STATUS LIKE 'Aborted_connects';"

    echo
    echo "TIEMPO ACTIVO:"
    consulta "SHOW GLOBAL STATUS LIKE 'Uptime';"

    echo
    echo "TAMANO DE BASE DE DATOS:"
    consulta "
    SELECT
        table_schema,
        ROUND(
            SUM(data_length + index_length)
            / 1024 / 1024, 2
        ) AS tamano_mb
    FROM information_schema.tables
    WHERE table_schema = '${BASE_DATOS}'
    GROUP BY table_schema;
    "

    pausa
}

# ====================================================
# INICIO DEL PROGRAMA
# ====================================================

if ! verificar_conexion; then
    exit 1
fi

while true; do

    titulo

    echo "1. Estado del servicio MariaDB"
    echo "2. Listar bases de datos"
    echo "3. Listar tablas de Nexo"
    echo "4. Consultar conexiones"
    echo "5. Ver procesos activos"
    echo "6. Consultar tamano de base de datos"
    echo "7. Consultar estadisticas generales"
    echo "8. Consultar version de MariaDB"
    echo "9. Revisar registros de errores"
    echo "10. Generar reporte general"
    echo "0. Salir"

    echo
    read -r -p "Seleccione una opcion: " opcion

    case "$opcion" in
        1) estado_servicio ;;
        2) listar_bases ;;
        3) listar_tablas ;;
        4) conexiones ;;
        5) procesos ;;
        6) tamano_bd ;;
        7) estadisticas ;;
        8) version ;;
        9) registros ;;
        10) reporte ;;
        0)
            echo "Saliendo del monitoreo..."
            exit 0
            ;;
        *)
            echo "Opcion incorrecta."
            sleep 2
            ;;
    esac

done