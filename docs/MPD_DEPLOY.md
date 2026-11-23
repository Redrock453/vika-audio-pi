# MPD + USB: развёртывание офлайн-плеера на Pi 3 A+

Дата: 2026-11-23. Статус: **подготовленный к развёртыванию пакет, на реальном Pi
не запускался**. Это не приёмка MVP из [SPEC.md](SPEC.md): критерии F01–F05
проверяются только на устройстве.

## 0. Честный блокер

На Raspberry Pi пользователь `vika` **не имеет passwordless sudo**. Поэтому:

- все шаги, требующие root (apt, `/etc`, `/usr/local`, systemd, udev, mount),
  выполняются **вручную с интерактивным паролем**;
- агент, подготовивший этот пакет, **не выполнял** установку, ssh, reboot,
  `mount`, не менял `/etc` на Pi и не трогал основную ветку Git;
- `scripts/install.sh` по умолчанию работает в режиме **dry-run** и печатает
  план; изменения выполняются только с `--apply` и только от root.

Это ограничение инфраструктуры, а не дефект пакета. Пока оно не снято
(осознанно, через узкий `sudoers`-файл или ручные шаги), автоматизация
развёртывания остаётся двухфазной: «посмотреть план → ввести пароль».

## 1. Что разворачивается

| Источник в репозитории | Куда устанавливается | Назначение |
| --- | --- | --- |
| `config/mpd.conf` | `/etc/vika-audio/mpd.conf` | MPD: только локальные файлы, ALSA `plughw:0,0`, UNIX-сокет |
| `config/vika-audio.env` | `/etc/vika-audio/vika-audio.env` | пути и политика; создаётся только если файла нет |
| `scripts/lib/media-lib.sh` | `/usr/local/lib/vika-audio/lib/media-lib.sh` | общая логика: плейлисты, resume, USB-детект |
| `scripts/play-source.sh` | `/usr/local/lib/vika-audio/play-source.sh` | переключение `local`/`usb` с восстановлением позиции |
| `scripts/boot-play.sh` | `/usr/local/lib/vika-audio/boot-play.sh` | автозапуск при загрузке |
| `scripts/usb-media.sh` | `/usr/local/lib/vika-audio/usb-media.sh` | read-only mount/unmount, reconcile |
| `scripts/verify.sh` | `/usr/local/sbin/vika-audio-verify` | проверки без root |
| `systemd/vika-audio.service` | `/etc/systemd/system/` | MPD от пользователя `vika` |
| `systemd/vika-audio-usb.service` | `/etc/systemd/system/` | root-задача: mount + переключение |
| `systemd/vika-audio-usb.timer` | `/etc/systemd/system/` | страховка от пропущенных udev-событий |
| `systemd/99-vika-audio-usb.rules` | `/etc/udev/rules.d/` | реакция на вставку/извлечение |
| `docs/MPD_DEPLOY.md` | `/usr/local/share/doc/vika-audio/` | эта инструкция |

Библиотека: `/home/vika/media/music`, `/home/vika/media/audiobooks`, точка
монтирования USB: `/home/vika/media/usb`.

## 2. Требования

- Raspberry Pi 3 Model A+, 512 МиБ RAM, отдельная microSD 64 ГБ.
- Raspberry Pi OS Lite **32-bit Trixie**, без графики.
- Пользователь `vika`, SSH по ключу с доверенной машины (Wi-Fi нужен только
  для первичной настройки, для прослушивания — нет).
- Интерактивный sudo-пароль на время установки.
- Аналоговый выход 3,5 мм (проводные JBL) как основной маршрут.
- Bluetooth (`HD-610`) — **необязателен** и по умолчанию выключен.

Никаких секретов в репозитории и в этом пакете нет: ни Wi-Fi, ни ключей, ни
паролей, ни MAC-адресов.

## 3. Установка (ручные шаги)

Все команды ниже выполняет человек на Pi. Агент их не запускал.

### 3.1. Доставить файлы

```sh
# с T450, без секретов и без аудиоколлекции
rsync -av --exclude .git ./vika-audio-pi/ vika@vika-audio.local:/home/vika/vika-audio-pi/
ssh vika@vika-audio.local
```

### 3.2. Пакеты — вручную

```sh
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    mpd mpc alsa-utils
```

Bluetooth-пакеты (только если решите проверять A2DP):

```sh
sudo apt-get install -y --no-install-recommends \
    bluez bluez-alsa-utils libasound2-plugin-bluez
```

