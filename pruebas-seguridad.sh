#!/usr/bin/env bash
#==============================================================================
# pruebas-seguridad.sh — pruebas de seguridad de CupCore en el servidor
#
# Menu de consola que corre en el servidor, como root, despues de instalar
# CupCore con instalar-servidor.sh. No instala ni cambia la configuracion:
# hace pedidos al sitio por https://127.0.0.1 (ingresos, inyeccion SQL, XSS,
# CSRF, TLS) y lee el estado del sistema (SELinux, puertos, MariaDB, permisos,
# PHP, fail2ban, Suricata, respaldos). Los ingresos de prueba quedan en el
# registro de accesos y en la auditoria, como cualquier ingreso.
#
# Cada corrida deja un informe de texto en /root/cupcore-pruebas-FECHA.txt.
#
# Uso, como root:
#   sudo bash pruebas-seguridad.sh
#   NO_COLOR, SOLO_ASCII, ANCHO_MARCO   pantalla sin color, sin Unicode o de ancho fijo
#==============================================================================
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -uo pipefail

#==============================================================================
# Interfaz de consola: marcos, menus, tablas, reloj de avance y confirmaciones
#==============================================================================
shopt -s extglob

#--------------------------------------------------------------- Capacidades
# Color y glifos se deciden una vez, al iniciar. Sin TTY (salida a archivo o
# a un pipe) se apaga el color: los codigos ANSI ensucian el texto guardado.
UI_COLOR=1
UI_UNICODE=1

ui__detectar() {
    local colores
    [ -t 1 ] || UI_COLOR=0
    [ -n "${NO_COLOR:-}" ] && UI_COLOR=0
    colores=$(tput colors 2>/dev/null || printf '0')
    [ "$colores" -ge 8 ] 2>/dev/null || UI_COLOR=0
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8*|*utf8*|*UTF8*) ;;
        *) UI_UNICODE=0 ;;
    esac
    [ -n "${SOLO_ASCII:-}" ] && UI_UNICODE=0
    # La consola de texto de Linux no tiene los glifos de estado ni el reloj
    [ "${TERM:-}" = linux ] && UI_UNICODE=0
    return 0
}

#-------------------------------------------------------------------- Paleta
# Paleta 256 saturada, sin negrita, para terminal de fondo negro. La forma
# $'\033' guarda el byte ESC real: el ancho visible se mide quitando los
# codigos, y para eso tienen que estar en la variable.
ui__paleta() {
    if [ "$UI_COLOR" -eq 1 ]; then
        R=$'\033[0m'
        CC=$'\033[38;5;44m'      # cian    — marcos y titulos
        CB=$'\033[38;5;39m'      # azul    — teclas de opcion
        CG=$'\033[38;5;78m'      # verde   — ok
        CY=$'\033[38;5;178m'     # amarillo— aviso
        CR=$'\033[38;5;167m'     # rojo    — error y salidas
        CW=$'\033[38;5;253m'     # blanco  — texto destacado
        CD=$'\033[38;5;244m'     # gris    — detalles
        CM=$'\033[38;5;140m'     # violeta — datos secundarios
        FR=$'\033[48;5;167m\033[38;5;16m'   # chip de produccion
        FY=$'\033[48;5;178m\033[38;5;16m'   # chip de pre-produccion
        FB=$'\033[48;5;39m\033[38;5;16m'    # chip de testing
        FD=$'\033[48;5;244m\033[38;5;16m'   # chip neutro
    else
        R=''; CC=''; CB=''; CG=''; CY=''; CR=''; CW=''; CD=''; CM=''
        FR=''; FY=''; FB=''; FD=''
    fi
}

#--------------------------------------------------------------------- Glifos
ui__glifos() {
    if [ "$UI_UNICODE" -eq 1 ]; then
        G_OK='✔'; G_INFO='→'; G_AVISO='!'; G_ERR='✘'; G_RIESGO='⚠'
        G_PUNTA='▸'; G_SEP='›'; G_BARRA='▌'; G_PUNTO='·'; G_CORTE='…'
        M_TL='╔'; M_TR='╗'; M_BL='╚'; M_BR='╝'; M_H='═'; M_V='║'
        M_ML='╠'; M_MR='╣'; M_FINA='─'
        G_LLENO='█'; G_VACIO='░'
    else
        G_OK='OK'; G_INFO='->'; G_AVISO='!'; G_ERR='XX'; G_RIESGO='!!'
        G_PUNTA='>'; G_SEP='>'; G_BARRA='|'; G_PUNTO='-'; G_CORTE='~'
        M_TL='+'; M_TR='+'; M_BL='+'; M_BR='+'; M_H='='; M_V='|'
        M_ML='+'; M_MR='+'; M_FINA='-'
        G_LLENO='#'; G_VACIO='.'
    fi
}

#---------------------------------------------------------------------- Ancho
# El marco se adapta al terminal entre 52 y 76 columnas de interior. Fijo en 60
# cuando no hay TTY, para que la salida redirigida a un archivo sea estable.
# Al pintar un menu puede crecer hasta UI_TOPE_ANCHO si el contenido lo pide.
UI_TOPE_ANCHO=96

# Ancho minimo de una columna de tabla: por debajo el dato deja de leerse.
UI_MIN_COL=10
UI_TABLA_TIT=()
UI_TABLA_ANCHO=()
UI_TABLA_REAL=()

ui__ancho() {
    local cols
    if [ -n "${ANCHO_MARCO:-}" ]; then
        UI_ANCHO="$ANCHO_MARCO"
        return 0
    fi
    cols=$(tput cols 2>/dev/null || printf '0')
    if [ ! -t 1 ] || [ "$cols" -lt 20 ] 2>/dev/null; then
        UI_ANCHO=60
        return 0
    fi
    UI_ANCHO=$(( cols - 8 ))
    (( UI_ANCHO < 52 )) && UI_ANCHO=52
    (( UI_ANCHO > 76 )) && UI_ANCHO=76
    return 0
}

# Columnas que el terminal deja usar para el marco.
ui__ancho_disponible() {
    local cols
    cols=$(tput cols 2>/dev/null || printf '0')
    # Se llama dentro de $(...), donde la salida es una tuberia: el terminal
    # se reconoce tambien por la salida de error.
    if { [ ! -t 1 ] && [ ! -t 2 ]; } || [ "$cols" -lt 20 ] 2>/dev/null; then
        printf '%s' "$UI_TOPE_ANCHO"
        return 0
    fi
    cols=$(( cols - 8 ))
    (( cols > UI_TOPE_ANCHO )) && cols=$UI_TOPE_ANCHO
    (( cols < 40 )) && cols=40
    printf '%s' "$cols"
}

