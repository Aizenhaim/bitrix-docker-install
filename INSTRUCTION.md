# Битрикс в Docker на Ubuntu

Установка демосайта «1С-Битрикс: Управление сайтом» в окружении `bitrix-tools/env-docker`. Восемь шагов, пройдены на чистом сервере.

Проверено 19.10.2026 · Docker 29.9.1 · 11 контейнеров · порт сайта 8588 · места нужно от 10 ГБ

## Прежде чем начать

Нужен сервер с Ubuntu 24.04, 4 ГБ RAM, от 10 ГБ свободного места и доступ по SSH под root. Все команды выполняются на сервере.

**Два вида блоков.** Блоки с командами копируйте в терминал целиком и смотрите на вывод. Блоки с пометкой `[ФАЙЛ]` или `[В БРАУЗЕРЕ]` — это содержимое файла или адрес, в терминал их вставлять нельзя.

Копируйте блок целиком, а не по строчке: при переносе длинной строки теряется дефис, и `apt` отвечает `Unable to locate package`, не сделав ничего.

## Шаг 1. Подключение и подготовка системы

На своём компьютере откройте терминал (в Windows — PowerShell) и подключитесь, подставив адрес сервера:

```bash
ssh root@<IP-адрес_сервера>
```

Пароль при вводе не отображается — это нормально. После входа приглашение станет вида `root@имя-сервера:~#`.

```bash
apt update && apt upgrade -y
apt install -y ca-certificates curl gnupg git unzip
```

Если в конце появилось **Pending kernel upgrade** — перезагрузитесь сейчас, до установки Docker: `reboot`. Позже перезагрузка оборвёт работающие контейнеры.

## Шаг 2. Установка Docker

Снести старые версии из репозиториев Ubuntu:

```bash
for pkg in docker.io docker-doc docker-compose \
           docker-compose-v2 podman-docker \
           containerd runc; do
  apt-get remove -y $pkg
done
```

Ключ и репозиторий Docker:

```bash
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt update
```

Установка и автозапуск:

```bash
apt install -y docker-ce docker-ce-cli containerd.io
apt install -y docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
```

Проверка:

```bash
docker --version && docker compose version
```

Должны появиться две строки с версиями.

## Шаг 3. Скачивание и распаковка окружения

```bash
mkdir -p ~/1c-bitrix
cd ~/1c-bitrix
wget https://github.com/bitrix-tools/env-docker/archive/refs/heads/main.zip
unzip main.zip
cd ~/1c-bitrix/env-docker-main
```

Архив весит 693 МБ. Без `unzip` каталог `env-docker-main` не появится, и все следующие шаги будут падать.

```bash
ls -la ~/1c-bitrix/env-docker-main/docker-compose.yml
```

Команда должна показать строку с файлом.

## Шаг 4. Пароли базы данных

**Только до первого запуска.** Пароли читаются один раз — когда создаётся том с базой. Правка файла после запуска не применится, даже после `restart`.

