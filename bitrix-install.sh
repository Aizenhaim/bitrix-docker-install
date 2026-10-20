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
pause() { echo; read -rsp "$(printf '  %sEnter — вернуться в меню…%s' "$C_OK" "$C_0") " _ || true; echo; }

genpw() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }

SPINLOG=/tmp/bitrix-install-step.log

# spin "Что делаем" команда...  — крутилка, пока команда работает
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
    check "Права root"                   '[ "$(id -u)" -eq 0 ]'
    check "ОС"                           '[ "${VERSION_ID:-}" = "24.04" ]'              "${PRETTY_NAME:-неизвестна}"
    check "Архитектура"                  '[ "$(dpkg --print-architecture)" = "amd64" ]' "$(dpkg --print-architecture 2>/dev/null)"
    check "python3"                      'command -v python3'                           "${pyver:-нет}"
    check "systemd"                      '[ -d /run/systemd/system ]'
    check "apt не занят"                 '! fuser /var/lib/dpkg/lock-frontend'

    printf '\n  %sРЕСУРСЫ%s\n' "$C_DIM" "$C_0"
    check "Свободно на диске"            "[ ${free_gb:-0} -ge 10 ]"                     "${free_gb:-?} ГБ, нужно от 10"
    check "Оперативная память"           "[ ${ram_mb:-0} -ge 3500 ]"                    "${ram_mb:-?} МБ, нужно от 3500"

    printf '\n  %sМЕСТО ПОД УСТАНОВКУ%s\n' "$C_DIM" "$C_0"
    check "Каталог $ENV_DIR свободен"    '[ ! -e "$ENV_DIR" ]'
    check "Порт $PORT свободен"          "! ss -tlnp 2>/dev/null | grep -q ':$PORT '"
    check "Порт $((PORT+1)) свободен"    "! ss -tlnp 2>/dev/null | grep -q ':$((PORT+1)) '"   "для https"

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
    printf '  %sEnter — оставить текущий%s\n' "$C_DIM" "$C_0"
    read -rp "$(printf '  %sНовый порт [%s]:%s' "$C_OK" "$PORT" "$C_0") " p
    p="${p:-$PORT}"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1024 ] || [ "$p" -gt 65535 ]; then
        bad "Нужно число от 1024 до 65535"; return
    fi
    PORT="$p"; CHECKS=unknown
    ok "Порт: $PORT (https $((PORT+1)))"
    warn "Проверку надо пройти заново — пункт 1"
}

ask_pw() {
    local which="$1" p
    read -rp "$(printf '  %sПароль %s (Enter — сгенерировать):%s' "$C_OK" "$which" "$C_0") " p
    if [ -z "$p" ]; then
        p="$(genpw)"
    elif ! [[ "$p" =~ ^[A-Za-z0-9_.-]{8,}$ ]]; then
        bad "Годятся латиница, цифры, _ . - и минимум 8 символов"; return
    fi
    case "$which" in
        root)   ROOT_PW="$p" ;;
        bitrix) USER_PW="$p" ;;
        admin)  ADMIN_PW="$p" ;;
    esac
    ok "Пароль $which: ${C_F}${p}${C_0}"
}

