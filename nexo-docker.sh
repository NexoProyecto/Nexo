#!/usr/bin/env bash
# ============================================================
#  Nexo / CupCore -> Docker  (AlmaLinux 9)
#  Menú que instala Docker, crea los archivos, genera HTTPS,
#  levanta PHP+Apache+MariaDB, importa la BD y hace respaldos.
#  Ubicación: /var/www/html/Nexo/nexo-docker.sh
#  Uso: sudo bash nexo-docker.sh
# ============================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$BASE_DIR/docker"
SITIO_DIR="$BASE_DIR/servidor/sitio"
SQL_DIR="$BASE_DIR/servidor/base-de-datos"
RESPALDO_DIR="$BASE_DIR/servidor/respaldo"
ENV_FILE="$DOCKER_DIR/.env"

G="\e[32m"; R="\e[31m"; Y="\e[33m"; B="\e[36m"; N="\e[0m"
ok()   { echo -e "${G}[OK]${N} $*"; }
err()  { echo -e "${R}[ERROR]${N} $*"; }
warn() { echo -e "${Y}[AVISO]${N} $*"; }
info() { echo -e "${B}[..]${N} $*"; }
pausa(){ echo; read -rp "Enter para continuar..." _; }

if [[ $EUID -ne 0 ]]; then
  err "Ejecuta como root:  sudo bash $0"
  exit 1
fi

compose() { docker compose --project-directory "$DOCKER_DIR" -f "$DOCKER_DIR/docker-compose.yml" "$@"; }

cargar_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
    return 0
  fi
  return 1
}

# ------------------------------------------------------------
# 1) Instalar Docker
# ------------------------------------------------------------
instalar_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker y Compose ya están instalados: $(docker --version)"
    systemctl enable --now docker >/dev/null 2>&1
    return
  fi
  info "Instalando Docker CE (repositorio oficial para RHEL/Alma 9)..."
  dnf -y install dnf-plugins-core || { err "No se pudo instalar dnf-plugins-core"; return 1; }
  dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo || { err "No se pudo agregar el repositorio"; return 1; }
  dnf -y install --allowerasing docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || { err "Falló la instalación de Docker"; return 1; }
  systemctl enable --now docker || { err "No arrancó el servicio docker"; return 1; }
  ok "Docker instalado: $(docker --version)"
}

# ------------------------------------------------------------
# 2) Crear archivos Docker
# ------------------------------------------------------------
crear_archivos() {
  if [[ ! -d "$SITIO_DIR" ]]; then
    err "No existe $SITIO_DIR. Revisa la ruta del sitio."
    return 1
  fi
  mkdir -p "$DOCKER_DIR/web" "$DOCKER_DIR/certs" "$RESPALDO_DIR"

  # --- .env (solo si no existe, para no cambiar contraseñas) ---
  if [[ ! -f "$ENV_FILE" ]]; then
    local rootp userp
    rootp="$(openssl rand -hex 16)"
    userp="$(openssl rand -hex 16)"
    cat > "$ENV_FILE" <<EOF
DB_NAME=ciberseguridad
DB_USER=nexo
DB_PASS=$userp
DB_ROOT_PASS=$rootp
HTTP_PORT=80
HTTPS_PORT=443
EOF
    chmod 600 "$ENV_FILE"
    ok "Creado $ENV_FILE (contraseñas generadas al azar)"
  else
    warn ".env ya existe, no se modifica"
  fi

  # --- Dockerfile ---
  cat > "$DOCKER_DIR/web/Dockerfile" <<'EOF'
FROM php:8.3-apache

RUN docker-php-ext-install pdo_mysql mysqli \
 && a2enmod ssl rewrite headers

COPY nexo.conf /etc/apache2/sites-available/000-default.conf

# Ajustes de PHP recomendados
RUN { \
      echo "expose_php=Off"; \
      echo "display_errors=Off"; \
      echo "log_errors=On"; \
      echo "upload_max_filesize=20M"; \
      echo "post_max_size=25M"; \
    } > /usr/local/etc/php/conf.d/nexo.ini

RUN echo "ServerTokens Prod" >> /etc/apache2/conf-available/security.conf \
 && echo "ServerSignature Off" >> /etc/apache2/conf-available/security.conf
EOF

  # --- Apache vhost (HTTP -> HTTPS) ---
  cat > "$DOCKER_DIR/web/nexo.conf" <<'EOF'
<VirtualHost *:80>
    RewriteEngine On
    RewriteCond %{HTTPS} off
    RewriteRule ^/?(.*) https://%{SERVER_NAME}/$1 [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile    /etc/ssl/nexo/server.crt
    SSLCertificateKeyFile /etc/ssl/nexo/server.key

    Header always set Strict-Transport-Security "max-age=31536000"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"

    <Directory /var/www/html>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

  # --- docker-compose.yml ---
  cat > "$DOCKER_DIR/docker-compose.yml" <<'EOF'
name: nexo

services:
  db:
    image: mariadb:11
    container_name: nexo-db
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASS}
      MARIADB_DATABASE: ${DB_NAME}
      MARIADB_USER: ${DB_USER}
      MARIADB_PASSWORD: ${DB_PASS}
    volumes:
      - nexo_db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 12
    networks: [nexo]

  web:
    build: ./web
    container_name: nexo-web
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      DB_HOST: db
      DB_PORT: "3306"
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASS: ${DB_PASS}
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ../servidor/sitio:/var/www/html:z
      - ./certs:/etc/ssl/nexo:ro,z
    networks: [nexo]