# Corta a `tope` columnas visibles arrastrando los codigos ANSI que va
# encontrando, y cierra el color al final.
ui__cortar() {
    local s=$1 tope=$2 salida='' vis=0 i j n c
    n=${#s}
    for (( i = 0; i < n; i++ )); do
        c=${s:i:1}
        if [ "$c" = $'\033' ]; then
            j=$i
            while (( j < n )) && [ "${s:j:1}" != m ]; do j=$(( j + 1 )); done
            salida="$salida${s:i:j-i+1}"
            i=$j
            continue
        fi
        (( vis >= tope )) && break
        salida="$salida$c"
        vis=$(( vis + 1 ))
    done
    printf '%s%s' "$salida" "$R"
}

# Ancho visible de un texto que puede traer codigos ANSI.
ui__visible() {
    local s=$1
    s="${s//$'\033'\[*([0-9;])m/}"
    printf '%s' "${#s}"
}

# Repite un caracter n veces.
ui__repetir() {
    local car=$1 n=$2 s=''
    while (( n > 0 )); do s="$s$car"; n=$(( n - 1 )); done
    printf '%s' "$s"
}

#------------------------------------------------------------------- Bitacora
# Registro de cada corrida en UI_LOG: acciones, resultados y la salida
# completa de cada comando.
ui__abrir_log() {
    touch "$UI_LOG" 2>/dev/null && chmod 600 "$UI_LOG" 2>/dev/null || { UI_LOG=''; return 0; }
    printf '\n===== %s | %s | %s =====\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$UI_CLAVE" "${USER:-desconocido}" \
        >> "$UI_LOG" 2>/dev/null
    return 0
}

ui_log() {
    [ -n "${UI_LOG:-}" ] || return 0
    printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" >> "$UI_LOG" 2>/dev/null
    return 0
}

#--------------------------------------------------------------------- Inicio
# $1 = titulo del script (cabecera)   $2 = clave corta (nombre de la bitacora)
ui_init() {
    UI_TITULO="$1"
    UI_CLAVE="$2"
    UI_AMBIENTE=''
    UI_AMB_TONO='neutro'
    UI_CHIPS=()
    ui__detectar
    ui__paleta
    ui__glifos
    ui__ancho
    ui__abrir_log
    trap 'ui__al_salir' EXIT
    trap 'ui__interrupcion' INT
    return 0
}

ui__al_salir() {
    [ "$UI_COLOR" -eq 1 ] && printf '%s' "$R"
    return 0
}

ui__interrupcion() {
    printf '\n'
    ui_aviso "Interrumpido por el usuario."
    ui_log "INTERRUMPIDO"
    exit 130
}

ui_salir() {
    printf '\n    %sHasta luego.%s\n\n' "$CD" "$R"
    ui_log "FIN"
    exit "${1:-0}"
}

#---------------------------------------------------------------------- Marcos
ui_marco_top() { printf '    %s%s%s%s%s\n' "$CC" "$M_TL" "$(ui__repetir "$M_H" "$UI_ANCHO")" "$M_TR" "$R"; }
ui_marco_sep() { printf '    %s%s%s%s%s\n' "$CC" "$M_ML" "$(ui__repetir "$M_H" "$UI_ANCHO")" "$M_MR" "$R"; }
ui_marco_bot() { printf '    %s%s%s%s%s\n' "$CC" "$M_BL" "$(ui__repetir "$M_H" "$UI_ANCHO")" "$M_BR" "$R"; }

# Fila del marco. Recibe el texto ya coloreado; el relleno se calcula sobre el
# ancho visible para que el borde derecho quede siempre alineado.
ui_fila() {
    local txt=${1:-} vis pad
    vis=$(ui__visible "$txt")
    if (( vis > UI_ANCHO )); then
        txt=$(ui__cortar "$txt" "$UI_ANCHO")
        vis=$UI_ANCHO
    fi
    pad=$(( UI_ANCHO - vis ))
    printf '    %s%s%s%s%*s%s%s%s\n' \
        "$CC" "$M_V" "$R" "$txt" "$pad" "" "$CC" "$M_V" "$R"
}

# Titulo centrado dentro del marco.
ui_marco_titulo() {
    local t=$1 izq der
    izq=$(( (UI_ANCHO - ${#t}) / 2 ));      (( izq < 0 )) && izq=0
    der=$(( UI_ANCHO - izq - ${#t} ));      (( der < 0 )) && der=0
    printf '    %s%s%s%*s%s%s%s%*s%s%s%s\n' \
        "$CC" "$M_V" "$R" "$izq" "" "$CW" "$t" "$R" "$der" "" "$CC" "$M_V" "$R"
}

ui_caja() { ui_marco_top; ui_marco_titulo "$1"; ui_marco_bot; }

ui_regla() {
    printf '    %s%s%s\n' "$CD" "$(ui__repetir "$M_FINA" "$(( UI_ANCHO + 2 ))")" "$R"
}

# Debajo del titulo va la linea de procedencia: script, ambiente, alcance y
# momento de la medicion. Un resultado copiado a un documento llega
# con eso, que fuera de la pantalla no se deduce.
ui_titulo() {
    local ctx c linea='' palabra
    printf '\n    %s%s%s\n' "$CC" "$1" "$R"
    ctx="$UI_TITULO"
    [ -n "${UI_AMBIENTE:-}" ] && ctx="$ctx|$UI_AMBIENTE"
    for c in ${UI_CHIPS[@]+"${UI_CHIPS[@]}"}; do ctx="$ctx|$c"; done
    ctx="$ctx|$(date '+%Y-%m-%d %H:%M')"
    # El corte cae entre dos datos, nunca dentro de uno.
    while IFS= read -r -d '|' palabra || [ -n "$palabra" ]; do
        palabra=${palabra%$'\n'}
        [ -n "$palabra" ] || continue
        if [ ${#linea} -gt 0 ] && [ $(( ${#linea} + ${#palabra} + 3 )) -gt "$UI_ANCHO" ]; then
            printf '    %s%s %s%s\n' "$CD" "$linea" "$G_PUNTO" "$R"
            linea="$palabra"
        else
            linea="${linea:+$linea $G_PUNTO }$palabra"
        fi
    done <<< "$ctx"
    [ -n "$linea" ] && printf '    %s%s%s\n' "$CD" "$linea" "$R"
    ui_regla
    ui_log "== $1"
}

#----------------------------------------------------------- Chips de contexto
# El ambiente se pinta con fondo para que no pase inadvertido: el color del
# chip es la unica senal que distingue una maniobra en produccion de una en
# testing cuando el resto de la pantalla es igual.
#
# $1 = etiqueta   $2 = tono (prod | preprod | testing | neutro)
ui_ambiente() {
    UI_AMBIENTE="$1"
    UI_AMB_TONO="${2:-neutro}"
}

ui_chip_reset() { UI_CHIPS=(); }

# $1 = nombre   $2 = valor
ui_chip() { UI_CHIPS+=("$1 $2"); }

ui__chip_fondo() {
    case "$1" in
        prod)    printf '%s' "$FR" ;;
        preprod) printf '%s' "$FY" ;;
        testing) printf '%s' "$FB" ;;
        *)       printf '%s' "$FD" ;;
    esac
}

ui__linea_chips() {
    local salida='' c fondo
    if [ -n "$UI_AMBIENTE" ]; then
        fondo=$(ui__chip_fondo "$UI_AMB_TONO")
        salida="${fondo} ${UI_AMBIENTE} ${R}"
    fi
    for c in ${UI_CHIPS[@]+"${UI_CHIPS[@]}"}; do
        [ -n "$salida" ] && salida="$salida  ${CD}${G_PUNTO}${R}  "
        salida="$salida${CD}${c%% *}${R} ${CW}${c#* }${R}"
    done
    [ -n "$salida" ] && printf '    %s\n' "$salida"
    return 0
}

# Cabecera de pantalla: limpia, dibuja el banner, la ubicacion y los chips.
# Los argumentos son los pasos de la ubicacion (breadcrumb).
ui_pantalla() {
    clear 2>/dev/null
    printf '\n'
    ui_caja "$UI_TITULO"
    printf '\n'
    local linea="    ${CD}Ubicacion ${G_PUNTA}${R}"
    local p
    for p in "$@"; do
        [ -n "$p" ] || continue
        linea="$linea  ${CW}${p}${R}  ${CD}${G_SEP}${R}"
    done
    linea="${linea%  ${CD}${G_SEP}${R}}"
    printf '%s\n' "$linea"
    ui__linea_chips
    printf '\n'
}

#-------------------------------------------------------------- Salida basica
ui_ok()      { printf '    %s%s%s  %b\n' "$CG" "$G_OK"    "$R" "$*"; ui_log "OK    $*"; }
ui_info()    { printf '    %s%s%s  %b\n' "$CB" "$G_INFO"  "$R" "$*"; ui_log "INFO  $*"; }
ui_aviso()   { printf '    %s%s%s  %b\n' "$CY" "$G_AVISO" "$R" "$*"; ui_log "AVISO $*"; }
ui_error()   { printf '    %s%s%s  %b\n' "$CR" "$G_ERR"   "$R" "$*"; ui_log "ERROR $*"; }
ui_detalle() { printf '       %s%b%s\n' "$CD" "$*" "$R"; }
ui_dato()    { printf '    %s%-18s%s %s%b%s\n' "$CD" "$1" "$R" "$CW" "$2" "$R"; }

# Encabezado de un bloque de trabajo.
ui_bloque() {
    printf '\n    %s%s%s %s%s%s' "$CC" "$M_FINA$M_FINA" "$R" "$CW" "$1" "$R"
    [ -n "${2:-}" ] && printf ' %s(%s)%s' "$CD" "$2" "$R"
    printf ' %s%s%s\n' "$CC" "$(ui__repetir "$M_FINA" 6)" "$R"
    ui_log "---- $1 ${2:-}"
}

# Paso n de m dentro de una maniobra.
ui_paso() {
    printf '    %s[%s/%s]%s %b\n' "$CM" "$1" "$2" "$R" "$3"
    ui_log "PASO  [$1/$2] $3"
}

#------------------------------------------------------------------- Progreso
# Barra de progreso en una sola linea, reescrita en el lugar.
ui_progreso() {
    local hechos=$1 total=$2 etiqueta=${3:-} ancho=24 llenos vacios pct texto disponible
    disponible=$(ui__ancho_disponible)
    # En un terminal angosto la barra se acorta y deja lugar a la etiqueta.
    (( disponible < 80 )) && ancho=16
    (( total <= 0 )) && total=1
    pct=$(( hechos * 100 / total ))
    llenos=$(( hechos * ancho / total ))
    (( llenos > ancho )) && llenos=$ancho
    vacios=$(( ancho - llenos ))
    # La etiqueta ocupa lo que deja la terminal: la linea se reescribe en el
    # lugar y una que pasa del ancho deja de reescribirse.
    texto=$(( disponible - ancho - 13 ))
    (( texto < 28 )) && texto=28
    printf '\r    %s%s%s%s%s%s %3s%%  %s%-*.*s%s' \
        "$CG" "$(ui__repetir "$G_LLENO" "$llenos")" "$R" \
        "$CD" "$(ui__repetir "$G_VACIO" "$vacios")" "$R" \
        "$pct" "$CD" "$texto" "$texto" "$etiqueta" "$R"
    (( hechos >= total )) && printf '\n'
    return 0
}

# Mata un proceso y todo lo que colgo de el: el comando corre dentro de una
# subshell y matar solo al padre deja vivos a sus hijos.
ui__matar_arbol() {
    local pid=$1 hijo
    for hijo in $(pgrep -P "$pid" 2>/dev/null); do
        ui__matar_arbol "$hijo"
    done
    kill -TERM "$pid" 2>/dev/null
}

# 1 si el operador corto la ultima espera. Lo consultan quienes encadenan
# pasos, para no seguir con el siguiente.
UI_CANCELADO=0
# Bytes de la ultima descarga completa (ui_traer_archivo).
UI_TRAIDO_BYTES=0

# Espera `pausa` segundos escuchando el teclado. Pone UI_CANCELADO en 1 si el
# operador pidio cortar. Sin terminal solo espera.
ui__escuchar_corte() {
    local pausa=$1 tecla
    if [ "${UI_CORTABLE:-0}" -eq 1 ]; then
        if read -rsn1 -t "$pausa" tecla < /dev/tty 2>/dev/null; then
            case "$tecla" in c|C|$'\e'|q|Q) UI_CANCELADO=1 ;; esac
        fi
    else
        sleep "$pausa" 2>/dev/null || sleep 1
    fi
    return 0
}

# Corta la espera: mata el arbol del proceso y deja constancia.
ui__cortar_espera() {
    ui__matar_arbol "$1"
    sleep 0.4 2>/dev/null
    kill -KILL "$1" 2>/dev/null
}

# Reloj de actividad mientras corre un PID: muestra que sigue vivo y cuanto
# lleva. $1 pid  $2 mensaje  [$3 =1 no cierra la linea: la cierra quien llama,
# que es el unico que sabe si el comando salio bien]. Deja UI_SEGUNDOS.
UI_SEGUNDOS=0

ui_reloj() {
    local pid=$1 msg=$2 callado=${3:-0}
    local marcos='|/-\' i=0 c inicio=$SECONDS pasado tecla
    local pista='' cortable=0 extra='' ancho_msg=38
    [ "$UI_UNICODE" -eq 1 ] && marcos='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local n=${#marcos}
    UI_CANCELADO=0
    # La espera se corta desde el teclado solo si hay terminal: en una corrida
    # sin tty (cron, tuberia) no hay a quien preguntarle.
    if [ -r /dev/tty ] && [ -t 1 ]; then
        cortable=1
        UI_CORTABLE=1
        pista="  ${CD}[c] o Ctrl-C cortar${R}"
    else
        UI_CORTABLE=0
    fi
    # Durante la espera Ctrl-C corta solo la espera: el trap general queda
    # suspendido para que el script siga en el menu.
    trap 'UI_CANCELADO=1' INT
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % n ))
        c=${marcos:i:1}
        pasado=$(( SECONDS - inicio ))
        printf '\r    %s%s%s  %-*.*s %s%02d:%02d%s%s%b ' \
            "$CB" "$c" "$R" "$ancho_msg" "$ancho_msg" "$msg" \
            "$CD" "$(( pasado / 60 ))" "$(( pasado % 60 ))" "$extra" "$R" "$pista"
        ui__escuchar_corte 0.2
        if [ "$UI_CANCELADO" -eq 1 ]; then
            ui__cortar_espera "$pid"
            break
        fi
    done
    trap 'ui__interrupcion' INT
    pasado=$(( SECONDS - inicio ))
    UI_SEGUNDOS=$pasado
    printf '\r%*s\r' "$(( $(ui__ancho_disponible) + 8 ))" ''
    if [ "$callado" -eq 1 ]; then
        [ "$UI_CANCELADO" -eq 1 ] && return 130
        return 0
    fi
    if [ "$UI_CANCELADO" -eq 1 ]; then
        printf '    %s%s%s  %-52.52s %s%02d:%02d%s  %scortado%s\n' \
            "$CY" "$G_AVISO" "$R" "$msg" \
            "$CD" "$(( pasado / 60 ))" "$(( pasado % 60 ))" "$R" "$CY" "$R"
        ui_log "CORTADO $msg (${pasado}s)"
        return 130
    fi
    printf '    %s%s%s  %-52.52s %s%02d:%02d%s\n' \
        "$CG" "$G_OK" "$R" "$msg" \
        "$CD" "$(( pasado / 60 ))" "$(( pasado % 60 ))" "$R"
    return 0
}

# El mismo reloj, con otro nombre.
ui_spinner() { ui_reloj "$1" "$2"; }

# Corre un comando mostrando el reloj y deja su salida en UI_SALIDA.
# Devuelve el codigo del comando, o 130 si el operador corto la espera.
# Uso: ui_tarea "Etiqueta" comando argumentos...  (o el nombre de una funcion)
ui_tarea() {
    local etiqueta=$1; shift
    local temporal codigo pid
    temporal=$(mktemp) || { "$@"; return $?; }
    ( "$@" > "$temporal" 2>&1 ) &
    pid=$!
    # El reloj no cierra la linea: la marca sale del codigo del comando, y
    # una tarea que fallo no se muestra con la tilde de las que salieron bien.
    ui_reloj "$pid" "$etiqueta" 1
    wait "$pid" 2>/dev/null; codigo=$?
    UI_SALIDA=$(cat "$temporal")
    rm -f "$temporal"
    if [ "$UI_CANCELADO" -eq 1 ]; then
        printf '    %s%s%s  %-52.52s %s%02d:%02d%s  %scortado%s\n' \
            "$CY" "$G_AVISO" "$R" "$etiqueta" \
            "$CD" "$(( UI_SEGUNDOS / 60 ))" "$(( UI_SEGUNDOS % 60 ))" "$R" "$CY" "$R"
        ui_log "TAREA (cortada) $etiqueta"
        return 130
    fi
    if [ "$codigo" -eq 0 ]; then
        printf '    %s%s%s  %-52.52s %s%02d:%02d%s\n' "$CG" "$G_OK" "$R" \
            "$etiqueta" "$CD" "$(( UI_SEGUNDOS / 60 ))" "$(( UI_SEGUNDOS % 60 ))" "$R"
    else
        printf '    %s%s%s  %-52.52s %s%02d:%02d%s\n' "$CR" "$G_ERR" "$R" \
            "$etiqueta" "$CD" "$(( UI_SEGUNDOS / 60 ))" "$(( UI_SEGUNDOS % 60 ))" "$R"
    fi
    ui_log "TAREA ($codigo) $etiqueta"
    return "$codigo"
}

UI_SALIDA=''

# Espera una cantidad de segundos mostrando la barra. Para los arranques.
ui_esperar() {
    local segundos=$1 etiqueta=${2:-esperando} pasado=0
    while [ "$pasado" -lt "$segundos" ]; do
        ui_progreso "$pasado" "$segundos" "$etiqueta"
        sleep 1
        pasado=$(( pasado + 1 ))
    done
    ui_progreso "$segundos" "$segundos" "$etiqueta"
}

#----------------------------------------------------------------------- Menu
# Menu declarativo: se cargan las opciones y se pinta. Todos los scripts
# navegan igual porque todos usan estas cuatro funciones.
#
#   ui_menu_nuevo "TITULO"
#   ui_menu_op  tecla  etiqueta  [pista]  [tono]
#   ui_menu_hueco / ui_menu_grupo "texto"
#   ui_menu_leer  ->  deja la tecla elegida en UI_OPCION (normalizada a
#                     mayuscula) y devuelve 1 si la tecla no existe.
#
# Tonos: normal (se infiere), salir, aviso, riesgo.
ui_menu_nuevo() {
    UI_MENU_TITULO="$1"
    UI_MENU_FILAS=()
    UI_MENU_TECLAS=()
}

ui__tono_tecla() {
    case "$1" in
        X|V|0) printf 'salir' ;;
        [0-9]) printf 'normal' ;;
        *)     printf 'aviso' ;;
    esac
}

