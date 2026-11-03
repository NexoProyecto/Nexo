#!/usr/bin/env bash
# ==============================================================
# NEXO / CUPCORE - ADMINISTRACION Y MONITOREO
# Sistema objetivo: AlmaLinux 9.8
#
# IMPORTANTE:
# - NO instala paquetes ni servicios.
# - NO ejecuta instaladores ni crea/reemplaza la aplicacion.
# - Detecta una instalacion nativa (httpd/php-fpm/mariadb),
#   una instalacion Docker/Compose, o ambas.
# - Solo administra componentes que ya existan.
#
# Ejecutar: sudo bash gestion-servidor-nexo.sh
# ==============================================================

set -uo pipefail
umask 077

NOMBRE="NEXO / CUPCORE"
LOG="/var/log/gestion-servidor-nexo.log"
BASE_NATIVA="CupCore"
RUTAS_SITIO=(
  "/var/www/cupcore"
  "/var/www/html/servidor/sitio"
  "/var/www/html/Nexo/servidor/sitio"
  "/var/www/html/nexo/servidor/sitio"
)
RUTAS_DOCKER=(
  "/var/www/html/Nexo/docker"
  "/var/www/html/nexo/docker"
  "/opt/nexo/docker"
  "/opt/cupcore/docker"
)
SITIO=""
DOCKER_DIR=""
DB_CLIENT="$(command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null || true)"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: ejecuta como administrador: sudo bash $0"
  exit 1
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
touch "$LOG" 2>/dev/null || { echo "No se pudo crear el registro $LOG"; exit 1; }
chmod 600 "$LOG" 2>/dev/null || true

registrar() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
}

titulo() {
  clear 2>/dev/null || true
  echo "============================================================"
  echo "             ADMINISTRACION DEL SERVIDOR"
  echo "                  $NOMBRE"
  echo "============================================================"
  echo
}

pausa() {
  echo
  read -r -p "Presione ENTER para continuar..." _
}

confirmar() {
  local r
  read -r -p "$1 (s/N): " r
  [[ "$r" =~ ^[sS]$ ]]
}

separador() { echo "------------------------------------------------------------"; }

detectar_rutas() {
  local p
  for p in "${RUTAS_SITIO[@]}"; do
    if [[ -d "$p" ]]; then SITIO="$p"; break; fi
  done
  for p in "${RUTAS_DOCKER[@]}"; do
    if [[ -f "$p/docker-compose.yml" || -f "$p/compose.yml" || -f "$p/compose.yaml" ]]; then
      DOCKER_DIR="$p"; break
    fi
  done
  # Si no se encontró por las rutas conocidas, buscar en ubicaciones de proyecto habituales.
  if [[ -z "$SITIO" ]]; then
    for p in /var/www/html/Nexo/servidor/sitio /var/www/html/nexo/servidor/sitio /opt/nexo/servidor/sitio; do
      [[ -d "$p" ]] && { SITIO="$p"; break; }
    done
  fi
}
detectar_rutas

servicio_existe() {
  systemctl list-unit-files "${1}.service" --no-legend 2>/dev/null |
    awk '{print $1}' | grep -qx "${1}.service"
}

estado_servicio() {
  local s="$1" a h
  if servicio_existe "$s"; then
    a="$(systemctl is-active "$s" 2>/dev/null || true)"
    h="$(systemctl is-enabled "$s" 2>/dev/null || true)"
    printf '%-14s Estado: %-12s Inicio: %s\n' "$s" "${a:-desconocido}" "${h:-desconocido}"
  else
    printf '%-14s No instalado / unidad no encontrada\n' "$s"
  fi
}

compose_file() {
  [[ -n "$DOCKER_DIR" ]] || return 1
  if [[ -f "$DOCKER_DIR/docker-compose.yml" ]]; then
    echo "$DOCKER_DIR/docker-compose.yml"
  elif [[ -f "$DOCKER_DIR/compose.yaml" ]]; then
    echo "$DOCKER_DIR/compose.yaml"
  elif [[ -f "$DOCKER_DIR/compose.yml" ]]; then
    echo "$DOCKER_DIR/compose.yml"
  else
    return 1
  fi
}

compose() {
  local f
  f="$(compose_file)" || { echo "No se encontró un archivo Compose."; return 1; }
  docker compose --project-directory "$DOCKER_DIR" -f "$f" "$@"
}