`mpd` в Debian слушает TCP 6600 и работает от `mpd:audio`. Наш сервис
заменяет его; `install.sh` отключает штатный `mpd.service`/`mpd.socket`
(обратимо, без маскирования).

### 3.3. План, затем установка

```sh
cd /home/vika/vika-audio-pi
./scripts/install.sh                 # dry-run: только печать плана
./scripts/install.sh --check         # проверка хоста/репозитория
sudo ./scripts/install.sh --apply --no-apt   # пакеты уже поставлены вручную
```

Если хотите, чтобы apt выполнил сам installer (без upgrade/autoremove):

```sh
sudo ./scripts/install.sh --apply
```

Свойства установщика:

- каждое заменяемое файло сначала копируется в
  `/var/backups/vika-audio/<дата-время>/` с `MANIFEST`;
- повторный запуск с тем же содержимым ничего не меняет;
- `/etc/vika-audio/vika-audio.env` не перезаписывается: локальные настройки
  сохраняются;
- добавляет `vika` в группу `audio`, создаёт каталоги библиотеки;
- не делает `apt upgrade`, `autoremove`, `clean`, не форматирует и не чистит
  носители, не меняет `/etc/fstab`, не открывает портов.

### 3.4. Проверка

```sh
sudo -u vika /usr/local/sbin/vika-audio-verify
sudo -u vika /usr/local/sbin/vika-audio-verify --audio-test   # слышимый тест 3 с
```

`verify.sh` не требует root и ничего не меняет. Он проверяет ОС/RAM, группы,
пакеты, конфиг, systemd, сокет, ALSA card 0, плейлисты, read-only флаг USB,
отсутствие TCP 6600 и политику автозапуска. `FAIL` — реальная проблема,
`WARN` — отклонение от целевой конфигурации, `SKIP` — проверка неприменима.

## 4. Аудиовыход

### 4.1. Аналог — основной

`config/mpd.conf` жёстко выбирает `plughw:0,0` — встроенный 3,5-мм выход,
программный микс, 44,1 кГц/16 бит/стерео (plughw конвертирует остальное).
Это первое и обязательное, что должно работать.

Проверить, что card 0 — именно встроенный выход:

```sh
aplay -l
aplay -L | grep -i plughw
amixer -c 0 sset 'PCM' 80% unmute 2>/dev/null || true
```

Если USB-звуковая карта оказалась card 0, `plughw:0,0` укажет не туда.
В таком случае либо отключите USB-аудио на время, либо (осознанно) замените
`device` на `plughw:CARD=Headphones`. Это изменение конфигурации, а не
автоматика скрипта.

### 4.2. Bluetooth — необязательно

По умолчанию выход Bluetooth выключен и закомментирован. Порядок включения
описан в комментарии `config/mpd.conf`: установить пакеты, сопрячь HD-610,
найти строку через `bluealsa-aplay -L`, раскомментировать блок, перезапустить
сервис и переключить выход через `mpc enable/disable`.

Историческая ошибка `a2dp-sink profile connect failed: Protocol not available`
из SPEC.md **не исправлена этим пакетом**. Уточнение (проверено по исходникам
пакета bluez-alsa 4.3.1-3 в Debian Trixie): штатный `bluealsa.service` уже
запускает демон с `-S -p a2dp-source -p a2dp-sink`, поэтому причина ошибки
не в «отсутствующем `--profile`», а в том, что на момент сопряжения endpoint'ы
A2DP не были зарегистрированы в BlueZ (демон не был активен/не успел) либо
сопряжение устарело. Диагностика по шагам: [BLUETOOTH.md](BLUETOOTH.md).
Пока A2DP не принят, плеер полностью работоспособен на аналоге.

## 5. Библиотека и порядок

- MPD видит только `/home/vika/media`. `music_directory` не выходит за него.
- Локальный плейлист собирается из `music/` и `audiobooks/` **заново** при
  каждом выборе источника, порядок — побайтовая сортировка (`LC_ALL=C`) по
  пути внутри библиотеки. Он не зависит от локали, порядка каталогов и
  времени копирования.
- Поддерживаемые расширения: `mp3 flac ogg oga opus m4a m4b aac wav wave aif
  aiff wma wv ape` (регистр не важен). Остальное игнорируется, не удаляется.
- Пропускаются скрытые файлы/каталоги, `._*`, имена с переводом строки,
  `\r`, обратным слешем, абсолютные пути и симлинки. Это защита от
  повреждения построчного m3u, а не цензура коллекции.
- Добавили файлы — перезагрузка или
  `sudo -u vika /usr/local/lib/vika-audio/play-source.sh local` пересоберёт
  плейлист. `auto_update` в MPD выключен, чтобы не сканировать карту постоянно.
