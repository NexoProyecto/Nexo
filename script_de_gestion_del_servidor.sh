#!/bin/bash

# ======================================================
# PROYECTO NEXO - SGDM
# TERCERA ENTREGA - SISTEMAS OPERATIVOS
# SCRIPT GENERAL DE GESTION DEL SERVIDOR
# SISTEMA OPERATIVO: ALMALINUX 9.8
# ======================================================

set -u

LOG="/var/log/gestion_servidor_nexo.log"

# Verificar permisos de administrador
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: este script debe ejecutarse con sudo."
    exit 1
fi

# Crear archivo de registro protegido
touch "$LOG" || exit 1
chmod 600 "$LOG"

registrar() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" \
        | tee -a "$LOG"
}

titulo() {
    clear
    echo "=========================================="
    echo "       GESTION DEL SERVIDOR NEXO"
    echo "           ALMALINUX 9.8"
    echo "=========================================="
    echo
}

pausa() {
    echo
    read -r -p "Presione ENTER para continuar..."
}

confirmar() {
    local respuesta
    read -r -p "$1 (s/N): " respuesta
    [[ "respuesta"=="s"||"respuesta" == "S" ]]
}

# ======================================================
# 1. INFORMACION GENERAL
# ======================================================

informacion_servidor() {
    titulo
    echo "INFORMACION GENERAL DEL SERVIDOR"
    echo

    echo "--- SISTEMA OPERATIVO ---"
    cat /etc/os-release

    echo
    echo "--- NOMBRE DEL EQUIPO ---"
    hostnamectl

    echo
    echo "--- TIEMPO ENCENDIDO ---"
    uptime

    echo
    echo "--- FECHA Y HORA ---"
    date

    registrar "Consulta de informacion general"
    pausa
}

# ======================================================
# 2. USO DE CPU Y MEMORIA
# ======================================================

recursos() {
    titulo
    echo "MONITOREO DE RECURSOS"
    echo

    echo "--- PROCESADOR ---"
    uptime

    echo
    echo "--- MEMORIA RAM ---"
    free -h

    echo
    echo "--- PROCESOS CON MAYOR USO DE CPU ---"
    ps -eo pid,user,comm,%cpu,%mem \
        --sort=-%cpu | head -n 11

    registrar "Consulta de CPU y memoria"
    pausa
}

# ======================================================
# 3. ESPACIO EN DISCO
# ======================================================

discos() {
    titulo
    echo "ALMACENAMIENTO DEL SERVIDOR"
    echo

    echo "--- ESPACIO DISPONIBLE ---"
    df -hT

    echo
    echo "--- DISCOS Y PARTICIONES ---"
    lsblk

    registrar "Consulta de almacenamiento"
    pausa
}

# ======================================================
# 4. ESTADO DE SERVICIOS
# ======================================================

servicios() {
    titulo
    echo "ESTADO DE SERVICIOS PRINCIPALES"
    echo

    for servicio in sshd httpd mariadb docker firewalld; do
        echo
        echo "--- $servicio ---"

        if systemctl list-unit-files \
            "${servicio}.service" --no-legend \
            2>/dev/null | grep -q "${servicio}.service"; then

            systemctl is-active "$servicio" || true
            systemctl is-enabled "$servicio" || true

        else
            echo "Servicio no encontrado."
        fi
    done

    registrar "Consulta de servicios"
    pausa
}

# ======================================================
# 5. GESTION DE SERVICIOS
# ======================================================