modo_despliegue() {
  local nativo=0 docker_ok=0
  servicio_existe httpd && nativo=1
  servicio_existe mariadb && nativo=1
  command -v docker >/dev/null 2>&1 && docker_ok=1
  echo "Despliegue detectado:"
  if (( nativo )); then
    echo " - Instalación nativa: se detectaron unidades de Apache y/o MariaDB."
  else
    echo " - Instalación nativa: no detectada completamente."
  fi
  if (( docker_ok )) && [[ -n "$DOCKER_DIR" ]]; then
    echo " - Docker/Compose: disponible; proyecto detectado en $DOCKER_DIR"
  elif (( docker_ok )); then
    echo " - Docker: instalado, pero no se encontró el archivo Compose en rutas conocidas."
  else
    echo " - Docker: no instalado."
  fi
  [[ -n "$SITIO" ]] && echo " - Carpeta del sitio: $SITIO" || echo " - Carpeta del sitio: no localizada en rutas conocidas."
}

# 1. Información general
informacion() {
  titulo
  echo "INFORMACION GENERAL"
  separador
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "Sistema: ${PRETTY_NAME:-desconocido}"
  fi
  echo "Kernel: $(uname -r)"
  echo "Equipo: $(hostname)"
  echo "Fecha: $(date)"
  echo "Tiempo encendido: $(uptime -p 2>/dev/null || uptime)"
  echo
  echo "Versiones detectadas:"
  command -v httpd >/dev/null 2>&1 && httpd -v | head -n1 || echo "Apache: no detectado"
  command -v php >/dev/null 2>&1 && php -v | head -n1 || echo "PHP: no detectado en el host"
  [[ -n "$DB_CLIENT" ]] && "$DB_CLIENT" --version || echo "Cliente MariaDB/MySQL: no detectado"
  command -v docker >/dev/null 2>&1 && docker --version || echo "Docker: no detectado"
  command -v curl >/dev/null 2>&1 && curl --version | head -n1 || echo "curl: no detectado"
  echo
  modo_despliegue
  registrar "Consulta de información general"
  pausa
}

# 2. CPU y memoria
recursos() {
  titulo
  echo "CPU, MEMORIA Y PROCESOS"
  separador
  uptime
  echo
  command -v lscpu >/dev/null 2>&1 && lscpu | grep -E '^(Architecture|CPU\(s\)|Model name|Thread|Core|Socket)' || true
  echo
  free -h
  echo
  echo "Procesos con mayor uso de CPU:"
  ps -eo pid,user,comm,%cpu,%mem --sort=-%cpu | head -n 11
  echo
  echo "Procesos con mayor uso de memoria:"
  ps -eo pid,user,comm,%mem,%cpu --sort=-%mem | head -n 11
  registrar "Consulta de recursos"
  pausa
}

# 3. Almacenamiento
almacenamiento() {
  titulo
  echo "DISCOS Y ALMACENAMIENTO"
  separador
  df -hT
  echo
  lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS 2>/dev/null || true
  echo
  for p in "$SITIO" "$DOCKER_DIR" /var/log/httpd /var/log/cupcore /backup/mysql /etc/cupcore; do
    [[ -n "$p" ]] || continue
    if [[ -e "$p" ]]; then du -sh "$p" 2>/dev/null; else echo "$p: no existe"; fi
  done
  registrar "Consulta de almacenamiento"
  pausa
}

# 4. Servicios
servicios() {
  titulo
  echo "ESTADO DE SERVICIOS"
  separador
  for s in httpd php-fpm mariadb firewalld fail2ban suricata crond docker; do
    estado_servicio "$s"
  done
  echo
  echo "Nota: que un servicio no esté instalado no provoca una instalación automática."
  registrar "Consulta de servicios"
  pausa
}