ask_login() {
    local l
    printf '  %sEnter — оставить текущий%s\n' "$C_DIM" "$C_0"
    read -rp "$(printf '  %sЛогин администратора сайта [%s]:%s' "$C_OK" "$ADMIN_LOGIN" "$C_0") " l
    l="${l:-$ADMIN_LOGIN}"
    if ! [[ "$l" =~ ^[A-Za-z0-9_.-]{3,}$ ]]; then
        bad "Годятся латиница, цифры, _ . - и минимум 3 символа"; return
    fi
    ADMIN_LOGIN="$l"; ok "Логин администратора: ${C_B}${ADMIN_LOGIN}${C_0}"
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
        printf '   %s[2]%s  Пароль root           %s%s%s\n' "$C_CY" "$C_0" "$C_F" "$(mask "$ROOT_PW")" "$C_0"
        printf '   %s[3]%s  Пароль bitrix         %s%s%s\n' "$C_CY" "$C_0" "$C_F" "$(mask "$USER_PW")" "$C_0"

        printf '\n   %sАДМИНИСТРАТОР САЙТА%s   %sвведёте в мастере сами%s\n' "$C_DIM" "$C_0" "$C_DIM" "$C_0"
        printf '   %s[4]%s  Логин                 %s%s%s\n' "$C_CY" "$C_0" "$C_B" "$ADMIN_LOGIN" "$C_0"
        printf '   %s[5]%s  Пароль                %s%s%s\n' "$C_CY" "$C_0" "$C_F" "$(mask "$ADMIN_PW")" "$C_0"

        printf '\n   %sНАБОР КОНТЕЙНЕРОВ%s\n' "$C_DIM" "$C_0"
        printf '   %s[6]%s  Переключить           %sсейчас%s %s%s%s %s· %s%s\n' \
               "$C_CY" "$C_0" "$C_DIM" "$C_0" "$C_B" "$SETNAME" "$C_0" "$C_DIM" "$SETINFO" "$C_0"

        printf '\n   %s[7]%s  Показать пароли открыто\n' "$C_CY" "$C_0"
        printf '   %s[8]%s  Сгенерировать новые пароли\n' "$C_CY" "$C_0"
        printf '   %s[0]%s  Назад\n\n' "$C_DIM" "$C_0"

        local c
        if ! read -rp "$(printf '  %sВыбор (0 — назад):%s' "$C_OK" "$C_0") " c; then echo; return; fi
        case "$c" in
            1) ask_port ;;
            2) ask_pw root ;;
            3) ask_pw bitrix ;;
            4) ask_login ;;
            5) ask_pw admin ;;
            6) if [ "$SETCHOICE" = 1 ]; then SETCHOICE=2; else SETCHOICE=1; fi
               set_profile; ok "Набор: $SETNAME, $SETINFO" ;;
            7) echo
               info "MySQL root ......: ${C_F}${ROOT_PW}${C_0}"
               info "MySQL bitrix ....: ${C_F}${USER_PW}${C_0}"
               info "Админ логин .....: ${C_B}${ADMIN_LOGIN}${C_0}"
               info "Админ пароль ....: ${C_F}${ADMIN_PW}${C_0}" ;;
            8) ROOT_PW="$(genpw)"; USER_PW="$(genpw)"; ADMIN_PW="$(genpw)"
               ok "Три пароля сгенерированы заново" ;;
            0) return ;;
            *) bad "Нет такого пункта" ;;
        esac
    done
}

# ─── установка ───────────────────────────────────────────────────────

do_install() (
    set -e
    set_profile

    step "Будет сделано"
    info "Порт сайта ..... $PORT (https $((PORT+1)))"
    info "Набор .......... $SETNAME, $SETINFO"
    info "Выключаются .... $DISABLE"
    info "Каталог ........ $WORK"
    echo
    local go
    printf '  %sy и Enter — начать, просто Enter — отмена%s\n' "$C_DIM" "$C_0"
    read -rp "$(printf '  %sНачинаем? [y/N]:%s' "$C_OK" "$C_0") " go
    [[ "${go,,}" == "y" ]] || { echo; info "Отменено."; exit 10; }

    step "[1/6] Системные пакеты"
    export DEBIAN_FRONTEND=noninteractive
    spin "Обновляю список пакетов" apt-get update -qq
    spin "Ставлю ca-certificates, curl, gnupg, git, unzip" \
         apt-get install -y -qq ca-certificates curl gnupg git unzip

    step "[2/6] Docker"
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        ok "Уже установлен: $(docker --version | cut -d, -f1)"
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
        spin "Обновляю список пакетов с репозиторием Docker" apt-get update -qq
        spin "Ставлю Docker Engine и Compose, около 400 МБ" \
             apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
             docker-buildx-plugin docker-compose-plugin
        spin "Включаю службу docker" systemctl enable --now docker
        ok "Установлен: $(docker --version | cut -d, -f1)"
    fi
    ok "compose: $(docker compose version --short)"

    step "[3/6] Окружение Битрикса"
    mkdir -p "$ENV_DIR"; cd "$ENV_DIR"
    info "Скачивание архива, 693 МБ…"
    wget -q --show-progress "$ZIP_URL" -O main.zip
    spin "Распаковываю архив" unzip -q main.zip
    [ -f "$WORK/docker-compose.yml" ] || die "Распаковка не удалась: нет $WORK/docker-compose.yml"
    ok "Распаковано в $WORK"

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
    ok "Пароли записаны в .env_mysql"

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
        ok "В конфиге nginx отключены push-конфиги (контейнеры push выключены)"
    fi

    docker compose config -q || die "compose-файл стал некорректным. Оригинал: $WORK/docker-compose.yml.orig"
    local planned; planned=$(docker compose config --services | wc -l)
    ok "Сервисов в конфигурации: $planned"
    ok "Порт сайта: $PORT"

    step "[5/6] Запуск контейнеров"
    info "Сейчас скачаются образы — это самая долгая часть, 5–15 минут."
    info "Docker покажет свой прогресс по каждому образу."
    echo
    docker compose up -d
    local up; up=$(docker compose ps --services --filter status=running | wc -l)
    [ "$up" -ge "$planned" ] || warn "Запущено $up из $planned, проверьте: docker compose ps"
    ok "Контейнеров работает: $up"

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
    ok "База bitrix готова, пользователь bitrix подключается $(printf '%s(%sс)%s' "$C_DIM" "$((SECONDS - t1))" "$C_0")"

    step "[6/6] Скрипт установки"
    docker compose exec -T --user=bitrix php sh -lc "cd /opt/www/ && wget -q $SETUP_URL"
    docker compose exec -T php ls /opt/www/ | grep -q bitrixsetup.php \
        || die "bitrixsetup.php не оказался в /opt/www внутри контейнера."
    ok "bitrixsetup.php на месте"

    echo
    local zipsize; zipsize=$(du -h "$ENV_DIR/main.zip" 2>/dev/null | cut -f1)
    info "Архив main.zip (${zipsize:-693M}) распакован, для работы сайта больше не нужен."
    info "Пригодится только если захотите развернуть окружение заново без скачивания."
    local rmzip
    printf '  %sEnter — удалить, n и Enter — оставить%s\n' "$C_DIM" "$C_0"
    read -rp "$(printf '  %sУдалить его? [Y/n]:%s' "$C_OK" "$C_0") " rmzip
    if [[ "${rmzip,,}" != "n" ]]; then
        rm -f "$ENV_DIR/main.zip"
        ok "Архив удалён, место освобождено"
    else
        info "Архив оставлен: $ENV_DIR/main.zip"
    fi
)

