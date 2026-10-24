#!/bin/bash
# gestion_usuarios_torneos.sh
# Gestion de usuarios y permisos del sistema operativo para el
# servidor del SGDM (Sistema de Gestion Deportiva Modular).
# Uso: sudo bash gestion_usuarios_torneos.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Este script debe ejecutarse como root (sudo)." >&2
  exit 1
fi

echo "== 1. Grupo y cuentas de administracion del servidor =="
if ! getent group admin_general > /dev/null; then
  groupadd admin_general
fi
read -rp "  Usuario administrador a crear (Enter para omitir): " ADMIN_USER || true
if [[ -n "${ADMIN_USER:-}" ]]; then
  useradd -m -s /bin/bash -G admin_general,sudo "$ADMIN_USER"
  passwd "$ADMIN_USER"
fi

echo "== 2. Grupo y cuentas de organizadores de torneo =="
if ! getent group organizador > /dev/null; then
  groupadd organizador
fi
read -rp "  Usuario organizador a crear (Enter para omitir): " ORG_USER || true
if [[ -n "${ORG_USER:-}" ]]; then
  useradd -m -s /bin/bash -G organizador "$ORG_USER"
  passwd "$ORG_USER"
fi

echo "== 3. Cuenta de servicio de la aplicacion (torneos_app) =="
if ! getent group torneos_app > /dev/null; then
  groupadd --system torneos_app
fi
if ! id torneos_app &> /dev/null; then
  useradd --system --gid torneos_app --home-dir /srv/torneos \
          --no-create-home --shell /usr/sbin/nologin torneos_app
  usermod -L torneos_app
fi

echo "== 4. Estructura de directorios (FHS) =="
mkdir -p /srv/torneos/resultados
mkdir -p /srv/torneos/reportes
mkdir -p /etc/torneos
mkdir -p /var/log/torneos/auditoria

echo "== 5. Propietarios y permisos =="
chown -R torneos_app:torneos_app /srv/torneos
chmod -R 750 /srv/torneos
chown -R torneos_app:organizador /srv/torneos/resultados
chmod -R 770 /srv/torneos/resultados
chown -R torneos_app:organizador /srv/torneos/reportes
chmod -R 750 /srv/torneos/reportes
chown -R root:torneos_app /etc/torneos
chmod -R 750 /etc/torneos
find /etc/torneos -type f -exec chmod 640 {} \;
chown -R torneos_app:admin_general /var/log/torneos
chmod -R 750 /var/log/torneos

echo "== Listo =="
getent group admin_general
getent group organizador
getent group torneos_app