Придумайте два пароля — для `root` и для пользователя сайта `bitrix`. Только латиница и цифры, от 16 символов, без кириллицы и без `$ " ' \ ` `. Можно сгенерировать:

```bash
echo "root:   $(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
echo "bitrix: $(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
```

Впишите их в файл, подставив свои значения вместо `ROOT_PW` и `USER_PW`:

```bash
cd ~/1c-bitrix/env-docker-main
sed -i 's/CHANGE_MYSQL_ROOT_PASSWORD_HERE/ROOT_PW/' .env_mysql
printf 'MYSQL_DATABASE=bitrix\n' >> .env_mysql
printf 'MYSQL_USER=bitrix\n' >> .env_mysql
printf 'MYSQL_PASSWORD="USER_PW"\n' >> .env_mysql
```

Три нижние строки создадут базу `bitrix` и одноимённого пользователя при первом запуске. В окружении их нет, они дописываются вручную.

```bash
cat ~/1c-bitrix/env-docker-main/.env_mysql
```

Должны быть видны ваши пароли и все пять строк. Если осталось `CHANGE_..._HERE` или `ROOT_PW` — команда выполнена дважды или без подстановки; исправьте файл в `nano`.

## Шаг 5. Правка compose-файла

Две правки до запуска: убрать PostgreSQL и отключить порт 80 у контейнера `lego`.

### Убрать PostgreSQL

Окружение поднимает две базы, Битриксу нужна одна. Лишняя занимает 640 МБ образа и память.

```bash
cd ~/1c-bitrix/env-docker-main
cp docker-compose.yml docker-compose.yml.bak
sed -i '107,150s/^/#/' docker-compose.yml
sed -i '233s/^/#/' docker-compose.yml
```

Первая `sed` комментирует блок сервиса `postgres`, вторая — строку `- postgres` в зависимостях `php`. Без второй Compose откажется запускаться.

### Отключить порт 80 у lego

Контейнер `lego` занимает порт 80. Если на сервере уже есть веб-сервер, запуск оборвётся ошибкой `address already in use`. Для сайта по IP этот контейнер не нужен.

```bash
sed -i '463,464s/^/#/' docker-compose.yml
docker compose config -q && echo "файл в порядке"
```

Номера строк — для версии окружения от 16.10.2026. Проверить, что закомментировалось именно нужное:

```bash
grep -n -A9 "^  lego:" docker-compose.yml
```

`[ФАЙЛ]` — так должно выглядеть:

```yaml
  lego:
    image: quay.io/bitrix24/lego:4.35.2-v1-alpine
    container_name: dev_lego
    restart: unless-stopped
    env_file:
      - .env
#    ports:
#      - "80:80"
```

## Шаг 6. Запуск контейнеров

```bash
cd ~/1c-bitrix/env-docker-main
docker compose up -d
```

Первый запуск качает около 3,3 ГБ образов — от 5 до 15 минут. Прерывать не нужно.

```bash
docker compose ps
```

Должны подняться 11 контейнеров со статусом `Up`. Если какой-то в `Exited` или `Restarting` — смотрите его лог, подставив имя сервиса:

```bash
docker compose logs --tail=50 mysql
```

В логе MySQL при первом запуске нормальны: создание `root@localhost` с пустым паролем, остановка и повторный старт, пропуск файлов часовых поясов. Важна последняя строка — `ready for connections`.

## Шаг 7. Установщик в браузере

Скрипт установки кладётся в корень сайта **внутри контейнера**, под пользователем `bitrix`.

```bash
cd ~/1c-bitrix/env-docker-main
docker compose exec --user=bitrix php sh
```

Приглашение сменится на `/opt/www $` — вы внутри.

```bash
cd /opt/www/
wget https://www.1c-bitrix.ru/download/scripts/bitrixsetup.php
exit
```

**wget — до exit.** Скачивать нужно, пока приглашение выглядит как `/opt/www $`. После `exit` вы снова на сервере, и файл ляжет не туда — браузер его не увидит.

```bash
docker compose exec php ls /opt/www/
```

Откройте в браузере `http://<IP-адрес_сервера>:8588/bitrixsetup.php` и пройдите мастер: демоверсия «Управление сайтом» редакция «Бизнес» → принять лицензию → **снять** галочку регистрации → предварительная проверка → база данных → администратор сайта → решение «Интернет-магазин» → шаблон по умолчанию.

### Экран «Создание базы данных»

Два поля подставлены неверно, их надо затереть и вписать своё:

| Поле | Подставлено | Вписать |
| --- | --- | --- |
| Сервер | `localhost` | **`mysql`** |
| Пользователь базы данных | Существующий | оставить |
| Имя пользователя | пусто | **`bitrix`** |
| Пароль | пусто | значение `MYSQL_PASSWORD` |
| База данных | Существующая | оставить |
| Имя базы данных | `sitemanager` | **`bitrix`** |
| Права на файлы и папки | 0644 и 0755 | оставить |

В поле «Сервер» именно слово `mysql`: база живёт в соседнем контейнере, и для Битрикса `localhost` — это он сам, пустое место.