# ─── справка после установки ─────────────────────────────────────────

server_ip() { curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'; }

show_params() {
    local ip rp up src
    ip="$(server_ip)"

    # если окружение развёрнуто — берём настоящие пароли из файла, а не из памяти
    if [ -f "$WORK/.env_mysql" ]; then
        rp=$(grep '^MYSQL_ROOT_PASSWORD=' "$WORK/.env_mysql" | cut -d'"' -f2)
        up=$(grep '^MYSQL_PASSWORD='      "$WORK/.env_mysql" | cut -d'"' -f2)
        src="из файла .env_mysql установленного окружения"
    else
        rp="$ROOT_PW"; up="$USER_PW"
        src="сгенерированы сейчас, установка ещё не выполнялась"
    fi

    step "Параметры для мастера установки"
    printf '  %s%s%s\n' "$C_DIM" "$src" "$C_0"

    # ── адрес установщика крупно, в рамке ──────────────────────────
    local url label inner bar pad1 pad2
    url="http://${ip}:${PORT}/bitrixsetup.php"
    label="ОТКРОЙТЕ ЭТО В БРАУЗЕРЕ"
    inner=$(( ${#url} > ${#label} ? ${#url} : ${#label} ))
    inner=$(( inner + 4 ))
    bar=$(printf '═%.0s' $(seq 1 "$inner"))
    pad1=$(printf '%*s' $(( inner - ${#label} - 2 )) '')
    pad2=$(printf '%*s' $(( inner - ${#url}   - 2 )) '')

    echo
    printf '  %s%s╔%s╗%s\n'        "$C_B" "$C_OK" "$bar" "$C_0"
    printf '  %s%s║%s  %s%s║%s\n'  "$C_B" "$C_OK" "$C_0" "$label" "$pad1" "$C_0"
    printf '  %s%s║%s  %s%s%s%s%s║%s\n' "$C_B" "$C_OK" "$C_0" "$C_B" "$url" "$C_0" "$pad2" "$C_OK$C_B" "$C_0"
    printf '  %s%s╚%s╝%s\n'        "$C_B" "$C_OK" "$bar" "$C_0"

    printf '\n  %sЭКРАН «СОЗДАНИЕ БАЗЫ ДАННЫХ»%s\n' "$C_DIM" "$C_0"
    printf '    %sСервер%s ....................  %s%s%s\n'        "$C_DIM" "$C_0" "$C_B" "mysql" "$C_0"
    printf '    %sПользователь базы данных%s ..  %sСуществующий%s\n' "$C_DIM" "$C_0" "$C_B" "$C_0"
    printf '    %sИмя пользователя%s ..........  %sbitrix%s\n'     "$C_DIM" "$C_0" "$C_B" "$C_0"
    printf '    %sПароль%s ....................  %s%s%s\n'        "$C_DIM" "$C_0" "$C_F" "$up" "$C_0"
    printf '    %sБаза данных%s ...............  %sСуществующая%s\n' "$C_DIM" "$C_0" "$C_B" "$C_0"
    printf '    %sИмя базы данных%s ...........  %sbitrix%s\n'     "$C_DIM" "$C_0" "$C_B" "$C_0"

    printf '\n  %sЭКРАН «СОЗДАНИЕ АДМИНИСТРАТОРА»%s\n' "$C_DIM" "$C_0"
    printf '    %sЛогин%s .....................  %s%s%s\n'  "$C_DIM" "$C_0" "$C_B" "$ADMIN_LOGIN" "$C_0"
    printf '    %sПароль%s ....................  %s%s%s\n'  "$C_DIM" "$C_0" "$C_F" "$ADMIN_PW" "$C_0"
    printf '    %sэти два придумываете вы, скрипт их только хранит%s\n' "$C_DIM" "$C_0"

    printf '\n  %sВСЕ ПАРОЛИ РАЗОМ%s\n' "$C_DIM" "$C_0"
    printf '    %sMySQL root%s ................  %s%s%s\n' "$C_DIM" "$C_0" "$C_F" "$rp" "$C_0"
    printf '    %sMySQL bitrix%s ..............  %s%s%s\n' "$C_DIM" "$C_0" "$C_F" "$up" "$C_0"
    printf '    %sАдмин сайта%s ...............  %s%s / %s%s\n' "$C_DIM" "$C_0" "$C_F" "$ADMIN_LOGIN" "$ADMIN_PW" "$C_0"
    printf '    %sФайл с паролями БД%s ........  %s%s/.env_mysql%s\n' "$C_DIM" "$C_0" "$C_B" "$WORK" "$C_0"

    printf '\n  %sПОСЛЕ УСТАНОВКИ%s\n' "$C_DIM" "$C_0"
    printf '    %sСайт%s ......................  %shttp://%s:%s/%s\n'              "$C_DIM" "$C_0" "$C_CY" "$ip" "$PORT" "$C_0"
    printf '    %sАдминка%s ...................  %shttp://%s:%s/bitrix/admin/%s\n' "$C_DIM" "$C_0" "$C_CY" "$ip" "$PORT" "$C_0"
    echo
}

# роль контейнера по имени
role_of() {
    case "$1" in
        *nginx)     echo "веб-сервер, принимает запросы браузера" ;;
        *php)       echo "выполняет код Битрикса" ;;
        *mysql)     echo "база данных" ;;
        *postgres)  echo "вторая база, Битриксом не используется" ;;
        *cron)      echo "агенты и отложенные задачи" ;;
        *redis)     echo "кэш и сессии" ;;
        *memcached) echo "кэш" ;;
        *sphinx)    echo "полнотекстовый поиск" ;;
        *push_sub|*push_pub) echo "уведомления в реальном времени" ;;
        *ssl)       echo "самоподписанные сертификаты" ;;
        *lego)      echo "сертификаты Let’s Encrypt" ;;
        *)          echo "" ;;
    esac
}