- Формат m3u — обычные строки `music/...`, `audiobooks/...`, `usb/...`
  относительно `music_directory`.

## 6. USB-флешка

### 6.1. Что считается кандидатом

- раздел (`TYPE=part`) на USB-шине (`TRAN=usb`), со съёмным флагом (`RM=1`)
  или с родительским диском на USB (USB SSD/картридер без removable-флага);
- файловая система: `vfat`, `exfat`, `ext2/3/4`, `ntfs/ntfs3`, `iso9660`;
- диск, на котором лежит `/`, **исключается всегда**, включая загрузку с USB;
- если кандидатов несколько и ни один не помечен `VIKA_AUDIO`, монтирование
  **отказывается** с внятной ошибкой: угадывание здесь опаснее бездействия.

Чтобы закрепить конкретную флешку:

```sh
# вариант 1: метка
sudo fatlabel /dev/sdX1 VIKA_AUDIO     # только осознанно, меняет метку
# вариант 2: путь устройства в /etc/vika-audio/vika-audio.env
VIKA_USB_DEVICE="/dev/disk/by-label/VIKA_AUDIO"
```

### 6.2. Монтирование только для чтения

`usb-media.sh` монтирует с `ro,nosuid,nodev,noexec,noatime` (для vfat/exfat/ntfs
дополнительно `umask=0022`, чтобы `vika` мог читать). После монтирования флаг
`ro` **проверяется** через `findmnt`; если его нет — немедленный `umount` и
ошибка. Проверяется и читаемость каталога пользователем `vika`.

На носитель ничего не пишется: нет `fsck`, нет форматирования, нет создания
каталогов, нет переименований. `umount` при занятости делает несколько
попыток и затем **lazy**-unmount; `umount -f` не используется.

Для `ext4` права файлов остаются как есть. Если `vika` не может читать
каталог, монтирование отменяется с подсказкой использовать FAT32/exFAT —
это ожидаемое ограничение, а не скрытая эскалация прав.

### 6.3. Вставка и извлечение

1. udev (правило `99-vika-audio-usb.rules`) или таймер запускает
   `vika-audio-usb.service`;
2. `usb-media.sh reconcile` идемпотентно: если ничего не изменилось — no-op,
   без остановки текущего воспроизведения;
3. при появлении: mount read-only → маркер
   `/var/lib/vika-audio/state/usb.active` → `play-source.sh usb` от имени
   `vika`;
4. при извлечении: `play-source.sh local` (сохраняет позицию USB и
   восстанавливает локальную) → `umount` → маркер удаляется.

Порядок файлов на флешке — тот же побайтовый (`usb/A.flac`, `usb/b.mp3`,
`usb/nested/C.ogg`). Неаудио игнорируется. Пустая флешка не очищает текущую
очередь: `play-source.sh` возвращает код 4, локальное воспроизведение
продолжается, монтирование остаётся (без цикла перезапусков).

Таймер `vika-audio-usb.timer` (первый запуск через 25 с после boot, далее раз
в 60 с после завершения предыдущего) — страховка, если udev-событие потеряно.
Скрипт при отсутствии изменений не пишет на SD-карту и не вмешивается в звук.

### 6.4. Возобновление после извлечения

Состояние хранится в `/var/lib/vika-audio/state/`:

| Файл | Содержимое |
| --- | --- |
| `local.resume` | URI трека и позиция в секундах |
| `usb.resume` | URI трека и позиция в секундах |
| `last-source` | `local` или `usb` |
| `usb.active` | устройство и ФС смонтированной флешки |

При переключении источника скрипт сначала сохраняет позицию текущего, затем
загружает новый плейлист, выбирает сохранённый трек по URI, ставит паузу,
делает `seek` (чтобы не было слышимого скачка с начала) и только потом
возобновляет. После извлечения флешки локальная книга продолжается с
сохранённого места. Это же работает после перезагрузки.

## 7. Автозапуск при загрузке

`vika-audio.service` запускает MPD, затем `boot-play.sh`:

1. ждёт UNIX-сокет MPD (до 60 с);
2. если флешка уже смонтирована — выбирает USB;
3. если флешка присутствует, но mount ещё идёт — ждёт до 15 с;
4. иначе — локальная библиотека с восстановлением позиции.