На экране «Создание администратора» заводится вход в админку — это отдельный пароль, не от базы. Запишите логин и пароль сразу: восстановление идёт по почте, а отправка писем на сервере не настроена.

Установка решения идёт несколько минут с полосой прогресса. Страницу не перезагружайте.

## Шаг 8. Проверка и уборка

`[В БРАУЗЕРЕ]`:

```
http://<IP-адрес_сервера>:8588/
http://<IP-адрес_сервера>:8588/bitrix/admin/
```

Вход в админку — по логину и паролю администратора с шага 7.

Когда сайт открылся, удалите установщик: он лежит в открытом доступе и позволяет запустить установку заново.

```bash
cd ~/1c-bitrix/env-docker-main
docker compose exec --user=bitrix php rm /opt/www/bitrixsetup.php
```

Архив окружения тоже можно убрать, освободится 693 МБ:

```bash
rm ~/1c-bitrix/main.zip
```

## Если что-то пошло не так

Здесь только то, на что натыкаются в реальности.

| Что видно | Что произошло | Что делать |
| --- | --- | --- |
| `no configuration file provided: not found` | Команда запущена не в каталоге окружения, или архив не распакован | `unzip main.zip`, затем `cd ~/1c-bitrix/env-docker-main` |
| `Unable to locate package docker-composeplugin` | Длинная строка разорвалась при копировании и потеряла дефис. `apt` при этом не сделал ничего | Скопировать блок заново целиком |
| `failed to bind host port 0.0.0.0:80/tcp` | Порт 80 занят другим веб-сервером, `lego` не смог встать | Шаг 5, отключение порта у `lego` |
| Страница на :8588 отдаёт **403** | Корень сайта пуст — `bitrixsetup.php` не скачан или лёг не туда | Шаг 7, скачивание до `exit` |
| `rm: can't remove … No such file or directory` | Файл не в контейнере, а на сервере: `wget` выполнен после `exit` | Удалять без `docker compose exec`: `rm ~/1c-bitrix/env-docker-main/имя.php` |
| `hostname: unrecognized option: I` | Команда для сервера выполнена внутри контейнера | Выйти: **Ctrl+D** или `exit` с Enter |
| Мастер не принимает пароль из env-файла | Пароль поменян после первого запуска, или в нём типографские кавычки | Пересоздать тома, см. ниже |

## Переустановка и удаление

### Поставить заново с нуля

**Стирает сайт и базу.** Флаг `-v` удаляет тома: файлы сайта, базу, кэши. Отменить нельзя. Пароли в env-файлах можно оставить прежние — тома создадутся заново и подхватят их.

```bash
cd ~/1c-bitrix/env-docker-main
docker compose down -v
docker compose up -d
```

Дальше повторяются шаги 7 и 8.

### Снести Docker с сервера полностью

```bash
cd ~/1c-bitrix/env-docker-main
docker compose down -v

systemctl stop docker docker.socket
systemctl disable docker

apt purge -y docker-ce docker-ce-cli
apt purge -y containerd.io
apt purge -y docker-buildx-plugin
apt purge -y docker-compose-plugin
apt purge -y docker-ce-rootless-extras
apt purge -y docker.io containerd
apt autoremove -y
```

Пакеты удаляются по одному-два: одной длинной строкой `apt` спотыкается на переносе и не делает ничего.

```bash
rm -rf /var/lib/docker /var/lib/containerd
rm -f /etc/apt/sources.list.d/docker.list
rm -f /etc/apt/keyrings/docker.asc
ip link delete docker0
rm -rf /run/docker /run/containerd /var/run/docker.sock
groupdel docker
rm -rf ~/1c-bitrix
apt update
```

Проверка — все команды должны ответить пустотой:

```bash
dpkg -l | grep -E "docker|containerd"
command -v docker dockerd containerd runc ctr
ls -d /var/lib/docker /etc/docker /run/docker
getent group docker
ip link show docker0
```

Останутся только цепочки `DOCKER` в `iptables`. Они нигде не сохраняются и исчезают при перезагрузке.