show_state() {
    step "Состояние сервера"

    printf '\n  %sDOCKER%s\n' "$C_DIM" "$C_0"
    if command -v docker >/dev/null 2>&1; then
        ok "Установлен: $(docker --version | sed 's/Docker version //; s/,.*//')"
        if systemctl is-active docker >/dev/null 2>&1; then
            ok "Служба работает и включена в автозапуск"
        else
            bad "Служба docker остановлена"
        fi
    else
        info "Не установлен"
        echo; return
    fi

    printf '\n  %sОКРУЖЕНИЕ%s\n' "$C_DIM" "$C_0"
    if [ -d "$WORK" ]; then
        ok "Каталог: $WORK"
    else
        info "Не развёрнуто — установка не запускалась"
        echo; return
    fi

    printf '\n  %sКОНТЕЙНЕРЫ%s  %sстолбец «работает» — сколько времени без перезапуска%s\n' \
           "$C_DIM" "$C_0" "$C_DIM" "$C_0"
    local line name st role
    while IFS='|' read -r name st; do
        [ -z "$name" ] && continue
        role="$(role_of "$name")"
        printf '    %s%-16s%s %s%-16s%s %s%s%s\n' \
               "$C_B" "$name" "$C_0" "$C_OK" "$st" "$C_0" "$C_DIM" "$role" "$C_0"
    done < <(cd "$WORK" && docker compose ps --format '{{.Name}}|{{.Status}}' 2>/dev/null)

    printf '\n  %sСАЙТ%s\n' "$C_DIM" "$C_0"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT}/" 2>/dev/null)
    case "$code" in
        200) ok "Отвечает на порту $PORT — код 200, страница отдаётся" ;;
        403) warn "Код 403: корень сайта пуст, мастер установки ещё не пройден" ;;
        000) bad "Не отвечает на порту $PORT" ;;
        *)   warn "Отвечает кодом $code" ;;
    esac
    local tables
    tables=$(cd "$WORK" && docker compose exec -T mysql mysql -u root \
             -p"$(grep MYSQL_ROOT_PASSWORD "$WORK/.env_mysql" 2>/dev/null | cut -d'"' -f2)" \
             -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='bitrix';" 2>/dev/null)
    if [ "${tables:-0}" -gt 0 ]; then
        ok "В базе bitrix: $tables таблиц — сайт установлен"
    else
        info "База bitrix пуста — Битрикс ещё не установлен"
    fi

    printf '\n  %sМЕСТО НА ДИСКЕ%s\n' "$C_DIM" "$C_0"
    local imgs vols
    imgs=$(docker system df --format '{{.Type}}|{{.Size}}' 2>/dev/null | awk -F'|' '/Images/{print $2}')
    vols=$(docker system df --format '{{.Type}}|{{.Size}}' 2>/dev/null | awk -F'|' '/Volumes/{print $2}')
    printf '    %sсвободно на диске%s ......  %s%s%s\n' "$C_DIM" "$C_0" "$C_B" "$(df -h / | awk 'NR==2{print $4}')" "$C_0"
    printf '    %sобразы Docker%s ..........  %s\n'     "$C_DIM" "$C_0" "${imgs:-?}"
    printf '    %sтома с данными%s .........  %s\n'     "$C_DIM" "$C_0" "${vols:-?}"
    echo
}

