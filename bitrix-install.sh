#!/usr/bin/env bash
#
# Установка демосайта «1С-Битрикс: Управление сайтом» в Docker на Ubuntu 24.04.
# Доводит сервер до состояния «открой установщик в браузере».
#
# Запуск:  bash bitrix-install.sh           меню
#          bash bitrix-install.sh --check   только проверка, без меню
#
set -uo pipefail

ENV_DIR="$HOME/1c-bitrix"
WORK="$ENV_DIR/env-docker-main"
ZIP_URL="https://github.com/bitrix-tools/env-docker/archive/refs/heads/main.zip"
SETUP_URL="https://www.1c-bitrix.ru/download/scripts/bitrixsetup.php"

C_OK=$'\033[32m'; C_NO=$'\033[31m'; C_DIM=$'\033[90m'; C_B=$'\033[1m'; C_Y=$'\033[33m'
C_CY=$'\033[36m'; C_F=$'\033[33m'; C_0=$'\033[0m'

bold()  { printf '%s%s%s\n' "$C_B" "$*" "$C_0"; }
info()  { printf '  %s\n' "$*"; }
ok()    { printf '  %s✓%s %s\n' "$C_OK" "$C_0" "$*"; }
bad()   { printf '  %s✗%s %s\n' "$C_NO" "$C_0" "$*"; }
warn()  { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()   { printf '\n%sОшибка:%s %s\n\n' "$C_NO" "$C_0" "$*" >&2; exit 1; }
step()  { printf '\n%s%s%s%s\n' "$C_B" "$C_CY" "$*" "$C_0"; }
pause() { echo; read -rsp "  Enter — вернуться в меню… " _ || true; echo; }

genpw() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }

SPINLOG=/tmp/bitrix-install-step.log

# spin "что делаем" команда...  — крутилка, пока команда работает
spin() {
    local msg="$1"; shift
    if [ ! -t 1 ]; then
        info "$msg…"
        if "$@" >"$SPINLOG" 2>&1; then ok "$msg"; return 0
        else bad "$msg"; tail -15 "$SPINLOG"; return 1; fi
    fi
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local rc=0 i=0 t0=$SECONDS
    "$@" >"$SPINLOG" 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 10 ))
        printf '\r  %s%s%s %s %s(%ss)%s  ' "$C_CY" "${frames[$i]}" "$C_0" "$msg" "$C_DIM" "$((SECONDS - t0))" "$C_0"
        sleep 0.15
    done
    wait "$pid" || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '\r  %s✓%s %s %s(%sс)%s          \n' "$C_OK" "$C_0" "$msg" "$C_DIM" "$((SECONDS - t0))" "$C_0"
    else
        printf '\r  %s✗%s %s                    \n' "$C_NO" "$C_0" "$msg"
        tail -15 "$SPINLOG"
    fi
    return "$rc"
}
mask()  { printf '%s%s' "${1:0:3}" "$(printf '%.0s•' $(seq 1 $(( ${#1} > 3 ? ${#1} - 3 : 0 ))))"; }

# ─── состояние ───────────────────────────────────────────────────────

CHECKS=unknown          # unknown | passed | failed
FAILED=0
INSTALLED=no
PORT=8588
ROOT_PW="$(genpw)"
USER_PW="$(genpw)"
ADMIN_LOGIN="admin"
ADMIN_PW="$(genpw)"
SETCHOICE=1

set_profile() {
    case "$SETCHOICE" in
        1) DISABLE="postgres sphinx memcached push-sub push-pub redis ssl lego"
           SETNAME="минимальный"; SETINFO="4 контейнера, образов ~2,5 ГБ" ;;
        2) DISABLE="postgres lego"
           SETNAME="полный";      SETINFO="10 контейнеров, образов ~3,1 ГБ" ;;
    esac
}
set_profile

# ─── проверки ────────────────────────────────────────────────────────

check() {
    local label="$1" cmd="$2" extra="${3:-}"
    if eval "$cmd" >/dev/null 2>&1; then
        ok "${label}${extra:+: $extra}"
    else
        bad "${label}${extra:+: $extra}"
        FAILED=$((FAILED + 1))
    fi
}