`VIKA_BOOT_AUTOPLAY=1` (по умолчанию) — играть сразу, как просили.
`VIKA_BOOT_AUTOPLAY=0` — восстановить очередь и остаться на паузе (более
консервативно, ближе к SPEC F05). Меняется в
`/etc/vika-audio/vika-audio.env` + `sudo systemctl restart vika-audio`.

Отсутствие медиа — это не ошибка: плеер остаётся в `IDLE`, сервис не
перезапускается по кругу.

## 8. Сеть, порты, приватность

- По умолчанию MPD слушает **только UNIX-сокет** `/run/vika-audio/mpd.sock`;
  TCP-порт не открывается. `verify.sh` проверяет, что на 6600 никто не
  слушает, если только LAN-доступ не включён явно (см. ниже).
- **Управление с телефона (MALP/MPDroid).** На конкретном Pi создаётся
  локальный файл (в git не попадает):

  ```sh
  # /etc/vika-audio/mpd.local.conf
  bind_to_address "0.0.0.0"
  ```

  и в `/etc/vika-audio/mpd.conf` должна быть строка
  `include_optional "/etc/vika-audio/mpd.local.conf"` (install.sh её ставит).
  Файл должен быть читаем пользователю `vika`: `chown root:vika`,
  `chmod 0640` — иначе MPD не стартует (`Permission denied`).
  После `systemctl restart vika-audio` проверка: `ss -ltnp | grep 6600`.

  В MALP: сервер `10.217.127.59` (или `vika-audio.local`), порт `6600`,
  пароль пустой. Порт доступен только в домашней сети; Pi не публикует его
  в интернет и не требует Wi-Fi для локального воспроизведения. Пароля нет:
  любой в той же сети может управлять плеером.
- Штатный `mpd.service` отключается, иначе он занял бы 6600 и `/var/lib/mpd`.
- Сервис не требует Wi-Fi/Ethernet: в unit нет сетевых зависимостей.
- MPD работает от `vika`, с `ProtectHome=read-only`, `ProtectSystem=strict`,
  `NoNewPrivileges`, приватным `/tmp` и записью только в
  `/var/lib/vika-audio` и `/run/vika-audio`.
- Wi-Fi-пароли, SSH-ключи, MAC-адреса и аудиоколлекция в репозиторий не
  попадают (см. `.gitignore`).

## 9. Эксплуатация

```sh
# состояние
sudo -u vika /usr/local/sbin/vika-audio-verify
sudo -u vika /usr/local/lib/vika-audio/usb-media.sh status

# ручное управление (от vika, сокет)
export MPD_HOST=/run/vika-audio/mpd.sock
mpc status
mpc pause; mpc play
mpc seek +30
mpc volume 70

# переключить источник вручную
sudo -u vika /usr/local/lib/vika-audio/play-source.sh local
sudo -u vika /usr/local/lib/vika-audio/play-source.sh usb

# логи
journalctl -u vika-audio -b --no-pager
journalctl -u vika-audio-usb -b --no-pager
```

`mpc` без `MPD_HOST` попытается подключиться к TCP `localhost:6600` и не
найдёт MPD — это ожидаемо, порт не открыт.

## 10. Откат

```sh
sudo systemctl disable --now vika-audio-usb.timer vika-audio.service
sudo systemctl disable --now vika-audio-usb.service 2>/dev/null || true
sudo systemctl daemon-reload
# вернуть файлы из /var/backups/vika-audio/<дата>/ по MANIFEST
# при необходимости вернуть штатный MPD:
sudo systemctl enable --now mpd.service
```

Точка монтирования после `umount` снова пустой каталог; данные на флешке не
затрагиваются.

## 11. Диагностика

| Симптом | Что проверить |
| --- | --- |
| `mpc: Connection refused` | `systemctl status vika-audio`, `ls -l /run/vika-audio/mpd.sock`, `journalctl -u vika-audio -b` |
| Нет звука на аналоге | `aplay -l`, `amixer -c 0`, `verify.sh --audio-test`, не занят ли card 0 другим сервисом |
| `plughw:0,0` не тот выход | USB-аудио стало card 0; отключить его или использовать `plughw:CARD=Headphones` |
| USB не монтируется | `sudo -u vika .../usb-media.sh status`, `lsblk -o NAME,RM,TRAN,FSTYPE`, несколько разделов без метки `VIKA_AUDIO` |
| USB смонтирован, но «не читается» | ext4-права; переформатировать флешку в exFAT/FAT32 (осознанно), либо `VIKA_USB_DEVICE` на правильный раздел |
| После извлечения играет не то место | проверить `state/local.resume` и `journalctl -u vika-audio-usb` |
| Служба перезапускается по кругу | `systemctl status vika-audio`, `TimeoutStartSec`, занятый ALSA-устройство, битый конфиг |
| USB смонтирован, но MPD его «не видит» | сандбокс systemd (`ProtectHome`/`ProtectSystem`) создаёт mount namespace; проверить `sudo -u vika ls /home/vika/media/usb`, при необходимости убрать `ProtectHome=read-only`/`ProtectSystem=strict` из unit и перезапустить сервис |
| Bluetooth: `Protocol not available` | отдельная задача; аналог должен работать независимо |
| Флешка определяется как sda, но система грузится с неё | защита `vika_is_root_device` исключит её; это ожидаемо |