ui_menu_op() {
    local tecla=$1 etiqueta=$2 pista=${3:-} tono=${4:-}
    local mayus color marca=''
    mayus=$(printf '%s' "$tecla" | tr '[:lower:]' '[:upper:]')
    [ -n "$tono" ] || tono=$(ui__tono_tecla "$mayus")
    case "$tono" in
        salir)  color="$CR" ;;
        aviso)  color="$CY" ;;
        riesgo) color="$CR"; marca=" ${CR}${G_RIESGO}${R}" ;;
        *)      color="$CB" ;;
    esac
    local fila="   ${color}${mayus})${R}  ${CW}${etiqueta}${R}${marca}"
    [ -n "$pista" ] && fila="$fila  ${CD}(${pista})${R}"
    UI_MENU_FILAS+=("$fila")
    UI_MENU_TECLAS+=("$mayus")
}

ui_menu_hueco() { UI_MENU_FILAS+=(""); }

# Linea tenue debajo de una opcion. En los diagnosticos lleva el sintoma: en
# que caso sirve esa revision.
ui_menu_nota() { UI_MENU_FILAS+=("       ${CD}${1}${R}"); }

ui_menu_grupo() {
    UI_MENU_FILAS+=("")
    UI_MENU_FILAS+=("   ${CD}${1}${R}")
}