do_checks() {
    step "Проверка сервера"
    FAILED=0

    . /etc/os-release 2>/dev/null || true
    local free_gb ram_mb pyver
    free_gb=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
    ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    pyver=$(python3 -V 2>&1 | awk '{print $2}')

    printf '\n  %sСИСТЕМА%s\n' "$C_DIM" "$C_0"
    check "права root"                   '[ "$(id -u)" -eq 0 ]'
    check "ОС"                           '[ "${VERSION_ID:-}" = "24.04" ]'              "${PRETTY_NAME:-неизвестна}"
    check "архитектура"                  '[ "$(dpkg --print-architecture)" = "amd64" ]' "$(dpkg --print-architecture 2>/dev/null)"
    check "python3"                      'command -v python3'                           "${pyver:-нет}"
    check "systemd"                      '[ -d /run/systemd/system ]'
    check "apt не занят"                 '! fuser /var/lib/dpkg/lock-frontend'

    printf '\n  %sРЕСУРСЫ%s\n' "$C_DIM" "$C_0"
    check "свободно на диске"            "[ ${free_gb:-0} -ge 10 ]"                     "${free_gb:-?} ГБ, нужно от 10"
    check "оперативная память"           "[ ${ram_mb:-0} -ge 3500 ]"                    "${ram_mb:-?} МБ, нужно от 3500"

    printf '\n  %sМЕСТО ПОД УСТАНОВКУ%s\n' "$C_DIM" "$C_0"
    check "каталог $ENV_DIR свободен"    '[ ! -e "$ENV_DIR" ]'
    check "порт $PORT свободен"          "! ss -tlnp 2>/dev/null | grep -q ':$PORT '"
    check "порт $((PORT+1)) свободен"    "! ss -tlnp 2>/dev/null | grep -q ':$((PORT+1)) '"   "для https"

    printf '\n  %sСЕТЬ%s\n' "$C_DIM" "$C_0"
    check "github.com доступен"          'curl -fsL --max-time 8 -o /dev/null https://github.com'
    check "download.docker.com доступен" 'curl -fsL --max-time 8 -o /dev/null https://download.docker.com'
    check "www.1c-bitrix.ru доступен"    'curl -fsL --max-time 8 -o /dev/null https://www.1c-bitrix.ru'

    echo
    if command -v docker >/dev/null 2>&1; then
        info "Docker уже установлен ($(docker --version 2>/dev/null | cut -d, -f1)) — шаг установки будет пропущен"
    else
        info "Docker не установлен — будет поставлен из официального репозитория"
    fi

    echo
    if [ "$FAILED" -eq 0 ]; then
        CHECKS=passed
        printf '  %s✓ Все проверки пройдены. Пункт 3 разблокирован.%s\n' "$C_OK" "$C_0"
    else
        CHECKS=failed
        printf '  %s✗ Не пройдено: %s. Исправьте отмеченное и проверьте снова.%s\n' "$C_NO" "$FAILED" "$C_0"
    fi
}

# ─── настройки ───────────────────────────────────────────────────────

ask_port() {
    local p
    read -rp "  Новый порт [$PORT]: " p
    p="${p:-$PORT}"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1024 ] || [ "$p" -gt 65535 ]; then
        bad "нужно число от 1024 до 65535"; return
    fi
    PORT="$p"; CHECKS=unknown
    ok "порт: $PORT (https $((PORT+1)))"
    warn "проверку надо пройти заново — пункт 1"
}

ask_pw() {
    local which="$1" p
    read -rp "  Пароль $which (Enter — сгенерировать): " p
    if [ -z "$p" ]; then
        p="$(genpw)"
    elif ! [[ "$p" =~ ^[A-Za-z0-9_.-]{8,}$ ]]; then
        bad "годятся латиница, цифры, _ . - и минимум 8 символов"; return
    fi
    case "$which" in
        root)   ROOT_PW="$p" ;;
        bitrix) USER_PW="$p" ;;
        admin)  ADMIN_PW="$p" ;;
    esac
    ok "пароль $which: $p"
}

ask_login() {
    local l
    read -rp "  Логин администратора сайта [$ADMIN_LOGIN]: " l
    l="${l:-$ADMIN_LOGIN}"
    if ! [[ "$l" =~ ^[A-Za-z0-9_.-]{3,}$ ]]; then
        bad "годятся латиница, цифры, _ . - и минимум 3 символа"; return
    fi
    ADMIN_LOGIN="$l"; ok "логин администратора: $ADMIN_LOGIN"
}