gestionar_servicio() {
    titulo
    echo "GESTION DE SERVICIOS"
    echo

    echo "1. Apache"
    echo "2. MariaDB"
    echo "3. Docker"
    echo
    read -r -p "Seleccione servicio: " opcion

    case "$opcion" in
        1) servicio="httpd" ;;
        2) servicio="mariadb" ;;
        3) servicio="docker" ;;
        *)
            echo "Opcion invalida."
            pausa
            return
            ;;
    esac

    echo
    echo "1. Iniciar"
    echo "2. Detener"
    echo "3. Reiniciar"
    echo "4. Consultar estado"
    echo
    read -r -p "Seleccione accion: " accion

    case "$accion" in
        1) comando="start" ;;
        2) comando="stop" ;;
        3) comando="restart" ;;
        4) comando="status" ;;
        *)
            echo "Accion invalida."
            pausa
            return
            ;;
    esac

    if [[ "$comando" == "status" ]]; then
        systemctl status "$servicio" --no-pager || true
    else
        echo
        echo "ATENCION: esta accion puede interrumpir"
        echo "el funcionamiento de Nexo."

        if confirmar "Ejecutar $comando sobre $servicio?"; then
            if systemctl "comando""servicio"; then
                registrar "Servicio $servicio: $comando exitoso"
            else
                registrar "ERROR en $comando de $servicio"
            fi
        else
            echo "Operacion cancelada."
        fi
    fi

    pausa
}

# ======================================================
# 6. USUARIOS Y GRUPOS
# ======================================================

usuarios() {
    titulo
    echo "USUARIOS Y GRUPOS DEL SISTEMA"
    echo

    echo "--- USUARIOS ---"
    getent passwd | cut -d: -f1

    echo
    echo "--- GRUPOS DEL PROYECTO ---"

    for grupo in admin_general organizador; do
        getent group "$grupo" || \
            echo "$grupo no encontrado"
    done

    echo
    echo "--- CUENTA DE SERVICIO ---"
    id torneos_app 2>/dev/null || \
        echo "torneos_app no encontrada"

    registrar "Consulta de usuarios y grupos"
    pausa
}

# ======================================================
# 7. RED Y PUERTOS
# ======================================================

red() {
    titulo
    echo "INFORMACION DE RED"
    echo

    echo "--- DIRECCIONES IP ---"
    ip -br addr

    echo
    echo "--- PUERTOS EN ESCUCHA ---"
    ss -tulnp

    echo
    echo "--- RUTAS DE RED ---"
    ip route

    registrar "Consulta de red"
    pausa
}

# ======================================================
# 8. FIREWALL Y SELINUX
# ======================================================

seguridad() {
    titulo
    echo "ESTADO DE SEGURIDAD"
    echo

    echo "--- FIREWALL ---"
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --state || true
        firewall-cmd --list-all || true
    else
        echo "firewalld no instalado."
    fi

    echo
    echo "--- SELINUX ---"
    if command -v getenforce >/dev/null 2>&1; then
        getenforce
    else
        echo "SELinux no disponible."
    fi

    registrar "Consulta de seguridad"
    pausa
}

# ======================================================
# 9. ACTUALIZACIONES
# ======================================================

actualizaciones() {
    titulo
    echo "ACTUALIZACIONES DEL SISTEMA"
    echo

    echo "1. Consultar actualizaciones"
    echo "2. Instalar actualizaciones"
    echo
    read -r -p "Seleccione opcion: " opcion

    case "$opcion" in
        1)
            dnf check-update
            codigo=$?
            if [[ "$codigo" -eq 100 ]]; then
                echo "Hay actualizaciones disponibles."
            elif [[ "$codigo" -ne 0 ]]; then
                echo "Error al consultar actualizaciones."
            fi
            ;;
        2)
            echo
            echo "ATENCION: las actualizaciones pueden"
            echo "afectar servicios y requerir reinicio."

            if confirmar "Instalar actualizaciones?"; then
                if dnf upgrade -y; then
                    registrar "Actualizacion del sistema completada"
                else
                    registrar "ERROR al actualizar el sistema"
                fi
            fi
            ;;
        *)
            echo "Opcion invalida."
            ;;
    esac

    pausa
}

# ======================================================
# 10. REGISTROS DEL SISTEMA
# ======================================================

