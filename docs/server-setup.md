# Конфигурация виртуальной машины devops-vm

Хостовая система — MacBook Air (Apple Silicon, macOS 15). VirtualBox 7.2 на Apple Silicon
не загружает Ubuntu Server (ядро зависает на ранней стадии), поэтому машина развёрнута
в гипервизоре **UTM 4 (QEMU, ускорение Hypervisor.framework)**. Гостевая ОС — Ubuntu Server
24.04.5 LTS для arm64.

Восстановление со снимка `01-clean-install` выполняется командами разделов 4–6 по порядку.
Все команды на сервере — от имени `student` (до раздела 4) или `devops`.

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Наименование | devops-vm |
| Гипервизор | UTM, бэкенд QEMU, архитектура aarch64, UEFI |
| ОЗУ | 2048 МБ |
| Ядра ЦП | 2 |
| Диск | 25 ГБ, qcow2 (динамически расширяемый), VirtIO |
| Установка | Ubuntu Server (не minimized), весь диск, OpenSSH server, без snaps |
| Имя узла | devops-vm (FQDN devops-vm.devops.local) |

## 2. Сетевые интерфейсы

| Интерфейс | Тип адаптера UTM | Адрес | Назначение |
|---|---|---|---|
| enp0s1 | Emulated VLAN (аналог NAT VirtualBox) | 10.0.2.15/24 (DHCP) | Доступ в Интернет, проброс SSH |
| enp0s2 | Host Only | 192.168.56.2/24 (DHCP) | Доступ с хоста напрямую, имя devops.local |

Шлюз хоста в сегменте Host-only — 192.168.56.1.

## 3. Правило проброса портов

Адаптер 1 (Emulated VLAN), протокол TCP: `127.0.0.1:2222` (хост) → порт гостя `2222`.
До усиления SSH (раздел 5) порт гостя был `22`. В UTM правило меняется только
у выключенной машины (Edit → Network → Port Forward).

## 4. Учётные записи

| Имя | Группы | Аутентификация по SSH |
|---|---|---|
| student | student, adm, cdrom, sudo, dip, plugdev, lxd | запрещена (`AllowUsers devops`) |
| devops | devops, sudo, users | только по ключу `~/.ssh/devops_vm` (ed25519) |

```bash
# [VM, student]
sudo adduser devops
sudo usermod -aG sudo devops
# [Хост]
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
```

На хосте в `~/.ssh/config`:

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

Права на сервере: `~/.ssh` — 700, `~/.ssh/authorized_keys` — 600.

## 5. Служба SSH

Основной файл `/etc/ssh/sshd_config` не изменяется (копия — `sshd_config.backup`).
Дополняющий файл `/etc/ssh/sshd_config.d/99-hardening.conf`:

```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

В `/etc/ssh/sshd_config.d/50-cloud-init.conf` строка `PasswordAuthentication yes`
закомментирована: файл читается раньше `99-hardening.conf`, и действует первое значение.

```bash
sudo sed -i 's/^PasswordAuthentication yes/#PasswordAuthentication yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf
sudo sshd -t && echo "Конфигурация корректна"
sudo systemctl disable --now ssh.socket     # иначе порт задаёт юнит сокета (22)
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd                   # 0.0.0.0:2222
```

Изменения проверяются новым подключением из второго терминала, не закрывая текущую сессию:
`ssh -i ~/.ssh/devops_vm -p 2222 devops@192.168.56.2` (через Host-only, пока проброс ещё на 22).
Затем машина выключается, проброс переводится на порт гостя 2222 (раздел 3).

## 6. Правила межсетевого экрана

Политики: `deny (incoming)`, `allow (outgoing)`, `disabled (routed)`; журнал — `medium`.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'   # правило создаётся ДО ufw enable
sudo ufw allow 80/tcp  comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw logging medium
```

| Порт | Действие | Комментарий |
|---|---|---|
| 2222/tcp (v4, v6) | LIMIT IN | SSH rate-limited |
| 80/tcp (v4, v6) | ALLOW IN | HTTP |
| 443/tcp (v4, v6) | ALLOW IN | HTTPS |

`ufw allow ssh` не используется: имя `ssh` по `/etc/services` означает порт 22.