settings_menu() {
    while true; do
        set_profile
        local other_name other_info
        if [ "$SETCHOICE" = 1 ]; then
            other_name="полный";      other_info="10 контейнеров, образов ~3,1 ГБ"
        else
            other_name="минимальный"; other_info="4 контейнера, образов ~2,5 ГБ"
        fi

        printf '\n   %s%s┌─ НАСТРОЙКИ ──────────────────────────────────────────┐%s\n' "$C_B" "$C_CY" "$C_0"
        printf '   %s│%s  значения, с которыми пойдёт установка              %s│%s\n' "$C_CY" "$C_DIM" "$C_CY" "$C_0"
        printf '   %s└──────────────────────────────────────────────────────┘%s\n' "$C_CY" "$C_0"

        printf '\n   %sСЕТЬ%s\n' "$C_DIM" "$C_0"
        printf '   %s[1]%s  Порт сайта            %s%s%s  ·  https %s\n' "$C_CY" "$C_0" "$C_B" "$PORT" "$C_0" "$((PORT+1))"

        printf '\n   %sБАЗА ДАННЫХ%s   %sскрипт впишет сам%s\n' "$C_DIM" "$C_0" "$C_DIM" "$C_0"
        printf '   %s[2]%s  Пароль root           %s\n' "$C_CY" "$C_0" "$(mask "$ROOT_PW")"
        printf '   %s[3]%s  Пароль bitrix         %s\n' "$C_CY" "$C_0" "$(mask "$USER_PW")"

        printf '\n   %sАДМИНИСТРАТОР САЙТА%s   %sвведёте в мастере сами%s\n' "$C_DIM" "$C_0" "$C_DIM" "$C_0"
        printf '   %s[4]%s  Логин                 %s%s%s\n' "$C_CY" "$C_0" "$C_B" "$ADMIN_LOGIN" "$C_0"
        printf '   %s[5]%s  Пароль                %s\n' "$C_CY" "$C_0" "$(mask "$ADMIN_PW")"

        printf '\n   %sНАБОР КОНТЕЙНЕРОВ%s\n' "$C_DIM" "$C_0"
        printf '   %s[6]%s  Переключить           %sсейчас%s %s%s%s %s· %s%s\n' \
               "$C_CY" "$C_0" "$C_DIM" "$C_0" "$C_B" "$SETNAME" "$C_0" "$C_DIM" "$SETINFO" "$C_0"

        printf '\n   %s[7]%s  Показать пароли открыто\n' "$C_CY" "$C_0"
        printf '   %s[8]%s  Сгенерировать новые пароли\n' "$C_CY" "$C_0"
        printf '   %s[0]%s  Назад\n\n' "$C_DIM" "$C_0"

        local c
        if ! read -rp "  Выбор: " c; then echo; return; fi
        case "$c" in
            1) ask_port ;;
            2) ask_pw root ;;
            3) ask_pw bitrix ;;
            4) ask_login ;;
            5) ask_pw admin ;;
            6) if [ "$SETCHOICE" = 1 ]; then SETCHOICE=2; else SETCHOICE=1; fi
               set_profile; ok "набор: $SETNAME, $SETINFO" ;;
            7) echo
               info "MySQL root ......: $ROOT_PW"
               info "MySQL bitrix ....: $USER_PW"
               info "Админ логин .....: $ADMIN_LOGIN"
               info "Админ пароль ....: $ADMIN_PW" ;;
            8) ROOT_PW="$(genpw)"; USER_PW="$(genpw)"; ADMIN_PW="$(genpw)"
               ok "три пароля сгенерированы заново" ;;
            0) return ;;
            *) bad "нет такого пункта" ;;
        esac
    done
}

# ─── установка ───────────────────────────────────────────────────────