registros() {
    titulo
    echo "ULTIMOS REGISTROS DEL SISTEMA"
    echo

    echo "1. Registros generales"
    echo "2. Apache"
    echo "3. MariaDB"
    echo "4. Docker"
    echo "5. SSH"
    echo
    read -r -p "Seleccione opcion: " opcion

    case "$opcion" in
        1) journalctl -n 40 --no-pager ;;
        2) journalctl -u httpd -n 40 --no-pager ;;
        3) journalctl -u mariadb -n 40 --no-pager ;;
        4) journalctl -u docker -n 40 --no-pager ;;
        5) journalctl -u sshd -n 40 --no-pager ;;
        *) echo "Opcion invalida." ;;
    esac

    registrar "Consulta de registros"
    pausa
}

# ======================================================
# 11. ESTADO DE DOCKER
# ======================================================

docker_estado() {
    titulo
    echo "ESTADO DE CONTENEDORES DOCKER"
    echo

    if command -v docker >/dev/null 2>&1; then
        docker ps -a || true

        echo
        echo "--- USO DE RECURSOS ---"
        docker stats --no-stream || true
    else
        echo "Docker no esta instalado."
    fi

    registrar "Consulta de Docker"
    pausa
}

# ======================================================
# 12. REPORTE GENERAL
# ======================================================

reporte() {
    titulo

    DIRECTORIO="/var/log/nexo"
    mkdir -p "$DIRECTORIO"
    chmod 700 "$DIRECTORIO"

    ARCHIVO="$DIRECTORIO/reporte_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "=================================="
        echo "REPORTE GENERAL DEL SERVIDOR NEXO"
        echo "=================================="
        echo "Fecha: $(date)"
        echo

        echo "--- SISTEMA ---"
        cat /etc/os-release

        echo
        echo "--- TIEMPO ACTIVO ---"
        uptime

        echo
        echo "--- MEMORIA ---"
        free -h

        echo
        echo "--- DISCO ---"
        df -hT

        echo
        echo "--- SERVICIOS ---"
        for s in httpd mariadb docker sshd firewalld; do
            echo "$s: (systemctlis-active"s" 2>/dev/null || true)"
        done

        echo
        echo "--- SELINUX ---"
        getenforce 2>/dev/null || true

        echo
        echo "--- PUERTOS ---"
        ss -tuln

        echo
        echo "--- DOCKER ---"
        if command -v docker >/dev/null 2>&1; then
            docker ps -a 2>&1 || true
        fi

    } > "$ARCHIVO"

    chmod 600 "$ARCHIVO"

    registrar "Reporte generado: $ARCHIVO"

    echo
    echo "Reporte guardado en:"
    echo "$ARCHIVO"

    pausa
}

# ======================================================
# MENU PRINCIPAL
# ======================================================

while true; do

    titulo

    echo "1. Informacion general del servidor"
    echo "2. Monitorear CPU y memoria"
    echo "3. Consultar espacio en disco"
    echo "4. Consultar estado de servicios"
    echo "5. Iniciar, detener o reiniciar servicios"
    echo "6. Consultar usuarios y grupos"
    echo "7. Consultar red y puertos"
    echo "8. Consultar firewall y SELinux"
    echo "9. Gestionar actualizaciones"
    echo "10. Consultar registros del sistema"
    echo "11. Consultar contenedores Docker"
    echo "12. Generar reporte general"
    echo "0. Salir"

    echo
    read -r -p "Seleccione una opcion: " opcion

    case "$opcion" in
        1) informacion_servidor ;;
        2) recursos ;;
        3) discos ;;
        4) servicios ;;
        5) gestionar_servicio ;;
        6) usuarios ;;
        7) red ;;
        8) seguridad ;;
        9) actualizaciones ;;
        10) registros ;;
        11) docker_estado ;;
        12) reporte ;;
        0)
            registrar "Cierre del programa"
            echo "Saliendo..."
            exit 0
            ;;
        *)
            echo "Opcion incorrecta."
            sleep 2
            ;;
    esac

done