volumes:
  nexo_db_data:

networks:
  nexo:
EOF
  ok "Archivos creados en $DOCKER_DIR"
}

# ------------------------------------------------------------
# 3) Certificado HTTPS autofirmado
# ------------------------------------------------------------
generar_cert() {
  mkdir -p "$DOCKER_DIR/certs"
  if [[ -f "$DOCKER_DIR/certs/server.crt" ]]; then
    read -rp "Ya hay un certificado. ¿Regenerar? (s/N): " r
    [[ "$r" =~ ^[sS]$ ]] || return
  fi
  local ip host
  ip="$(hostname -I | awk '{print $1}')"
  host="$(hostname)"
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "$DOCKER_DIR/certs/server.key" \
    -out "$DOCKER_DIR/certs/server.crt" \
    -subj "/CN=$host" \
    -addext "subjectAltName=DNS:$host,DNS:localhost,IP:$ip" 2>/dev/null \
    && chmod 600 "$DOCKER_DIR/certs/server.key" \
    && ok "Certificado autofirmado creado (IP $ip). El navegador mostrará aviso; para producción usa uno real (Let's Encrypt o el de tu institución)." \
    || err "No se pudo generar el certificado"
}

# ------------------------------------------------------------
# 4) Firewall
# ------------------------------------------------------------
abrir_firewall() {
  if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=http --add-service=https >/dev/null
    firewall-cmd --reload >/dev/null
    ok "Puertos 80 y 443 abiertos en firewalld"
  else
    warn "firewalld no está activo, nada que hacer"
  fi
}

# ------------------------------------------------------------
# 5) Levantar contenedores
# ------------------------------------------------------------
verificar_puertos() {
  local p
  for p in 80 443; do
    if ss -ltn | awk '{print $4}' | grep -qE "[:.]${p}$"; then
      warn "El puerto $p ya está en uso en el servidor (¿httpd/nginx del host?)."
      warn "Detén el servicio del host (ej: systemctl disable --now httpd) o cambia HTTP_PORT/HTTPS_PORT en $ENV_FILE"
      read -rp "¿Continuar de todos modos? (s/N): " r
      [[ "$r" =~ ^[sS]$ ]] || return 1
    fi
  done
}

levantar() {
  [[ -f "$DOCKER_DIR/docker-compose.yml" ]] || { err "Primero crea los archivos (opción 2)"; return 1; }
  [[ -f "$DOCKER_DIR/certs/server.crt" ]]   || { err "Primero genera el certificado (opción 3)"; return 1; }
  verificar_puertos || return 1
  info "Construyendo y levantando contenedores..."
  compose up -d --build && ok "Contenedores arriba" || err "Falló docker compose up"
  compose ps
}

# ------------------------------------------------------------
# 6) Importar base de datos
# ------------------------------------------------------------
esperar_db() {
  info "Esperando a que MariaDB esté lista..."
  local i
  for i in $(seq 1 30); do
    [[ "$(docker inspect -f '{{.State.Health.Status}}' nexo-db 2>/dev/null)" == "healthy" ]] && return 0
    sleep 2
  done
  err "MariaDB no respondió a tiempo"; return 1
}

importar_bd() {
  cargar_env || { err "Falta $ENV_FILE (opción 2)"; return 1; }
  docker ps --format '{{.Names}}' | grep -qx nexo-db || { err "El contenedor nexo-db no está corriendo (opción 4)"; return 1; }
  esperar_db || return 1

  echo "¿Qué archivo importar?"
  echo "  1) BD_CupCore.sql (estructura)"
  echo "  2) CupCore_datos_ejemplo.sql (datos de ejemplo)"
  echo "  3) Otra ruta"
  read -rp "Opción: " o
  local f
  case "$o" in
    1) f="$SQL_DIR/BD_CupCore.sql" ;;
    2) f="$SQL_DIR/CupCore_datos_ejemplo.sql" ;;
    3) read -rp "Ruta completa del .sql: " f ;;
    *) warn "Opción inválida"; return ;;
  esac
  [[ -f "$f" ]] || { err "No existe: $f"; return 1; }

  info "Importando $f en la base '$DB_NAME'..."
  docker exec -i -e MYSQL_PWD="$DB_ROOT_PASS" nexo-db mariadb -uroot "$DB_NAME" < "$f" \
    && ok "Importación terminada" || err "Falló la importación (revisa si el .sql trae CREATE DATABASE/USE con otro nombre)"
}