do_install() (
    set -e
    set_profile

    step "Будет сделано"
    info "порт сайта ..... $PORT (https $((PORT+1)))"
    info "набор .......... $SETNAME, $SETINFO"
    info "выключаются .... $DISABLE"
    info "каталог ........ $WORK"
    echo
    local go; read -rp "  Начинаем? [y/N]: " go
    [[ "${go,,}" == "y" ]] || { echo; info "Отменено."; exit 10; }

    step "[1/6] Системные пакеты"
    export DEBIAN_FRONTEND=noninteractive
    spin "обновляю список пакетов" apt-get update -qq
    spin "ставлю ca-certificates, curl, gnupg, git, unzip" \
         apt-get install -y -qq ca-certificates curl gnupg git unzip

    step "[2/6] Docker"
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        ok "уже установлен: $(docker --version | cut -d, -f1)"
    else
        local pkg
        for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
            apt-get remove -y -qq "$pkg" >/dev/null 2>&1 || true
        done
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        . /etc/os-release
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
            "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
        spin "обновляю список пакетов с репозиторием Docker" apt-get update -qq
        spin "ставлю Docker Engine и Compose, около 400 МБ" \
             apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
             docker-buildx-plugin docker-compose-plugin
        spin "включаю службу docker" systemctl enable --now docker
        ok "установлен: $(docker --version | cut -d, -f1)"
    fi
    ok "compose: $(docker compose version --short)"

    step "[3/6] Окружение Битрикса"
    mkdir -p "$ENV_DIR"; cd "$ENV_DIR"
    info "скачивание архива, 693 МБ…"
    wget -q --show-progress "$ZIP_URL" -O main.zip
    spin "распаковываю архив" unzip -q main.zip
    [ -f "$WORK/docker-compose.yml" ] || die "Распаковка не удалась: нет $WORK/docker-compose.yml"
    ok "распаковано в $WORK"

    step "[4/6] Настройка"
    cd "$WORK"
    cp docker-compose.yml docker-compose.yml.orig

    ROOT_PW="$ROOT_PW" USER_PW="$USER_PW" python3 - <<'PY'
import io, os
p = ".env_mysql"
s = io.open(p, encoding="utf-8").read()
s = s.replace("CHANGE_MYSQL_ROOT_PASSWORD_HERE", os.environ["ROOT_PW"])
s += 'MYSQL_DATABASE=bitrix\nMYSQL_USER=bitrix\nMYSQL_PASSWORD="%s"\n' % os.environ["USER_PW"]
io.open(p, "w", encoding="utf-8").write(s)
PY
    chmod 600 .env_mysql
    ok "пароли записаны в .env_mysql"

    DISABLE="$DISABLE" PORT="$PORT" PORT_HTTPS="$((PORT+1))" python3 - <<'PY'
import io, os, re
path = "docker-compose.yml"
lines = io.open(path, encoding="utf-8").read().split("\n")
off = os.environ["DISABLE"].split()

def comment_service(lines, name):
    out, inside = [], False
    for ln in lines:
        if re.match(r"^  %s:\s*$" % re.escape(name), ln):
            inside = True; out.append("#" + ln); continue
        if inside:
            if re.match(r"^  [A-Za-z0-9_-]+:\s*$", ln):
                inside = False; out.append(ln); continue
            out.append(("#" + ln) if ln.strip() else ln); continue
        out.append(ln)
    return out

def comment_dep(lines, dep):
    out, in_dep = [], False
    for ln in lines:
        if re.match(r"^\s*depends_on:\s*$", ln):
            in_dep = True; out.append(ln); continue
        if in_dep:
            if re.match(r"^\s*- %s\s*$" % re.escape(dep), ln):
                out.append(re.sub(r"^(\s*)", r"#\1", ln, count=1)); continue
            if not re.match(r"^\s*- ", ln):
                in_dep = False
        out.append(ln)
    return out

for svc in off: lines = comment_service(lines, svc)
for svc in off: lines = comment_dep(lines, svc)
text = "\n".join(lines)
text = text.replace('"8588:80"',  '"%s:80"'  % os.environ["PORT"])
text = text.replace('"8589:443"', '"%s:443"' % os.environ["PORT_HTTPS"])
io.open(path, "w", encoding="utf-8").write(text)
PY

    # nginx тянет push-сервер через собственные конфиги, а не через depends_on:
    # если контейнеры push выключены, nginx упадёт на "host not found in upstream".
    if [[ " $DISABLE " == *" push-sub "* ]]; then
        python3 - <<'PY'
import io, re
p = "confs/nginx/conf.d/default.conf"
s = io.open(p, encoding="utf-8").read()
io.open(p + ".orig", "w", encoding="utf-8").write(s)
s = re.sub(r"(?m)^(\s*)(include\s+/etc/nginx/inc/push(?:_secure)?\.conf;)", r"\1#\2", s)
io.open(p, "w", encoding="utf-8").write(s)
PY
        ok "в конфиге nginx отключены push-конфиги (контейнеры push выключены)"
    fi

    docker compose config -q || die "compose-файл стал некорректным. Оригинал: $WORK/docker-compose.yml.orig"
    local planned; planned=$(docker compose config --services | wc -l)
    ok "сервисов в конфигурации: $planned"
    ok "порт сайта: $PORT"

    step "[5/6] Запуск контейнеров"
    info "сейчас скачаются образы — это самая долгая часть, 5–15 минут."
    info "Docker покажет свой прогресс по каждому образу."
    echo
    docker compose up -d
    local up; up=$(docker compose ps --services --filter status=running | wc -l)
    [ "$up" -ge "$planned" ] || warn "запущено $up из $planned, проверьте: docker compose ps"
    ok "контейнеров работает: $up"

    local ngx_ok=no i t0=$SECONDS
    for i in $(seq 1 12); do
        if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${PORT}/"; then ngx_ok=yes; break; fi
        [ -t 1 ] && printf '\r  %s⠿%s жду ответа от nginx %s(%sс из 36)%s  ' \
                     "$C_CY" "$C_0" "$C_DIM" "$((SECONDS - t0))" "$C_0"
        sleep 3
    done
    [ -t 1 ] && printf '\r%*s\r' 60 ""
    if [ "$ngx_ok" = yes ]; then
        ok "nginx отвечает на порту $PORT"
    else
        docker compose logs --tail=15 nginx
        die "nginx не отвечает на порту $PORT. Лог выше."
    fi

    local j t1=$SECONDS
    for j in $(seq 1 60); do
        docker compose exec -T mysql mysql -u bitrix -p"$USER_PW" -e "SELECT 1" >/dev/null 2>&1 && break
        [ "$j" -eq 60 ] && die "База не поднялась за 5 минут. Логи: docker compose logs --tail=50 mysql"
        [ -t 1 ] && printf '\r  %s⠿%s база создаётся, это первый запуск %s(%sс из 300)%s  ' \
                     "$C_CY" "$C_0" "$C_DIM" "$((SECONDS - t1))" "$C_0"
        sleep 5
    done
    [ -t 1 ] && printf '\r%*s\r' 60 ""
    ok "база bitrix готова, пользователь bitrix подключается $(printf '%s(%sс)%s' "$C_DIM" "$((SECONDS - t1))" "$C_0")"

    step "[6/6] Скрипт установки"
    docker compose exec -T --user=bitrix php sh -lc "cd /opt/www/ && wget -q $SETUP_URL"
    docker compose exec -T php ls /opt/www/ | grep -q bitrixsetup.php \
        || die "bitrixsetup.php не оказался в /opt/www внутри контейнера."
    ok "bitrixsetup.php на месте"

    echo
    local zipsize; zipsize=$(du -h "$ENV_DIR/main.zip" 2>/dev/null | cut -f1)
    info "Архив main.zip (${zipsize:-693M}) распакован, для работы сайта больше не нужен."
    info "Пригодится только если захотите развернуть окружение заново без скачивания."
    local rmzip; read -rp "  Удалить его? [Y/n]: " rmzip
    if [[ "${rmzip,,}" != "n" ]]; then
        rm -f "$ENV_DIR/main.zip"
        ok "архив удалён, место освобождено"
    else
        info "архив оставлен: $ENV_DIR/main.zip"
    fi
)