# Comando resumido de la opcion, debajo de la etiqueta. No es el comando
# entero: alcanza con que el operador vea si la opcion lee (cat, grep, ls) o
# si actua sobre el proceso (jstack, kill -3).
ui_menu_cmd() { UI_MENU_FILAS+=("       ${CM}\$ ${1}${R}"); }

# Encabezado de un bloque de opciones que cambian el servidor. Va en rojo.
# $1 = titulo   $2 = aclaracion (opcional)
ui_menu_grupo_riesgo() {
    UI_MENU_FILAS+=("")
    UI_MENU_FILAS+=("   ${CR}${G_RIESGO} ${1}${R}")
    [ -n "${2:-}" ] && UI_MENU_FILAS+=("   ${CD}${2}${R}")
}

# El marco se agranda hasta donde el terminal permita si alguna fila no entra;
# recien si tampoco asi entra, la fila se recorta. El ancho vuelve a su valor
# al terminar, asi un menu ancho no arrastra al resto de las pantallas.
ui_menu_pintar() {
    local f vis maximo=0 previo=$UI_ANCHO disponible
    for f in ${UI_MENU_FILAS[@]+"${UI_MENU_FILAS[@]}"}; do
        vis=$(ui__visible "$f")
        (( vis > maximo )) && maximo=$vis
    done
    vis=$(( ${#UI_MENU_TITULO} + 4 ))
    (( vis > maximo )) && maximo=$vis
    if (( maximo > UI_ANCHO )); then
        disponible=$(ui__ancho_disponible)
        UI_ANCHO=$(( maximo > disponible ? disponible : maximo ))
    fi

    ui_marco_top
    ui_marco_titulo "$UI_MENU_TITULO"
    ui_marco_sep
    ui_fila ""
    for f in ${UI_MENU_FILAS[@]+"${UI_MENU_FILAS[@]}"}; do
        ui_fila "$f"
    done
    ui_fila ""
    ui_marco_bot
    UI_ANCHO=$previo
}

# Lee y valida contra las teclas cargadas. Devuelve 1 si no es valida.
ui_menu_leer() {
    local sel t
    printf '    %sSeleccion: %s' "$CW" "$R"
    read -r sel || { printf '\n'; ui_salir 0; }
    UI_OPCION=$(printf '%s' "$sel" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    for t in ${UI_MENU_TECLAS[@]+"${UI_MENU_TECLAS[@]}"}; do
        [ "$t" = "$UI_OPCION" ] && return 0
    done
    ui_error "Opcion invalida."
    ui_pausa
    return 1
}

#--------------------------------------------------------------------- Tablas
# Columnas declaradas como "TITULO:ancho"; ancho 0 = lo que sobre.
ui_tabla_def() {
    UI_TABLA_TIT=()
    UI_TABLA_ANCHO=()
    local c
    for c in "$@"; do
        UI_TABLA_TIT+=("${c%%:*}")
        UI_TABLA_ANCHO+=("${c##*:}")
    done
    ui__repartir_anchos
}

# El ancho declarado es el pedido; el efectivo sale del ancho de la terminal.
# Lo que no entra se descuenta de la columna mas ancha, de a una columna, hasta
# que la fila cabe en la pantalla.
ui__repartir_anchos() {
    UI_TABLA_REAL=()
    local n=${#UI_TABLA_TIT[@]} j elastica=-1 fijas=0 disponible mayor falta
    for j in "${!UI_TABLA_ANCHO[@]}"; do
        UI_TABLA_REAL[$j]=${UI_TABLA_ANCHO[$j]}
        if [ "${UI_TABLA_ANCHO[$j]}" -eq 0 ] 2>/dev/null; then
            elastica=$j
        else
            fijas=$(( fijas + UI_TABLA_ANCHO[j] ))
        fi
    done
    disponible=$(( UI_ANCHO + 2 - 3 * (n - 1) ))
    if [ "$elastica" -ge 0 ]; then
        falta=$(( UI_MIN_COL - (disponible - fijas) ))
    else
        falta=$(( fijas - disponible ))
    fi
    while [ "$falta" -gt 0 ]; do
        mayor=-1
        for j in "${!UI_TABLA_REAL[@]}"; do
            [ "$j" -eq "$elastica" ] && continue
            [ "${UI_TABLA_REAL[$j]}" -le "$UI_MIN_COL" ] && continue
            if [ "$mayor" -lt 0 ] || [ "${UI_TABLA_REAL[$j]}" -gt "${UI_TABLA_REAL[$mayor]}" ]; then
                mayor=$j
            fi
        done
        [ "$mayor" -lt 0 ] && break
        UI_TABLA_REAL[$mayor]=$(( UI_TABLA_REAL[mayor] - 1 ))
        falta=$(( falta - 1 ))
    done
    [ "$elastica" -ge 0 ] || return 0
    fijas=0
    for j in "${!UI_TABLA_REAL[@]}"; do
        [ "$j" -eq "$elastica" ] || fijas=$(( fijas + UI_TABLA_REAL[j] ))
    done
    UI_TABLA_REAL[$elastica]=$(( disponible - fijas ))
    [ "${UI_TABLA_REAL[$elastica]}" -lt "$UI_MIN_COL" ] && UI_TABLA_REAL[$elastica]=$UI_MIN_COL
    return 0
}

ui__ancho_col() {
    printf '%s' "${UI_TABLA_REAL[$1]}"
}

ui_tabla_encabezado() {
    local i linea='' sub='' a
    for i in "${!UI_TABLA_TIT[@]}"; do
        a=$(ui__ancho_col "$i")
        [ -n "$linea" ] && { linea="$linea   "; sub="$sub${CD}${M_FINA}${M_FINA}${M_FINA}${R}"; }
        linea="$linea${CD}$(printf '%-*.*s' "$a" "$a" "${UI_TABLA_TIT[$i]}")${R}"
        sub="$sub${CD}$(ui__repetir "$M_FINA" "$a")${R}"
    done
    printf '\n    %s\n    %s\n' "$linea" "$sub"
}

ui_tabla_fila() {
    local i linea='' a celda vis pad
    for i in "${!UI_TABLA_TIT[@]}"; do
        a=$(ui__ancho_col "$i")
        celda=${@:i+1:1}
        vis=$(ui__visible "$celda")
        if (( vis > a )); then
            # El corte cuenta caracteres visibles: la celda puede traer color.
            celda="$(ui__cortar "$celda" "$(( a - 1 ))")$G_CORTE"
            vis=$a
        fi
        pad=$(( a - vis ))
        [ -n "$linea" ] && linea="$linea   "
        linea="$linea${celda}$(printf '%*s' "$pad" '')"
    done
    printf '    %s\n' "$linea"
}


#----------------------------------------------------------- Entrada y control
ui_pausa() {
    printf '\n    %sEnter para continuar...%s' "$CD" "$R"
    read -r _ || printf '\n'
    return 0
}

# Confirmacion S / N / V.  0 = Si   1 = No   2 = Volver
ui_si_no() {
    local r
    while true; do
        printf '    %s%s%s  %s[S / N / V para volver]%s: ' "$CB" "$1" "$R" "$CD" "$R"
        read -r r || return 2
        case "$r" in
            s|S) ui_log "CONFIRMA SI  $1"; return 0 ;;
            n|N) ui_log "CONFIRMA NO  $1"; return 1 ;;
            v|V) return 2 ;;
            *) ui_aviso "Responder S, N o V." ;;
        esac
    done
}

# Confirmacion de una accion que no se deshace: hay que escribir la palabra.
# $1 = palabra   $2..= lineas de advertencia
ui_confirmar_riesgo() {
    local palabra=$1; shift
    local l r
    printf '\n'
    ui_marco_top
    ui_marco_titulo "ATENCION"
    ui_marco_sep
    ui_fila ""
    # Cada linea se parte por palabras al ancho del marco: ui_fila corta.
    local parte
    for l in "$@"; do
        while IFS= read -r parte; do
            ui_fila "   ${CY}${parte}${R}"
        done < <(printf '%s\n' "$l" | fold -s -w $(( UI_ANCHO - 4 )))
    done
    ui_fila ""
    ui_marco_bot
    printf '\n    %sEscriba %s%s%s para confirmar (vacio = cancelar): %s' \
        "$CW" "$CR" "$palabra" "$CW" "$R"
    read -r r || return 1
    if [ "$r" = "$palabra" ]; then
        ui_log "RIESGO CONFIRMADO $palabra"
        return 0
    fi
    ui_info "Cancelado."
    ui_log "RIESGO CANCELADO $palabra"
    return 1
}

# Lectura con valor por defecto. V vuelve (devuelve 1). Deja el valor en UI_VALOR.
ui_leer() {
    local etiqueta=$1 defecto=${2:-} r
    if [ -n "$defecto" ]; then
        printf '    %s%s%s %s[%s]%s %s(v = volver)%s: ' \
            "$CB" "$etiqueta" "$R" "$CW" "$defecto" "$R" "$CD" "$R"
    else
        printf '    %s%s%s %s(v = volver)%s: ' "$CB" "$etiqueta" "$R" "$CD" "$R"
    fi
    read -r r || return 1
    case "$r" in v|V) return 1 ;; esac
    UI_VALOR="${r:-$defecto}"
    [ -n "$UI_VALOR" ] || return 1
    return 0
}