## 7. Снимки состояния

| Наименование | Момент создания |
|---|---|
| 01-clean-install | После установки ОС и `apt upgrade`, машина выключена |
| 02-keys-configured | После создания devops, ключа и `~/.ssh/config` |
| 03-ssh-hardened | После усиления SSH и перевода проброса на 2222 |
| 04-nginx-https | После установки Nginx и перевода ресурса на HTTPS (ПР № 6) |
| 05-docker-compose | После запуска проекта «приложение + СУБД» (ПР № 7) |

Имя `devops.local` задаётся на хосте в `/etc/hosts`: `192.168.56.2   devops.local`.
FQDN сервера: `sudo hostnamectl set-hostname devops-vm` и
`sudo sed -i 's/^127.0.1.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts`.

## 8. Веб-сервер

| Параметр | Значение |
|---|---|
| Пакет | `nginx` 1.24.0 из репозитория Ubuntu (`sudo apt install -y nginx`) |
| Конфигурация ресурса | `/etc/nginx/sites-available/devops-site`, ссылка в `sites-enabled/`; `sites-enabled/default` удалена (сам файл в `sites-available/` сохранён) |
| Каталог ресурса | `/var/www/devops-site`, владелец `devops:devops`, каталоги 755, файлы 644 |
| Сертификат | `/etc/ssl/certs/devops.crt`, `root:root`, 644, CN и SAN `DNS:devops.local` |
| Закрытый ключ | `/etc/ssl/private/devops.key`, `root:root`, 600 |
| Срок действия | 365 дней |
| Журналы | `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log` |
| Доставка | `scripts/deploy.sh` (rsync `--delete --chmod=D755,F644`, проверка `curl --cacert`) |

```bash
sudo mkdir -p /var/www/devops-site && sudo chown -R devops:devops /var/www/devops-site
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" -addext "subjectAltName=DNS:devops.local"
```

`/etc/nginx/sites-available/devops-site`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;

    ssl_certificate     /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /var/www/devops-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    error_page 404 /404.html;

    access_log /var/log/nginx/devops-site.access.log;
    error_log  /var/log/nginx/devops-site.error.log;
}
```

```bash
sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
# [Хост] сертификат для проверки без -k
scp devops:/etc/ssl/certs/devops.crt ~/devops.crt
```

На хосте macOS для доставки нужен GNU rsync (`brew install rsync`): системный `/usr/bin/rsync` —
это openrsync, который не поддерживает `--chmod`.

Снимок состояния `04-nginx-https` создан после перевода ресурса на HTTPS.

## 9. Контейнеризация

| Параметр | Значение |
|---|---|
| Docker Engine | 29.9.2 из официального репозитория `download.docker.com` (пакеты `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`); `docker.io` не используется |
| Группа docker | только `devops` (у него есть sudo — группа docker фактически даёт права root) |
| Проект на сервере | `/home/devops/app` (доставляется `rsync -avz --delete --exclude=.env app/ devops:app/`) |
| Файл секретов | `/home/devops/app/.env`, владелец devops, права 600, создаётся только на сервере из `.env.example` |
| Образы | `devops-app:1.0` (python:3.12-slim, пользователь `app`), `postgres:16-alpine` |
| Публикация портов | приложение `127.0.0.1:5000:5000`; порт СУБД 5432 не публикуется |
| Сеть | пользовательская сеть `app_backend` (bridge), СУБД доступна по имени `db` |
| Том | `app_db_data` → `/var/lib/postgresql/data` |
| Обратный прокси | `location /app/` в блоке HTTPS `devops-site` → `proxy_pass http://127.0.0.1:5000/` |

Установка (по инструкции docs.docker.com/engine/install/ubuntu):

```bash
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources <<EOT
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOT
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker devops      # затем новая SSH-сессия
```

Запуск проекта:

```bash
cd ~/app
cp .env.example .env && chmod 600 .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
docker compose up -d --build
```

Фрагмент блока HTTPS в `/etc/nginx/sites-available/devops-site`:

```nginx
    location /app/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
```

Снимок состояния `05-docker-compose` создан после запуска проекта (ПР № 7).