# ─── справка после установки ─────────────────────────────────────────

server_ip() { curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'; }

show_params() {
    local ip; ip="$(server_ip)"
    step "Параметры для мастера установки"
    echo
    info "Установщик:  http://${ip}:${PORT}/bitrixsetup.php"
    echo
    bold "  Экран «Создание базы данных»"
    info "  Сервер ....................  mysql"
    info "  Пользователь базы данных ..  Существующий"
    info "  Имя пользователя ..........  bitrix"
    info "  Пароль ....................  ${USER_PW}"
    info "  База данных ...............  Существующая"
    info "  Имя базы данных ...........  bitrix"
    echo
    bold "  Экран «Создание администратора» — вводится вручную"
    info "  Логин .....................  ${ADMIN_LOGIN}"
    info "  Пароль ....................  ${ADMIN_PW}"
    echo
    bold "  Все пароли разом"
    info "  MySQL root ................  ${ROOT_PW}"
    info "  MySQL bitrix ..............  ${USER_PW}"
    info "  Админ сайта ...............  ${ADMIN_LOGIN} / ${ADMIN_PW}"
    info "  Пароли БД в файле .........  ${WORK}/.env_mysql"
    echo
    bold "  После установки сайта"
    info "  Сайт ......................  http://${ip}:${PORT}/"
    info "  Админка ...................  http://${ip}:${PORT}/bitrix/admin/"
    echo
    bold "  Когда сайт заработает — уберите файлы установщика"
    info "  Они лежат в корне сайта и открыты любому, кто знает адрес:"
    info "  через них можно запустить установку заново и затереть ваш сайт."
    info "  После успешной установки Битрикс стирает установщик сам."
    info "  Если мастер оборвался — удалите вручную и скачайте заново:"
    echo
    info "    cd ${WORK}"
    info "    docker compose exec --user=bitrix php rm -f /opt/www/bitrixsetup.php"
}

show_state() {
    step "Состояние сервера"
    if command -v docker >/dev/null 2>&1; then
        ok "Docker: $(docker --version | cut -d, -f1)"
    else
        info "Docker не установлен"
    fi
    if [ -d "$WORK" ]; then
        ok "окружение: $WORK"
        if docker compose -f "$WORK/docker-compose.yml" ps >/dev/null 2>&1; then
            echo
            (cd "$WORK" && docker compose ps --format "   {{.Name}}  {{.Status}}") 2>/dev/null
        fi
    else
        info "окружение не развёрнуто"
    fi
    echo
    info "свободно на диске: $(df -h / | awk 'NR==2{print $4}')"
}

remove_bitrix() {
    if [ -f "$WORK/docker-compose.yml" ]; then
        info "останавливаю контейнеры и стираю тома…"
        (cd "$WORK" && docker compose down -v) >/dev/null 2>&1 || true
    fi
    rm -rf "$ENV_DIR"
    ok "контейнеры, тома и каталог $ENV_DIR удалены"
}

remove_docker() {
    info "останавливаю службу…"
    systemctl stop docker docker.socket >/dev/null 2>&1 || true
    systemctl disable docker >/dev/null 2>&1 || true

    info "удаляю пакеты…"
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y -qq docker-ce docker-ce-cli >/dev/null 2>&1 || true
    apt-get purge -y -qq containerd.io >/dev/null 2>&1 || true
    apt-get purge -y -qq docker-buildx-plugin >/dev/null 2>&1 || true
    apt-get purge -y -qq docker-compose-plugin >/dev/null 2>&1 || true
    apt-get purge -y -qq docker-ce-rootless-extras >/dev/null 2>&1 || true
    apt-get purge -y -qq docker.io containerd >/dev/null 2>&1 || true
    apt-get autoremove -y -qq >/dev/null 2>&1 || true

    info "удаляю данные, репозиторий и остатки…"
    rm -rf /var/lib/docker /var/lib/containerd
    rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
    ip link delete docker0 >/dev/null 2>&1 || true
    rm -rf /run/docker /run/containerd /var/run/docker.sock
    groupdel docker >/dev/null 2>&1 || true
    apt-get update -qq >/dev/null 2>&1 || true
    ok "Docker удалён"

    step "Проверка, что следов не осталось"
    local left=0
    dpkg -l 2>/dev/null | grep -qE "docker|containerd" && { bad "остались пакеты"; left=1; } || ok "пакетов нет"
    command -v docker >/dev/null 2>&1       && { bad "остался бинарник docker"; left=1; } || ok "бинарников нет"
    [ -e /var/lib/docker ]                  && { bad "остался /var/lib/docker"; left=1; } || ok "каталогов данных нет"
    getent group docker >/dev/null 2>&1     && { bad "осталась группа docker"; left=1; } || ok "группы docker нет"
    ip link show docker0 >/dev/null 2>&1    && { bad "остался мост docker0"; left=1; }   || ok "моста docker0 нет"
    echo
    if [ "$left" -eq 0 ]; then
        ok "сервер чистый"
        info "в iptables останутся цепочки DOCKER — они исчезнут при перезагрузке"
    fi
}

do_reinstall() {
    step "Переустановка с нуля"
    echo
    info "Нужна, если установка оборвалась: пропала связь, зависла загрузка"
    info "образов, скрипт закрыли на середине, мастер упал с ошибкой."
    info "Поверх недоделанной установки ставить нельзя — останутся битые"
    info "файлы и полупустая база, и новый мастер об них споткнётся."
    echo
    info "Что будет сделано по порядку:"
    info "  1. остановлены контейнеры, стёрты тома с базой и файлами сайта"
    info "  2. удалён каталог окружения вместе с архивом"
    info "  3. пройдена проверка сервера"
    info "  4. установка запущена с начала"
    echo
    info "Docker и его образы останутся — качать заново их не придётся."
    echo

    if [ -e "$ENV_DIR" ]; then
        local tables=0
        if [ -f "$WORK/.env_mysql" ] && (cd "$WORK" && docker compose ps --services --filter status=running 2>/dev/null | grep -q '^mysql$'); then
            tables=$(cd "$WORK" && docker compose exec -T mysql mysql -u root \
                     -p"$(grep MYSQL_ROOT_PASSWORD "$WORK/.env_mysql" | cut -d'"' -f2)" \
                     -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='bitrix';" 2>/dev/null)
        fi
        warn "Найдена прошлая установка в $ENV_DIR — она будет стёрта."
        [ "${tables:-0}" -gt 0 ] && warn "В базе $tables таблиц, они тоже пропадут."
    else
        info "Следов прошлой установки нет — просто поставим заново."
    fi

    echo
    local a
    if ! read -rp "  Продолжить? [y/N]: " a; then echo; return; fi
    [[ "${a,,}" == "y" ]] || { info "Отменено."; return; }

    if [ -e "$ENV_DIR" ]; then
        step "Очистка"
        remove_bitrix
    fi

    CHECKS=unknown; INSTALLED=no
    do_checks
    if [ "$CHECKS" != passed ]; then
        echo; bad "проверка не прошла — установка не запущена, смотрите крестики выше"
        return
    fi

    do_install; local rc=$?
    if [ "$rc" -eq 0 ]; then
        INSTALLED=yes
        printf '\n  %s✓ Переустановка завершена.%s\n' "$C_OK" "$C_0"
        show_params
    elif [ "$rc" -ne 10 ]; then
        bad "установка прервалась, код $rc — смотрите сообщение выше"
    fi
}

do_remove() {
    while true; do
        printf '\n   %s%s┌─ УДАЛЕНИЕ ───────────────────────────────────────────┐%s\n' "$C_B" "$C_NO" "$C_0"
        printf '   %s│%s  действия необратимы                                %s│%s\n' "$C_NO" "$C_DIM" "$C_NO" "$C_0"
        printf '   %s└──────────────────────────────────────────────────────┘%s\n' "$C_NO" "$C_0"
        printf '\n   %s[1]%s  Только Битрикс        %sконтейнеры, тома, каталог%s\n' "$C_NO" "$C_0" "$C_DIM" "$C_0"
        printf '   %s[2]%s  Вместе с Docker       %sплюс пакеты, образы, репозиторий%s\n' "$C_NO" "$C_0" "$C_DIM" "$C_0"
        printf '   %s[0]%s  Назад\n\n' "$C_DIM" "$C_0"

        local c
        if ! read -rp "  Выбор: " c; then echo; return; fi
        case "$c" in
            1) echo
               warn "Будут стёрты контейнеры, тома с базой и сайтом, каталог $ENV_DIR."
               local a; read -rp "  Введите УДАЛИТЬ для подтверждения: " a
               [ "$a" = "УДАЛИТЬ" ] || { info "Отменено."; continue; }
               remove_bitrix
               INSTALLED=no; CHECKS=unknown
               return ;;
            2) echo
               warn "Будут стёрты: сайт, база, каталог $ENV_DIR, все пакеты Docker,"
               warn "все образы и тома в /var/lib/docker, репозиторий и ключ."
               warn "Если на сервере есть другие контейнеры — они тоже погибнут."
               local a; read -rp "  Введите УДАЛИТЬ ВСЁ для подтверждения: " a
               [ "$a" = "УДАЛИТЬ ВСЁ" ] || { info "Отменено."; continue; }
               remove_bitrix
               remove_docker
               INSTALLED=no; CHECKS=unknown
               return ;;
            0) return ;;
            *) bad "нет такого пункта" ;;
        esac
    done
}