# 5. Administrar servicio
gestionar_servicio() {
  titulo
  echo "GESTION DE SERVICIOS EXISTENTES"
  echo "1) Apache (httpd)"
  echo "2) PHP-FPM"
  echo "3) MariaDB"
  echo "4) Firewall (firewalld)"
  echo "5) Fail2ban"
  echo "6) Suricata"
  echo "7) Cron (crond)"
  echo "8) Docker"
  read -r -p "Servicio: " op
  case "$op" in
    1) s=httpd;; 2) s=php-fpm;; 3) s=mariadb;; 4) s=firewalld;;
    5) s=fail2ban;; 6) s=suricata;; 7) s=crond;; 8) s=docker;;
    *) echo "Opción inválida."; pausa; return;;
  esac
  if ! servicio_existe "$s"; then
    echo "No se puede administrar $s: la unidad no está instalada."
    pausa; return
  fi
  echo
  systemctl status "$s" --no-pager -l 2>/dev/null | head -n 12
  echo
  echo "1) Iniciar  2) Detener  3) Reiniciar  4) Habilitar al inicio  5) Deshabilitar inicio"
  read -r -p "Acción: " ac
  case "$ac" in
    1) cmd="start";; 2) cmd="stop";; 3) cmd="restart";;
    4) cmd="enable";; 5) cmd="disable";;
    *) echo "Acción inválida."; pausa; return;;
  esac
  case "$s:$cmd" in
    mariadb:stop|mariadb:restart)
      echo "ATENCION: MariaDB contiene la base de datos. El sitio puede dejar de funcionar.";;
    httpd:stop|httpd:restart|php-fpm:stop|php-fpm:restart)
      echo "ATENCION: esta acción puede interrumpir el acceso al sitio.";;
  esac
  if confirmar "¿Ejecutar systemctl $cmd $s?"; then
    if systemctl "$cmd" "$s"; then
      echo "Acción completada."; registrar "Servicio $s: $cmd correcto"
    else
      echo "No se pudo completar."; registrar "ERROR: $cmd $s"
    fi
  else
    echo "Cancelado."
  fi
  pausa
}

# 6. Base de datos nativa
base_datos() {
  titulo
  echo "MARIADB / BASE CUPCORE (INSTALACION NATIVA)"
  separador
  if ! servicio_existe mariadb; then
    echo "No se detectó el servicio MariaDB nativo."
    echo "Si la base funciona en Docker, revisa la opción Docker."
    pausa; return
  fi
  systemctl is-active mariadb 2>/dev/null || true
  if [[ -z "$DB_CLIENT" ]]; then
    echo "No se encontró cliente mariadb/mysql en el host."
    pausa; return
  fi
  if ! "$DB_CLIENT" -NBe "SELECT 1" >/dev/null 2>&1; then
    echo "No se pudo conectar con las credenciales locales disponibles."
    echo "No se muestra ni solicita ninguna contraseña."
    echo "Si el administrador configuró autenticación por archivo, revisa sus permisos."
    pausa; return
  fi
  echo "Conexión local: correcta"
  "$DB_CLIENT" -e "SELECT VERSION() AS version;"
  echo
  if "$DB_CLIENT" -NBe "SHOW DATABASES LIKE '$BASE_NATIVA'" | grep -qx "$BASE_NATIVA"; then
    echo "Tablas de $BASE_NATIVA:"
    "$DB_CLIENT" -e "SELECT TABLE_NAME, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='$BASE_NATIVA' AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME;"
    echo
    echo "Cuentas de base relacionadas:"
    "$DB_CLIENT" -e "SELECT User,Host FROM mysql.user WHERE User LIKE 'cupcore%' OR User='nexo' ORDER BY User,Host;"
  else
    echo "La base '$BASE_NATIVA' no existe con ese nombre."
    echo "No se crea ni modifica ninguna base desde este menú."
  fi
  echo
  echo "Puerto 3306:"
  ss -ltnp 2>/dev/null | grep ':3306' || echo "No se detecta escucha TCP en 3306."
  registrar "Consulta de base de datos nativa"
  pausa
}

# 7. Usuarios y permisos
usuarios() {
  titulo
  echo "USUARIOS Y PERMISOS"
  separador
  id apache 2>/dev/null || echo "Usuario apache no encontrado."
  echo
  if [[ -n "$SITIO" ]]; then
    stat -c 'Sitio: %n | propietario: %U:%G | permisos: %a' "$SITIO"
    find "$SITIO" -maxdepth 2 -type d -printf '%M %u:%g %p\n' 2>/dev/null | head -n 20
  else
    echo "No se encontró la carpeta del sitio en las rutas conocidas."
  fi
  echo
  if [[ -f /root/cupcore-credenciales.txt ]]; then
    stat -c 'Credenciales: %n | propietario: %U:%G | permisos: %a' /root/cupcore-credenciales.txt
    echo "Contenido oculto por seguridad."
  else
    echo "No existe /root/cupcore-credenciales.txt (puede usarse otra ubicación o Docker)."
  fi
  if [[ -n "$DB_CLIENT" ]] && "$DB_CLIENT" -NBe "SELECT 1" >/dev/null 2>&1; then
    echo
    "$DB_CLIENT" -e "SELECT User,Host FROM mysql.user WHERE User LIKE 'cupcore%' OR User='nexo' ORDER BY User,Host;"
  fi
  registrar "Consulta de usuarios y permisos"
  pausa
}