#------------------------------------------------------------------- Resumen
# Cuadro de confirmacion previo a una maniobra. Los pares nombre/valor se
# pasan seguidos: ui_resumen "Sitio" "/var/www/cupcore" "Base" "CupCore"
ui_resumen() {
    ui_titulo "RESUMEN"
    while [ $# -ge 2 ]; do
        ui_dato "$1" "$2"
        shift 2
    done
    printf '\n'
}


#==============================================================================
# CupCore instalado
#==============================================================================
DESTINO=/var/www/cupcore
CARPETA_LOG=/var/log/cupcore
CREDENCIALES=/root/cupcore-credenciales.txt
CLAVE_CERTIFICADO=/etc/pki/tls/private/cupcore.key
UI_LOG=/var/log/cupcore-pruebas.log

# Version corregida de PHP2Shell (CVE-2026-109618 y CVE-2026-109619) en cada rama
# con soporte; una rama fuera de la lista no se acepta.
php_al_dia() {
    php -r '$m = ["8.2" => "8.2.35", "8.3" => "8.3.36", "8.4" => "8.4.27", "8.5" => "8.5.12"];
        $r = PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;
        exit(isset($m[$r]) && version_compare(PHP_VERSION, $m[$r], ">=") ? 0 : 1);' > /dev/null 2>&1
}

version_php() { php -r 'echo PHP_VERSION;' 2>/dev/null || printf 'no instalado'; }

#------------------------------------------------------------- Acciones
# hacer "Texto" comando...: reloj mientras corre, marca al terminar y salida
# completa en UI_LOG. Si falla, muestra las ultimas lineas de la salida.
hacer() {
    local texto=$1 codigo; shift
    printf '\n### %s  %s\n$ %s\n' "$(date '+%H:%M:%S')" "$texto" "$*" >> "${UI_LOG:-/dev/null}" 2>/dev/null
    if [ -t 1 ]; then
        ui_tarea "$texto" "$@"; codigo=$?
    else
        UI_SALIDA=$("$@" 2>&1); codigo=$?
        if [ "$codigo" -eq 0 ]; then ui_ok "$texto"; else ui_error "$texto"; fi
    fi
    printf '%s\n' "$UI_SALIDA" >> "${UI_LOG:-/dev/null}" 2>/dev/null
    if [ "$codigo" -ne 0 ] && [ "$codigo" -ne 130 ]; then
        {
            printf '%s\n' "$UI_SALIDA" | grep -iE '^(error|problem)|invalid command|cannot|no such file|not found|conflict' | head -n 4
            printf '%s\n' "$UI_SALIDA" | grep -v '^\s*$' | tail -n 4
        } | awk '!visto[$0]++' | cut -c1-150 | while IFS= read -r l; do ui_detalle "$l"; done
    fi
    return "$codigo"
}

contexto() {
    ui_chip_reset
    ui_chip "equipo" "$(hostname -s)"
    ui_chip "PHP" "$(version_php)"
}

#---------------------------------------------------------------- Pruebas
# Cada resultado va a la pantalla y, si hay informe abierto, a un archivo de
# texto en /root que sirve de evidencia.
URL_SITIO=https://127.0.0.1
PRUEBAS_OK=0
PRUEBAS_ERROR=0
PRUEBAS_AVISO=0
INFORME=''

probar() {  # probar "Descripcion" condicion(0 = correcta)
    if [ "$2" -eq 0 ]; then
        PRUEBAS_OK=$(( PRUEBAS_OK + 1 )); ui_ok "$1"
        [ -n "$INFORME" ] && printf '[OK]     %s\n' "$1" >> "$INFORME"
    else
        PRUEBAS_ERROR=$(( PRUEBAS_ERROR + 1 )); ui_error "$1"
        [ -n "$INFORME" ] && printf '[ERROR]  %s\n' "$1" >> "$INFORME"
    fi
    return 0
}

# Algo para revisar que no es una falla de CupCore
advertir() {
    PRUEBAS_AVISO=$(( PRUEBAS_AVISO + 1 )); ui_aviso "$1"
    [ -n "$INFORME" ] && printf '[AVISO]  %s\n' "$1" >> "$INFORME"
    return 0
}

grupo() {
    ui_bloque "$1"
    [ -n "$INFORME" ] && printf '\n%s\n' "$1" >> "$INFORME"
    return 0
}

abrir_informe() {
    PRUEBAS_OK=0; PRUEBAS_ERROR=0; PRUEBAS_AVISO=0
    INFORME="/root/cupcore-pruebas-$(date +%Y%m%d-%H%M%S).txt"
    ( umask 077
      printf 'PRUEBAS DE CUPCORE - %s\nServidor: %s  ·  PHP %s  ·  %s\n' \
          "$1" "$(hostname -f 2>/dev/null || hostname)" "$(version_php)" "$(date '+%Y-%m-%d %H:%M')" > "$INFORME" )
}

cerrar_informe() {
    printf '\n'
    ui_dato "RESULTADO" "$PRUEBAS_OK correctas, $PRUEBAS_ERROR con error, $PRUEBAS_AVISO avisos"
    ui_dato "Informe" "$INFORME"
    printf '\nRESULTADO: %s correctas, %s con error, %s avisos\n' \
        "$PRUEBAS_OK" "$PRUEBAS_ERROR" "$PRUEBAS_AVISO" >> "$INFORME"
    ui_log "PRUEBAS $PRUEBAS_OK correctas, $PRUEBAS_ERROR con error, $PRUEBAS_AVISO avisos ($INFORME)"
    INFORME=''
}

# Pedidos al sitio con una sesion propia por archivo de cookies
codigo_http() { curl -sk -o /dev/null -w '%{http_code}' "$@"; }
pagina()      { curl -sk -c "$1" -b "$1" "$URL_SITIO/index.php?ruta=$2"; }
token_csrf()  { pagina "$1" login | grep -o 'name="tokenCsrf" value="[^"]*"' | head -1 | cut -d'"' -f4; }
cookie_sesion() { awk '$6 == "CUPCORESESSID" {print $7}' "$1" 2>/dev/null; }

# ingresar COOKIES CORREO CLAVE [TOKEN]: imprime la redireccion; sin redireccion, nada
ingresar() {
    local token=${4-$(token_csrf "$1")}
    curl -sk -c "$1" -b "$1" -o /dev/null -w '%{redirect_url}' \
        --data-urlencode "tokenCsrf=$token" --data-urlencode "correo=$2" \
        --data-urlencode "contrasena=$3" "$URL_SITIO/index.php?ruta=login"
}

# Mensaje de error de la pantalla de ingreso, sin el token
mensaje_ingreso() {
    local token
    token=$(token_csrf "$1")
    curl -sk -c "$1" -b "$1" --data-urlencode "tokenCsrf=$token" \
        --data-urlencode "correo=$2" --data-urlencode "contrasena=$3" \
        "$URL_SITIO/index.php?ruta=login" | grep -A1 'aviso-error' | tail -1 | sed 's/^ *//'
}

prueba_sitio() {
    local cab cookies destino
    cookies=$(mktemp)
    grupo "HTTPS"
    [ "$(codigo_http http://127.0.0.1/)" = 301 ]; probar "El puerto 80 redirige a HTTPS" $?
    [ "$(codigo_http "$URL_SITIO/index.php?ruta=login")" = 200 ]; probar "La pantalla de ingreso responde por HTTPS" $?
    cab=$(curl -skI "$URL_SITIO/index.php?ruta=login")
    grep -qi '^strict-transport-security' <<< "$cab"; probar "Cabecera Strict-Transport-Security" $?
    grep -qi '^content-security-policy' <<< "$cab";   probar "Cabecera Content-Security-Policy" $?
    grep -qi '^x-content-type-options: nosniff' <<< "$cab"; probar "Cabecera X-Content-Type-Options" $?
    ! grep -qiE '^server:.*[0-9]|^x-powered-by' <<< "$cab"; probar "Apache y PHP no informan su version" $?
    grep -qiE '^set-cookie:.*secure.*httponly|^set-cookie:.*httponly.*secure' <<< "$cab"; probar "Cookie de sesion con Secure y HttpOnly" $?
    grupo "Archivos protegidos"
    [ "$(codigo_http "$URL_SITIO/config/database.php")" = 403 ]; probar "La carpeta config no se sirve" $?
    [ "$(codigo_http "$URL_SITIO/.htaccess")" = 403 ];          probar "El archivo .htaccess no se descarga" $?
    [ "$(codigo_http "$URL_SITIO/css/")" = 403 ];               probar "Las carpetas no listan su contenido" $?
    grupo "Aplicacion y base"
    grep -qi 'torneo' < <(pagina "$cookies" torneos); probar "El listado de torneos responde" $?
    destino=$(ingresar "$cookies" admin@cupcore.com 'CupCore2026$')
    grep -q 'admin\|clave' <<< "$destino"; probar "Ingreso del administrador de prueba" $?
    ! ss -tln | grep ':3306 ' | grep -vq '127.0.0.1:3306'; probar "MariaDB escucha solo en 127.0.0.1" $?
    ! mysql -N -e "show grants for 'cupcoreapp'@'localhost'" 2>/dev/null | grep -q 'ALL PRIVILEGES'
    probar "La cuenta del sitio no tiene todos los permisos" $?
    grupo "Servidor"
    local version
    version=$(version_php)
    php_al_dia; probar "PHP $version con la correccion de PHP2Shell" $?
    fail2ban-client status cupcore-login > /dev/null 2>&1; probar "Carcel cupcore-login de fail2ban activa" $?
    systemctl is-active -q firewalld 2>/dev/null; probar "Firewall activo" $?
    systemctl is-active -q suricata 2>/dev/null; probar "Suricata activo" $?
    rm -f "$cookies"
}

prueba_ataques() {
    local c1 c2 c3 antes despues destino m1 m2 pag
    c1=$(mktemp); c2=$(mktemp); c3=$(mktemp)
    grupo "Inyeccion SQL (A03)"
    destino=$(ingresar "$c1" "admin@cupcore.com' or '1'='1" 'cualquiera')
    ! grep -q 'ruta=admin' <<< "$destino"; probar "El ingreso con ' or '1'='1 en el correo no entra" $?
    destino=$(ingresar "$c1" 'admin@cupcore.com' "' or '1'='1")
    ! grep -q 'ruta=admin' <<< "$destino"; probar "El ingreso con ' or '1'='1 en la contrasena no entra" $?
    pag=$(curl -sk "$URL_SITIO/index.php?ruta=torneos&busqueda=%27%20union%20select%201,2,3%20--%20")
    ! grep -qiE 'SQLSTATE|syntax error|mysql|mariadb' <<< "$pag" && grep -qi 'torneo' <<< "$pag"
    probar "Una busqueda con union select no muestra errores de la base" $?
    grupo "XSS (A03)"
    pag=$(curl -sk "$URL_SITIO/index.php?ruta=torneos&busqueda=%3Cscript%3Ealert(1)%3C/script%3E")
    ! grep -q '<script>alert(1)</script>' <<< "$pag"; probar "Un <script> en la busqueda vuelve escapado" $?
    grupo "CSRF (A01)"
    destino=$(ingresar "$c2" admin@cupcore.com 'CupCore2026$' '')
    ! grep -q 'ruta=admin' <<< "$destino"; probar "Un ingreso sin token CSRF se rechaza" $?
    destino=$(ingresar "$c2" admin@cupcore.com 'CupCore2026$' 'token-inventado')
    ! grep -q 'ruta=admin' <<< "$destino"; probar "Un ingreso con un token CSRF falso se rechaza" $?
    grupo "Sesiones y cuentas (A07)"
    pagina "$c3" login > /dev/null
    antes=$(cookie_sesion "$c3")
    ingresar "$c3" admin@cupcore.com 'CupCore2026$' > /dev/null
    despues=$(cookie_sesion "$c3")
    [ -n "$antes" ] && [ -n "$despues" ] && [ "$antes" != "$despues" ]
    probar "La sesion cambia de identificador al ingresar (fijacion de sesion)" $?
    grep -qi 'samesite=strict' < <(curl -skI "$URL_SITIO/index.php?ruta=login"); probar "Cookie de sesion con SameSite=Strict" $?
    m1=$(mensaje_ingreso "$c1" 'noexiste.prueba@cupcore.com' 'Clave2026$x')
    m2=$(mensaje_ingreso "$c1" 'rfranco@cupcore.com' 'Clave2026$x')
    [ -n "$m1" ] && [ "$m1" = "$m2" ]; probar "El mismo mensaje para un correo inexistente y una clave equivocada" $?
    grupo "Control de acceso (A01)"
    : > "$c1"
    destino=$(curl -sk -c "$c1" -b "$c1" -o /dev/null -w '%{redirect_url}' "$URL_SITIO/index.php?ruta=admin")
    grep -q 'ruta=login' <<< "$destino"; probar "Sin sesion, el panel de administracion lleva al ingreso" $?
    : > "$c1"
    destino=$(ingresar "$c1" sofia@cupcore.com 'CupCore2026$')
    if [ -z "$destino" ]; then
        advertir "No se pudo ingresar con sofia@cupcore.com: prueba de roles omitida"
    else
        [ "$(curl -sk -c "$c1" -b "$c1" -o /dev/null -w '%{http_code}' "$URL_SITIO/index.php?ruta=admin")" != 200 ]
        probar "Un participante no entra al panel de administracion" $?
    fi
    grupo "Recorrido de rutas y metodos (A05)"
    ! curl -sk "$URL_SITIO/index.php?ruta=../../../../etc/passwd" | grep -q 'root:x:0:0'
    probar "ruta=../../etc/passwd no muestra archivos del sistema" $?
    [ "$(codigo_http "$URL_SITIO/modelos/Usuario.php")" = 403 ]; probar "El codigo PHP de modelos no se sirve" $?
    [ "$(codigo_http -X TRACE "$URL_SITIO/")" = 405 ]; probar "El metodo TRACE esta desactivado" $?
    grep -qi '^x-frame-options: sameorigin' < <(curl -skI "$URL_SITIO/"); probar "Cabecera X-Frame-Options contra clickjacking" $?
    grupo "TLS (A02)"
    openssl s_client -connect 127.0.0.1:443 -tls1_2 < /dev/null > /dev/null 2>&1; probar "TLS 1.2 aceptado" $?
    openssl s_client -connect 127.0.0.1:443 -tls1_3 < /dev/null > /dev/null 2>&1; probar "TLS 1.3 aceptado" $?
    ! openssl s_client -connect 127.0.0.1:443 -tls1_1 -cipher 'DEFAULT@SECLEVEL=0' < /dev/null > /dev/null 2>&1
    probar "TLS 1.1 rechazado" $?
    ! openssl s_client -connect 127.0.0.1:443 -tls1 -cipher 'DEFAULT@SECLEVEL=0' < /dev/null > /dev/null 2>&1
    probar "TLS 1.0 rechazado" $?
    rm -f "$c1" "$c2" "$c3"
}

# 0 si la opcion de PHP esta apagada ("", 0 u Off)
ini_apagado() {
    local v
    v=$(php -r "echo ini_get('$1');" 2>/dev/null)
    case "${v,,}" in ''|0|off) return 0 ;; *) return 1 ;; esac
}

