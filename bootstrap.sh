#!/usr/bin/env bash
# bootstrap.sh: поднимает проект «Сборщик логов» с нуля (ДЗ2, капстоун).
# Образ и контейнер, RAID 1 + LVM на loop-устройствах, Nginx + TLS, служба systemd.
# Запуск из корня репозитория: ./bootstrap.sh
# Повторный запуск безопасен: готовое не пересоздаётся, данные RAID не затираются.
#
# Используется set -e, но не set -o pipefail: конструкция «yes | mdadm ...» при
# pipefail завершает скрипт с кодом 141 (SIGPIPE), хотя массив уже создан.
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="/mnt/raid-lab"
MDSTAT="${MDSTAT:-/proc/mdstat}"
APT_OPTS="-o DPkg::Lock::Timeout=300"   # ждать, пока unattended-upgrades отпустит замок dpkg

cd "$REPO_DIR"

# --- вспомогательные функции ---------------------------------------------------

# loop-устройство для файла: берём уже подключённое или создаём новое
attach_loop() {
    local existing
    existing="$(sudo losetup -j "$1" -O NAME -n 2>/dev/null | head -n 1)"
    if [ -n "$existing" ]; then
        echo "$existing"
    else
        sudo losetup -fP --show "$1"
    fi
}

mount_if_needed() {   # $1 = устройство, $2 = точка монтирования
    sudo mkdir -p "$2"
    if ! mountpoint -q "$2"; then
        sudo mount "$1" "$2"
    fi
}

raid_is_active() {
    grep -q "^md0 : active" "$MDSTAT"
}

# --- 0. Docker -----------------------------------------------------------------
echo "== 0. Проверка Docker =="
if ! command -v docker > /dev/null 2>&1; then
    sudo apt-get $APT_OPTS update -qq
    sudo apt-get $APT_OPTS install -y -qq docker.io > /dev/null
fi
DOCKER_BIN="$(command -v docker)"
# если текущий пользователь ещё не в группе docker, работаем через sudo
if docker info > /dev/null 2>&1; then
    DOCKER="docker"
else
    DOCKER="sudo docker"
fi

# --- 1. Образ и контейнер --------------------------------------------------------
echo "== 1. Образ и контейнер =="
# если служба уже есть, останавливаем её, чтобы можно было пересоздать контейнер
sudo systemctl stop my-app 2> /dev/null || true
$DOCKER build -t my-script .
$DOCKER rm -f my-app 2> /dev/null || true
$DOCKER create -p 8080:8080 --name my-app -v /var/log:/var/log:ro my-script

# --- 2. RAID 1 и LVM на loop-устройствах ----------------------------------------
echo "== 2. RAID/LVM на loop-устройствах =="
sudo apt-get $APT_OPTS update -qq
sudo apt-get $APT_OPTS install -y -qq mdadm lvm2 > /dev/null
sudo mkdir -p "$LAB_DIR"

if raid_is_active; then
    echo "   RAID-массив уже собран: пересоздание пропущено."
    mount_if_needed /dev/md0 /mnt/raid
    sudo vgchange -ay vg_data > /dev/null 2>&1 || true
    mount_if_needed /dev/vg_data/lv_logs /mnt/logs
elif [ -f "$LAB_DIR/disk1.img" ] && [ -f "$LAB_DIR/disk2.img" ] && [ -f "$LAB_DIR/disk3.img" ]; then
    echo "   Найдены образы дисков (например, после перезагрузки): собираем заново без потери данных."
    sudo mdadm --stop /dev/md0 2> /dev/null || true
    LOOP1="$(attach_loop "$LAB_DIR/disk1.img")"
    LOOP2="$(attach_loop "$LAB_DIR/disk2.img")"
    LOOP3="$(attach_loop "$LAB_DIR/disk3.img")"
    # автосборка ядром может опередить нас: «busy» тогда не ошибка
    sudo mdadm --assemble /dev/md0 "$LOOP1" "$LOOP2" || true
    mount_if_needed /dev/md0 /mnt/raid
    sudo vgchange -ay vg_data
    mount_if_needed /dev/vg_data/lv_logs /mnt/logs