# ─── меню ────────────────────────────────────────────────────────────

if [ "${1:-}" = "--check" ] || [ "${1:-}" = "-c" ]; then
    do_checks; [ "$CHECKS" = passed ] && exit 0 || exit 1
fi

while true; do
    set_profile
    case "$CHECKS" in
        passed) st="${C_OK}● пройдена${C_0}" ;;
        failed) st="${C_NO}✗ ошибок: $FAILED${C_0}" ;;
        *)      st="${C_DIM}○ не выполнялась${C_0}" ;;
    esac

    printf '\n%s%s╔════════════════════════════════════════════════════════╗%s\n' "$C_B" "$C_CY" "$C_0"
    printf '%s%s║   Битрикс в Docker  ·  установка на Ubuntu 24.04       ║%s\n' "$C_B" "$C_CY" "$C_0"
    printf '%s%s╚════════════════════════════════════════════════════════╝%s\n' "$C_B" "$C_CY" "$C_0"

    printf '\n   %sПОДГОТОВКА%s\n' "$C_DIM" "$C_0"
    printf '   %s[1]%s  Проверить сервер          %b\n' "$C_CY" "$C_0" "$st"
    printf '   %s[2]%s  Настройки                 %sпорт %s · %s%s\n' "$C_CY" "$C_0" "$C_DIM" "$PORT" "$SETNAME" "$C_0"

    printf '\n   %sУСТАНОВКА%s\n' "$C_DIM" "$C_0"
    if [ "$CHECKS" = passed ]; then
        printf '   %s[3]%s  Установить                %s● готово к запуску%s\n' "$C_CY" "$C_0" "$C_OK" "$C_0"
    else
        printf '   %s[3]%s  %sУстановить%s                %s○ сначала пункт 1%s\n' "$C_CY" "$C_0" "$C_DIM" "$C_0" "$C_DIM" "$C_0"
    fi

    printf '   %s[4]%s  Переустановить            %sесли оборвалась или зависла%s\n' "$C_CY" "$C_0" "$C_DIM" "$C_0"

    printf '\n   %sПОСЛЕ УСТАНОВКИ%s\n' "$C_DIM" "$C_0"
    printf '   %s[5]%s  Состояние сервера         %sчто сейчас на сервере%s\n' "$C_CY" "$C_0" "$C_DIM" "$C_0"
    if [ "$INSTALLED" = yes ] || [ -f "$WORK/docker-compose.yml" ]; then
        printf '   %s[6]%s  Параметры для мастера     %s● пароли и ссылки%s\n' "$C_CY" "$C_0" "$C_OK" "$C_0"
    else
        printf '   %s[6]%s  %sПараметры для мастера%s     %s○ после установки%s\n' "$C_CY" "$C_0" "$C_DIM" "$C_0" "$C_DIM" "$C_0"
    fi

    printf '\n   %sОПАСНОЕ%s\n' "$C_DIM" "$C_0"
    printf '   %s[7]%s  Удалить сайт и окружение  %sсотрёт данные%s\n' "$C_NO" "$C_0" "$C_DIM" "$C_0"

    printf '\n   %s[0]%s  Выход\n\n' "$C_DIM" "$C_0"

    if ! read -rp "  Выбор: " choice; then echo; info "Ввод закончился — выход."; echo; exit 0; fi
    case "$choice" in
        1) do_checks; pause ;;
        2) settings_menu ;;
        3) if [ "$CHECKS" != passed ]; then
               bad "сначала пункт 1 — проверка сервера"
           else
               do_install; rc=$?
               if [ "$rc" -eq 0 ]; then
                   INSTALLED=yes
                   printf '\n  %s✓ Установка завершена. Пункт 5 — параметры для мастера.%s\n' "$C_OK" "$C_0"
                   show_params
               elif [ "$rc" -eq 10 ]; then
                   :
               else
                   bad "установка прервалась, код $rc — смотрите сообщение выше"
               fi
           fi
           pause ;;
        4) do_reinstall; pause ;;
        5) show_state; pause ;;
        6) if [ "$INSTALLED" = yes ] || [ -f "$WORK/docker-compose.yml" ]; then show_params
           else bad "установка ещё не выполнена"; fi
           pause ;;
        7) do_remove; pause ;;
        0) echo; info "Выход."; echo; exit 0 ;;
        *) bad "нет такого пункта" ;;
    esac
done