# ------------------------------------------------------------
# 7) Respaldo (reemplaza a respaldo_sdgm.sh para la BD)
# ------------------------------------------------------------
respaldo_bd() {
  cargar_env || { err "Falta $ENV_FILE"; return 1; }
  docker ps --format '{{.Names}}' | grep -qx nexo-db || { err "nexo-db no está corriendo"; return 1; }
  mkdir -p "$RESPALDO_DIR"
  local out="$RESPALDO_DIR/db_${DB_NAME}_$(date +%F_%H%M%S).sql.gz"
  docker exec -e MYSQL_PWD="$DB_ROOT_PASS" nexo-db \
    mariadb-dump -uroot --single-transaction --routines --triggers "$DB_NAME" | gzip > "$out" \
    && ok "Respaldo creado: $out" || err "Falló el respaldo"
  # conserva solo los últimos 14
  ls -1t "$RESPALDO_DIR"/db_*.sql.gz 2>/dev/null | tail -n +15 | xargs -r rm -f
}

restaurar_bd() {
  cargar_env || { err "Falta $ENV_FILE"; return 1; }
  ls -1t "$RESPALDO_DIR"/db_*.sql.gz 2>/dev/null | head -n 10
  read -rp "Ruta del respaldo .sql.gz a restaurar: " f
  [[ -f "$f" ]] || { err "No existe"; return 1; }
  read -rp "Esto sobrescribe la base '$DB_NAME'. ¿Seguro? (s/N): " r
  [[ "$r" =~ ^[sS]$ ]] || return
  gunzip -c "$f" | docker exec -i -e MYSQL_PWD="$DB_ROOT_PASS" nexo-db mariadb -uroot "$DB_NAME" \
    && ok "Restaurado" || err "Falló la restauración"
}

# ------------------------------------------------------------
# 8) Estado, logs, control
# ------------------------------------------------------------
estado() { compose ps; echo; docker stats --no-stream nexo-web nexo-db 2>/dev/null; }
logs()   { compose logs --tail=60 -f; }
detener(){ compose down && ok "Contenedores detenidos (los datos se conservan)"; }
reiniciar(){ compose restart && ok "Reiniciado"; }
shell_web(){ docker exec -it nexo-web bash; }
shell_db() { cargar_env; docker exec -it -e MYSQL_PWD="$DB_ROOT_PASS" nexo-db mariadb -uroot "$DB_NAME"; }

mostrar_credenciales() {
  if [[ -f "$ENV_FILE" ]]; then
    echo; cat "$ENV_FILE"
    echo; warn "Guarda estas credenciales en un lugar seguro."
  else
    err "Aún no existe .env"
  fi
}

# ------------------------------------------------------------
# 9) Todo automático
# ------------------------------------------------------------
todo_automatico() {
  instalar_docker  || return
  crear_archivos   || return
  generar_cert
  abrir_firewall
  levantar         || return
  esperar_db       || return
  cargar_env
  if [[ -f "$SQL_DIR/BD_CupCore.sql" ]]; then
    info "Importando BD_CupCore.sql..."
    docker exec -i -e MYSQL_PWD="$DB_ROOT_PASS" nexo-db mariadb -uroot "$DB_NAME" < "$SQL_DIR/BD_CupCore.sql" \
      && ok "Base importada" || warn "La importación falló; hazla manualmente (opción 6)"
  fi
  echo
  ok "Listo. Abre: https://$(hostname -I | awk '{print $1}')"
}

# ------------------------------------------------------------
# Menú
# ------------------------------------------------------------
while true; do
  clear
  echo -e "${B}=====================================${N}"
  echo -e "${B}   NEXO / CupCore  ->  DOCKER${N}"
  echo -e "${B}=====================================${N}"
  echo " 1) Instalar Docker y Compose"
  echo " 2) Crear archivos Docker (Dockerfile, compose, .env)"
  echo " 3) Generar certificado HTTPS"
  echo " 4) Abrir firewall (80/443)"
  echo " 5) Levantar contenedores"
  echo " 6) Importar base de datos"
  echo " 7) Respaldo de la base de datos"
  echo " 8) Restaurar respaldo"
  echo " 9) Estado"
  echo "10) Ver logs"
  echo "11) Reiniciar"
  echo "12) Detener"
  echo "13) Shell del contenedor web"
  echo "14) Consola MariaDB"
  echo "15) Ver credenciales (.env)"
  echo "16) TODO AUTOMÁTICO (1 a 6)"
  echo " 0) Salir"
  echo
  read -rp "Opción: " op
  case "$op" in
    1) instalar_docker; pausa ;;
    2) crear_archivos; pausa ;;
    3) generar_cert; pausa ;;
    4) abrir_firewall; pausa ;;
    5) levantar; pausa ;;
    6) importar_bd; pausa ;;
    7) respaldo_bd; pausa ;;
    8) restaurar_bd; pausa ;;
    9) estado; pausa ;;
    10) logs ;;
    11) reiniciar; pausa ;;
    12) detener; pausa ;;
    13) shell_web ;;
    14) shell_db ;;
    15) mostrar_credenciales; pausa ;;
    16) todo_automatico; pausa ;;
    0) exit 0 ;;
    *) warn "Opción inválida"; sleep 1 ;;
  esac
done