# 8. Red y puertos
red() {
  titulo
  echo "RED Y PUERTOS"
  separador
  ip -br addr 2>/dev/null || true
  echo
  ip route 2>/dev/null || true
  echo
  ss -tulnp 2>/dev/null || true
  echo
  for p in 22 80 443 3306; do
    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "([:.])${p}$"; then
      echo "TCP $p: en escucha"
    else
      echo "TCP $p: sin escucha detectada"
    fi
  done
  echo
  echo "Recomendación de seguridad: MariaDB no debería exponerse a Internet."
  registrar "Consulta de red"
  pausa
}

# 9. Seguridad
seguridad() {
  titulo
  echo "FIREWALL, SELINUX Y SEGURIDAD"
  separador
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --state 2>/dev/null || true
    firewall-cmd --list-all 2>/dev/null || true
  else
    echo "firewalld no detectado."
  fi
  echo
  command -v getenforce >/dev/null 2>&1 && echo "SELinux: $(getenforce)" || echo "SELinux: herramienta no detectada"
  echo
  if command -v fail2ban-client >/dev/null 2>&1; then
    fail2ban-client status 2>/dev/null || true
  else
    echo "Fail2ban no detectado."
  fi
  echo
  if command -v suricata >/dev/null 2>&1; then
    suricata --build-info 2>/dev/null | head -n 5
    [[ -f /var/log/suricata/fast.log ]] && tail -n 10 /var/log/suricata/fast.log
  else
    echo "Suricata no detectado."
  fi
  echo
  echo "Escucha de MariaDB:"
  ss -ltnp 2>/dev/null | grep ':3306' || echo "No detectada."
  registrar "Consulta de seguridad"
  pausa
}