else
    echo "   Чистая машина: создаём диски, RAID 1 и LVM."
    sudo mdadm --stop /dev/md0 2> /dev/null || true
    for n in 1 2 3; do
        sudo dd if=/dev/zero of="$LAB_DIR/disk$n.img" bs=1M count=512 status=none
    done
    LOOP1="$(attach_loop "$LAB_DIR/disk1.img")"
    LOOP2="$(attach_loop "$LAB_DIR/disk2.img")"
    LOOP3="$(attach_loop "$LAB_DIR/disk3.img")"

    yes | sudo mdadm --create /dev/md0 --level=1 --raid-devices=2 "$LOOP1" "$LOOP2"
    sudo mkfs.ext4 -F /dev/md0
    mount_if_needed /dev/md0 /mnt/raid

    yes | sudo pvcreate "$LOOP3"
    sudo vgcreate vg_data "$LOOP3"
    yes | sudo lvcreate -L 200M -n lv_logs vg_data
    sudo mkfs.ext4 -F /dev/vg_data/lv_logs
    mount_if_needed /dev/vg_data/lv_logs /mnt/logs
fi
cd "$REPO_DIR"

# --- 3. Nginx и TLS -------------------------------------------------------------
echo "== 3. Nginx и TLS =="
sudo apt-get $APT_OPTS install -y -qq nginx openssl > /dev/null

if [ ! -f /etc/ssl/certs/my-app.crt ] || [ ! -f /etc/ssl/private/my-app.key ]; then
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/private/my-app.key \
        -out /etc/ssl/certs/my-app.crt \
        -subj "/CN=my-app.local"
fi

# кавычки вокруг NGINXEOF: оболочка не должна подставлять $host и $request_uri
sudo tee /etc/nginx/sites-available/my-app > /dev/null << 'NGINXEOF'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/ssl/certs/my-app.crt;
    ssl_certificate_key /etc/ssl/private/my-app.key;

    location / {
        proxy_pass http://127.0.0.1:8080;
    }
}
NGINXEOF
sudo ln -sf /etc/nginx/sites-available/my-app /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable nginx > /dev/null 2>&1 || true
sudo systemctl restart nginx

# --- 4. Служба systemd ----------------------------------------------------------
echo "== 4. systemd-служба =="
# здесь heredoc без кавычек: нужна подстановка пути к docker
sudo tee /etc/systemd/system/my-app.service > /dev/null << UNITEOF
[Unit]
Description=my-app service
After=docker.service
Requires=docker.service

[Service]
ExecStart=${DOCKER_BIN} start -a my-app
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNITEOF
sudo systemctl daemon-reload
sudo systemctl enable my-app
sudo systemctl start my-app

# --- 5. Самопроверка ------------------------------------------------------------
echo "== 5. Самопроверка =="
printf "Ожидание готовности сервиса"
READY=no
for _ in $(seq 1 15); do
    # -f: ответ 502 считается неудачей, а не успехом
    if curl -ksf -o /dev/null https://127.0.0.1/report.txt; then
        READY=yes
        break
    fi
    printf "."
    sleep 2
done
echo

if [ "$READY" = yes ]; then
    curl -ksI https://127.0.0.1/ | head -n 1
else
    echo "ВНИМАНИЕ: сервис не ответил за 30 секунд."
    echo "Смотрите: sudo systemctl status my-app и docker logs my-app"
fi
cat "$MDSTAT"
df -h | grep -E "raid|logs" || echo "ВНИМАНИЕ: тома RAID/LVM не смонтированы"
systemctl is-enabled my-app
sudo systemctl status my-app --no-pager || true

if [ "$READY" != yes ]; then
    exit 1
fi
echo "bootstrap.sh: готово"