## 12. Тесты на T450 (без Pi)

```sh
cd vika-audio-pi
./tests/run-tests.sh
```

Проверяется: синтаксис всех скриптов, инварианты `mpd.conf`/unit/udev, политика
установщика, отсутствие wildcard-портов и credentials, а также функциональные
сценарии на fake-`mpc`, fake-`lsblk` и fake-`findmnt`:

- детерминированный порядок и фильтрация расширений (локально и USB);
- сохранение/восстановление позиции, включая `seek` после `pause`;
- пустая флешка не ломает текущую очередь;
- переключение USB → local с восстановлением книги;
- boot-политика `autoplay` / `paused` и «нет медиа — не ошибка»;
- отказ при нескольких кандидатах и при диске, несущем `/`.

Тесты не требуют root, MPD, звука и сети. `shellcheck` и
`systemd-analyze verify` выполняются, если установлены; иначе `SKIP`.

## 13. Что ещё не проверено (честно)

1. Пакет **не запускался** на Pi: нет подтверждения звука, автозапуска и
   реального mount.
2. Нет passwordless sudo у `vika` — установка требует ручного пароля.
3. Индекс ALSA card 0 может измениться при подключении USB-аудио; проверять
   `aplay -l` после каждого нового устройства.
4. A2DP/HD-610 не принимался; Bluetooth-выход выключен.
5. Расход RAM/CPU MPD на этой карте не измерен; `max_output_buffer_size`
   выставлен консервативно (4096 КиБ) без бенчмарка.
6. Поведение при внезапной потере питания (F03) и точность ±5 с (F02)
   проверяются только на устройстве.
7. `mpc update --wait` поддерживается современным `mpc`; при отсутствии
   скрипт деградирует до `update` + короткая пауза, это отражено в коде.
8. Кнопки, микрофон, TTS и STT в этот пакет не входят.
9. Позиция трека передаётся в `mpc play <N>` как 0-based индекс MPD; на T450
   `mpc` отсутствует, поэтому семантика проверяется в чек-листе на Pi
   (пункт «вставка флешки»: трек должен совпасть с сохранённым, не съехать на
   один). При расхождении правится одна строка в `vika_restore_source`.
10. Проброс динамического mount в mount namespace песочницы systemd
    (`ProtectHome`/`ProtectSystem`) проверяется на месте; диагностика и
    обходной путь описаны в таблице раздела 11.
11. Флешка без таблицы разделов (файловая система на всём диске, `TYPE=disk`)
    автоопределением не подхватывается; для неё нужно явно задать
    `VIKA_USB_DEVICE` в `/etc/vika-audio/vika-audio.env`. Обычные флешки с
    разделом (sdb1) поддерживаются автоматически.

## 14. Приёмка на реальном Pi (чек-лист)

- [ ] `verify.sh` без `FAIL`.
- [ ] `--audio-test`: тон слышен в проводных JBL, без хрипа.
- [ ] 30 минут MP3 офлайн, Wi-Fi выключен (F01).
- [ ] reboot: очередь и позиция восстановлены, отклонение ≤5 с (F02).
- [ ] `kill -9` MPD / потеря питания: потеря позиции ≤30 с (F03).
- [ ] play/pause и громкость без экрана/телефона (F04/F08 — кнопки отдельно).
- [ ] 10 перезагрузок без цикла автозапуска (F05).
- [ ] вставка флешки: играет `usb/...`, порядок совпадает с `sort`.
- [ ] извлечение: возврат к локальной книге с сохранённого места.
- [ ] флешка после работы: `mount | grep usb` показывает `ro`, файлы не
      изменены (сверить `find -newer` до/после).
- [ ] `ss -ltn` не содержит 6600.
- [ ] `systemctl restart vika-audio` не оставляет висящих процессов.

Только после этого пакет можно считать принятым; успешная установка пакетов
приёмкой не является (см. `docs/PLAN.md`, Gates).