# 10. Certificado HTTPS
certificado() {
  titulo
  echo "CERTIFICADOS HTTPS"
  separador
  local encontrados=0 cert
  for cert in /etc/pki/tls/certs/cupcore.crt /etc/ssl/nexo/server.crt /etc/letsencrypt/live/*/fullchain.pem; do
    [[ -f "$cert" ]] || continue
    encontrados=1
    echo "Certificado: $cert"
    openssl x509 -in "$cert" -noout -subject -issuer -dates 2>/dev/null || true
    echo
  done
  (( encontrados )) || echo "No se encontraron certificados en las ubicaciones habituales."
  echo "No se genera ni reemplaza ningún certificado desde este menú."
  registrar "Consulta de certificados"
  pausa
}

# 11. Registros
registros() {
  titulo
  echo "REGISTROS"
  echo "1) Administrador"
  echo "2) Apache error"
  echo "3) Apache access"
  echo "4) MariaDB journal"
  echo "5) PHP-FPM journal"
  echo "6) Fail2ban"
  echo "7) Suricata"
  echo "8) Journal general"
  read -r -p "Opción: " op
  case "$op" in
    1) f="$LOG";;
    2) f="/var/log/httpd/error_log";;
    3) f="/var/log/httpd/access_log";;
    4) journalctl -u mariadb -n 60 --no-pager; f="";;
    5) journalctl -u php-fpm -n 60 --no-pager; f="";;
    6) f="/var/log/fail2ban.log";;
    7) f="/var/log/suricata/fast.log";;
    8) journalctl -n 60 --no-pager; f="";;
    *) echo "Opción inválida."; pausa; return;;
  esac
  if [[ -n "${f:-}" ]]; then
    [[ -f "$f" ]] && tail -n 60 "$f" || echo "No existe el registro: $f"
  fi
  registrar "Consulta de registros, opción $op"
  pausa
}

# 12. Docker
docker_estado() {
  titulo
  echo "DOCKER Y CONTENEDORES"
  separador
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker no está instalado."
    pausa; return
  fi
  docker --version
  docker compose version 2>/dev/null || echo "Docker Compose no disponible."
  echo
  systemctl is-active docker 2>/dev/null || true
  echo
  docker ps -a 2>&1 || true
  echo
  if [[ -n "$DOCKER_DIR" ]]; then
    echo "Proyecto Compose detectado: $DOCKER_DIR"
    compose ps 2>&1 || true
    echo
    echo "Servicios definidos en Compose:"
    compose config --services 2>/dev/null || true
  else
    echo "No se encontró un proyecto Compose en las rutas conocidas."
  fi
  echo
  echo "Este apartado solo consulta contenedores; no instala, crea ni levanta contenedores."
  registrar "Consulta de Docker"
  pausa
}

# 13. Pruebas web
pruebas_web() {
  titulo
  echo "PRUEBAS HTTP/HTTPS LOCALES"
  separador
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl no está instalado; no se puede realizar la prueba."
    pausa; return
  fi
  local http https
  http="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1/ 2>/dev/null || true)"
  https="$(curl -skS -o /dev/null -w '%{http_code}' --max-time 8 https://127.0.0.1/ 2>/dev/null || true)"
  [[ -n "$http" ]] || http="000"
  [[ -n "$https" ]] || https="000"
  echo "HTTP  : $http"
  echo "HTTPS : $https"
  echo
  echo "Cabeceras HTTPS:"
  curl -skI --max-time 8 https://127.0.0.1/ 2>/dev/null |
    grep -iE '^(HTTP/|strict-transport-security:|content-security-policy:|x-content-type-options:|x-frame-options:)' || true
  echo
  echo "Interpretación: 200 suele indicar respuesta correcta; 301/302 redirección; 403 acceso denegado; 404 ruta inexistente; 000 sin conexión."
  registrar "Pruebas HTTP/HTTPS"
  pausa
}

# 14. Actualizaciones disponibles (solo consulta)
actualizaciones() {
  titulo
  echo "ACTUALIZACIONES DISPONIBLES (CONSULTA)"
  separador
  if ! command -v dnf >/dev/null 2>&1; then
    echo "DNF no está disponible."
  else
    echo "Se consultan actualizaciones; no se instala nada."
    dnf check-update
    rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "No se encontraron actualizaciones pendientes."
    elif [[ $rc -eq 100 ]]; then
      echo "Hay actualizaciones disponibles."
    else
      echo "DNF terminó con código $rc; revisar repositorios o conexión."
    fi
  fi
  registrar "Consulta de actualizaciones"
  pausa
}

# 15. Informe
informe() {
  titulo
  local salida="/var/log/reporte-nexo-$(date +%F_%H%M%S).txt"
  {
    echo "REPORTE NEXO / CUPCORE"
    date
    echo
    . /etc/os-release 2>/dev/null || true
    echo "Sistema: ${PRETTY_NAME:-desconocido}"
    echo "Kernel: $(uname -r)"
    echo
    echo "=== DESPLIEGUE ==="
    modo_despliegue
    echo
    echo "=== SERVICIOS ==="
    for s in httpd php-fpm mariadb firewalld fail2ban suricata crond docker; do estado_servicio "$s"; done
    echo
    echo "=== MEMORIA ==="
    free -h
    echo
    echo "=== DISCOS ==="
    df -hT
    echo
    echo "=== PUERTOS ==="
    ss -tulnp 2>/dev/null || true
    echo
    echo "=== CONTENEDORES ==="
    command -v docker >/dev/null 2>&1 && docker ps -a 2>&1 || echo "Docker no detectado."
  } > "$salida"
  chmod 600 "$salida"
  echo "Informe creado: $salida"
  registrar "Informe generado: $salida"
  pausa
}

# Menú principal
while true; do
  titulo
  echo "1) Información general y detección de instalación"
  echo "2) CPU y memoria"
  echo "3) Discos y almacenamiento"
  echo "4) Estado de servicios"
  echo "5) Administrar servicios existentes"
  echo "6) MariaDB y base CupCore (nativo)"
  echo "7) Usuarios y permisos"
  echo "8) Red y puertos"
  echo "9) Firewall, SELinux y seguridad"
  echo "10) Certificados HTTPS"
  echo "11) Consultar registros"
  echo "12) Docker y contenedores"
  echo "13) Pruebas HTTP/HTTPS"
  echo "14) Consultar actualizaciones (sin instalar)"
  echo "15) Generar informe"
  echo "0) Salir"
  echo
  read -r -p "Seleccione una opción: " op
  case "$op" in
    1) informacion;; 2) recursos;; 3) almacenamiento;; 4) servicios;;
    5) gestionar_servicio;; 6) base_datos;; 7) usuarios;; 8) red;;
    9) seguridad;; 10) certificado;; 11) registros;; 12) docker_estado;;
    13) pruebas_web;; 14) actualizaciones;; 15) informe;;
    0) exit 0;;
    *) echo "Opción inválida."; sleep 1;;
  esac
done