remove_bitrix() {
    if [ -f "$WORK/docker-compose.yml" ]; then
        info "Останавливаю контейнеры и стираю тома…"
        (cd "$WORK" && docker compose down -v) >/dev/null 2>&1 || true
    fi
    rm -rf "$ENV_DIR"
    ok "Контейнеры, тома и каталог $ENV_DIR удалены"
}

remove_docker() {
    info "Останавливаю службу…"
    systemctl stop docker docker.socket >/dev/null 2>&1 || true
    systemctl disable docker >/dev/null 2>&1 || true

    info "Удаляю пакеты…"
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y -qq docker-ce docker-ce-cli >/dev/null 2>&1 || true
    apt-get purge -y -qq containerd.io >/dev/null 2>&1 || true
    apt-get purge -y -qq docker-buildx-plugin >/dev/null 2>&1 || true
    apt-get purge -y -qq docker-compose-plugin >/dev/null 2>&1 || true
    apt-get purge -y -qq docker-ce-rootless-extras >/dev/null 2>&1 || true
    apt-get purge -y -qq docker.io containerd >/dev/null 2>&1 || true
    apt-get autoremove -y -qq >/dev/null 2>&1 || true

    info "Удаляю данные, репозиторий и остатки…"
    rm -rf /var/lib/docker /var/lib/containerd
    rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
    ip link delete docker0 >/dev/null 2>&1 || true
    rm -rf /run/docker /run/containerd /var/run/docker.sock
    groupdel docker >/dev/null 2>&1 || true
    apt-get update -qq >/dev/null 2>&1 || true
    ok "Docker удалён"

    step "Проверка, что следов не осталось"
    local left=0
    dpkg -l 2>/dev/null | grep -qE "docker|containerd" && { bad "Остались пакеты"; left=1; } || ok "Пакетов нет"
    command -v docker >/dev/null 2>&1       && { bad "Остался бинарник docker"; left=1; } || ok "Бинарников нет"
    [ -e /var/lib/docker ]                  && { bad "Остался /var/lib/docker"; left=1; } || ok "Каталогов данных нет"
    getent group docker >/dev/null 2>&1     && { bad "Осталась группа docker"; left=1; } || ok "Группы docker нет"
    ip link show docker0 >/dev/null 2>&1    && { bad "Остался мост docker0"; left=1; }   || ok "Моста docker0 нет"
    echo
    if [ "$left" -eq 0 ]; then
        ok "Сервер чистый"
        info "В iptables останутся цепочки DOCKER — они исчезнут при перезагрузке"
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
    printf '  %sy и Enter — продолжить, просто Enter — отмена%s\n' "$C_DIM" "$C_0"
    if ! read -rp "$(printf '  %sПродолжить? [y/N]:%s' "$C_OK" "$C_0") " a; then echo; return; fi
    [[ "${a,,}" == "y" ]] || { info "Отменено."; return; }

    if [ -e "$ENV_DIR" ]; then
        step "Очистка"
        remove_bitrix
    fi

    CHECKS=unknown; INSTALLED=no
    do_checks
    if [ "$CHECKS" != passed ]; then
        echo; bad "Проверка не прошла — установка не запущена, смотрите крестики выше"
        return
    fi

    do_install; local rc=$?
    if [ "$rc" -eq 0 ]; then
        INSTALLED=yes
        printf '\n  %s✓ Переустановка завершена.%s\n' "$C_OK" "$C_0"
        show_params
    elif [ "$rc" -ne 10 ]; then
        bad "Установка прервалась, код $rc — смотрите сообщение выше"
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
        if ! read -rp "$(printf '  %sВыбор (0 — назад):%s' "$C_OK" "$C_0") " c; then echo; return; fi
        case "$c" in
            1) echo
               warn "Будут стёрты контейнеры, тома с базой и сайтом, каталог $ENV_DIR."
               local a
               printf '  %sПередумали — просто нажмите Enter.%s\n' "$C_DIM" "$C_0"
               printf '  %sВведите%s %s%sУДАЛИТЬ%s %sдля подтверждения:%s ' "$C_OK" "$C_0" "$C_B" "$C_NO" "$C_0" "$C_OK" "$C_0"
               read -r a
               [ "$a" = "УДАЛИТЬ" ] || { info "Отменено."; continue; }
               remove_bitrix
               INSTALLED=no; CHECKS=unknown
               return ;;
            2) echo
               warn "Будут стёрты: сайт, база, каталог $ENV_DIR, все пакеты Docker,"
               warn "все образы и тома в /var/lib/docker, репозиторий и ключ."
               warn "Команда rm -rf /var/lib/docker стирает всё хранилище Docker:"
               warn "контейнеры, образы и тома любых других проектов на сервере"
               warn "будут удалены вместе с их данными."
               local a
               printf '  %sПередумали — просто нажмите Enter.%s\n' "$C_DIM" "$C_0"
               printf '  %sВведите%s %s%sУДАЛИТЬ ВСЁ%s %sдля подтверждения:%s ' "$C_OK" "$C_0" "$C_B" "$C_NO" "$C_0" "$C_OK" "$C_0"
               read -r a
               [ "$a" = "УДАЛИТЬ ВСЁ" ] || { info "Отменено."; continue; }
               remove_bitrix
               remove_docker
               INSTALLED=no; CHECKS=unknown
               return ;;
            0) return ;;
            *) bad "Нет такого пункта" ;;
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

    if ! read -rp "$(printf '  %sВыбор:%s' "$C_OK" "$C_0") " choice; then echo; info "Ввод закончился — выход."; echo; exit 0; fi
    case "$choice" in
        1) do_checks; pause ;;
        2) settings_menu ;;
        3) if [ "$CHECKS" != passed ]; then
               bad "Сначала пункт 1 — проверка сервера"
           else
               do_install; rc=$?
               if [ "$rc" -eq 0 ]; then
                   INSTALLED=yes
                   printf '\n  %s✓ Установка завершена. Пункт 5 — параметры для мастера.%s\n' "$C_OK" "$C_0"
                   show_params
               elif [ "$rc" -eq 10 ]; then
                   :
               else
                   bad "Установка прервалась, код $rc — смотрите сообщение выше"
               fi
           fi
           pause ;;
        4) do_reinstall; pause ;;
        5) show_state; pause ;;
        6) if [ "$INSTALLED" = yes ] || [ -f "$WORK/docker-compose.yml" ]; then show_params
           else bad "Установка ещё не выполнена"; fi
           pause ;;
        7) do_remove; pause ;;
        0) echo; info "Выход."; echo; exit 0 ;;
        *) bad "Нет такого пункта" ;;
    esac
done