prueba_configuracion() {
    local puertos extra modo sshroot dias ultimo pendientes reglas
    grupo "Sistema"
    modo=$(getenforce 2>/dev/null)
    [ "$modo" = Enforcing ]; probar "SELinux en modo Enforcing (${modo:-sin SELinux})" $?
    puertos=$(ss -Htln | awk '{print $4}' | sort -u)
    extra=$(grep -vE '^(0\.0\.0\.0|\[::\]|\*):(22|80|443)$|^127\.0\.0\.1:|^\[::1\]:' <<< "$puertos" | paste -sd' ' -)
    if [ -z "$extra" ]; then
        probar "Solo escuchan hacia afuera los puertos 22, 80 y 443" 0
    else
        advertir "Otros puertos escuchando: $extra"
    fi
    grep -qw 3306 <<< "$(firewall-cmd --list-ports 2>/dev/null) $(firewall-cmd --list-services 2>/dev/null)"
    [ $? -ne 0 ]; probar "El firewall no abre MariaDB" $?
    sshroot=$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" {print $2}')
    case "$sshroot" in
        no) probar "SSH no admite ingresar como root" 0 ;;
        prohibit-password|without-password) probar "SSH admite root solo con clave publica" 0 ;;
        *) advertir "SSH admite ingresar como root con contrasena (PermitRootLogin ${sshroot:-sin dato})" ;;
    esac
    fail2ban-client status sshd > /dev/null 2>&1; probar "Carcel sshd de fail2ban activa" $?
    grupo "Base de datos"
    [ "$(mysql -N -e "select count(*) from mysql.user where user=''" 2>/dev/null)" = 0 ]
    probar "MariaDB sin usuarios anonimos" $?
    [ "$(mysql -N -e "select count(*) from mysql.user where user='root' and host not in ('localhost','127.0.0.1','::1')" 2>/dev/null)" = 0 ]
    probar "root de MariaDB solo desde el propio servidor" $?
    ! mysql -N -e 'show databases' 2>/dev/null | grep -qx test; probar "Sin la base de prueba test" $?
    grupo "Archivos y claves"
    ! runuser -u apache -- test -w "$DESTINO/index.php" 2>/dev/null; probar "Apache no puede modificar el sitio" $?
    [ "$(stat -c %a "$CREDENCIALES" 2>/dev/null)" = 600 ]; probar "Claves de la base con permiso 600" $?
    [ "$(stat -c %a "$CLAVE_CERTIFICADO" 2>/dev/null)" = 600 ]; probar "Clave privada del certificado con permiso 600" $?
    [ "$(stat -c %a /etc/cupcore/claves 2>/dev/null)" = 700 ]; probar "Carpeta de claves del respaldo con permiso 700" $?
    grupo "PHP"
    ini_apagado expose_php;     probar "expose_php desactivado" $?
    ini_apagado display_errors; probar "display_errors desactivado" $?
    ini_apagado file_uploads;   probar "Carga de archivos desactivada" $?
    ini_apagado session.upload_progress.enabled; probar "Progreso de carga en la sesion desactivado (PHP2Shell)" $?
    grupo "Deteccion y respaldo"
    reglas=$(grep -c '^alert' /var/lib/suricata/rules/cupcore.rules 2>/dev/null)
    [ "${reglas:-0}" -ge 7 ] && systemctl is-active -q suricata 2>/dev/null
    probar "Suricata activo con las 7 reglas de CupCore (${reglas:-0} cargadas)" $?
    ultimo=$(ls -t /backup/mysql/*.enc 2>/dev/null | head -1)
    if [ -n "$ultimo" ]; then
        dias=$(( ( $(date +%s) - $(stat -c %Y "$ultimo") ) / 86400 ))
        [ "$dias" -le 8 ] && [ -s "$ultimo.firma" ]; probar "Ultimo respaldo firmado, de hace $dias dias" $?
    else
        probar "Hay un respaldo cifrado en /backup/mysql" 1
    fi
    grupo "Actualizaciones"
    if hacer "Consulta de actualizaciones de seguridad" dnf -q updateinfo list --security; then
        pendientes=$(grep -c . <<< "$UI_SALIDA")
        if [ "$pendientes" -eq 0 ]; then
            probar "Sin actualizaciones de seguridad pendientes" 0
        else
            advertir "Actualizaciones de seguridad pendientes: $pendientes (dnf upgrade --security)"
        fi
    else
        advertir "No se pudo consultar las actualizaciones (sin acceso a los repositorios)"
    fi
}

prueba_fuerza_bruta() {
    local cookies i msg correo="fuerza.bruta.prueba@cupcore.com"
    cookies=$(mktemp)
    grupo "Fuerza bruta (A07)"
    for i in 1 2 3 4 5; do
        mensaje_ingreso "$cookies" "$correo" "Equivocada2026\$$i" > /dev/null
    done
    msg=$(mensaje_ingreso "$cookies" "$correo" 'Equivocada2026$6')
    grep -qi 'bloqueada' <<< "$msg"; probar "Despues de 5 intentos fallidos, la cuenta queda bloqueada" $?
    [ "$(grep -c "LOGIN FALLIDO usuario=$correo" "$CARPETA_LOG/acceso.log" 2>/dev/null)" -ge 5 ]
    probar "Los intentos quedan en $CARPETA_LOG/acceso.log" $?
    fail2ban-client get cupcore-login logpath 2>/dev/null | grep -q acceso.log
    probar "fail2ban vigila ese registro (las IP locales estan exceptuadas)" $?
    rm -f "$cookies"
}

menu_pruebas() {
    while true; do
        contexto
        ui_pantalla "Servidor" "Pruebas de seguridad"
        ui_menu_nuevo "PRUEBAS DE SEGURIDAD"
        ui_menu_op 1 "Sitio" "18: HTTPS, cabeceras, ingreso, base"
        ui_menu_cmd "curl a https://127.0.0.1  ·  mysql -e  ·  fail2ban-client"
        ui_menu_op 2 "Ataques simulados al sitio" "SQL, XSS, CSRF, sesiones, roles, TLS"
        ui_menu_cmd "curl con datos maliciosos  ·  openssl s_client"
        ui_menu_nota "suma un intento fallido a rfranco@cupcore.com"
        ui_menu_op 3 "Configuracion del servidor" "SELinux, puertos, MariaDB, claves, PHP"
        ui_menu_cmd "getenforce  ·  ss  ·  mysql -e  ·  stat  ·  dnf updateinfo"
        ui_menu_op 4 "Todas las anteriores"
        ui_menu_cmd "1, 2 y 3 en un solo informe"
        ui_menu_grupo_riesgo "Deja rastro en los registros"
        ui_menu_op 5 "Fuerza bruta contra el ingreso" "6 intentos con una cuenta inexistente" riesgo
        ui_menu_cmd "6 POST a ruta=login  ·  grep en acceso.log"
        ui_menu_hueco
        ui_menu_op X "Salir"
        ui_menu_pintar
        ui_detalle "Cada corrida deja un informe en /root/cupcore-pruebas-FECHA.txt"
        ui_menu_leer || continue
        case "$UI_OPCION" in
            1) ui_titulo "PRUEBAS DEL SITIO"; abrir_informe "Sitio"; prueba_sitio ;;
            2) ui_titulo "ATAQUES SIMULADOS"; abrir_informe "Ataques simulados"; prueba_ataques ;;
            3) ui_titulo "CONFIGURACION DEL SERVIDOR"; abrir_informe "Configuracion"; prueba_configuracion ;;
            4) ui_titulo "TODAS LAS PRUEBAS"; abrir_informe "Todas"
               prueba_sitio; prueba_ataques; prueba_configuracion ;;
            5) ui_titulo "FUERZA BRUTA"
               ui_aviso "Hace 6 ingresos fallidos con fuerza.bruta.prueba@cupcore.com."
               ui_detalle "Quedan en el registro de accesos; esa cuenta no existe y ninguna cuenta real se bloquea."
               ui_si_no "Correrla" || continue
               abrir_informe "Fuerza bruta"; prueba_fuerza_bruta ;;
            X) ui_salir 0 ;;
        esac
        cerrar_informe
        ui_pausa
    done
}

main() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Ejecutar como root: sudo bash $0"
        exit 1
    fi
    if [ ! -d "$DESTINO" ]; then
        echo "CupCore no esta instalado en $DESTINO: instalar antes con instalar-servidor.sh"
        exit 1
    fi
    ui_init "CUPCORE  ·  PRUEBAS DE SEGURIDAD" "cupcore-pruebas"
    menu_pruebas
}

main "$@"
