# OSS: исследование готовых решений

Срез: 2026-11-23. Ссылки — первичные страницы проектов. **Без установки на реальный Pi, результатов бенчмарков пока нет.** Нельзя автоматически считать совместимыми с Raspbian Trixie / Pi 3 A+ 512 МБ.

| Решение | Заявленные возможности | Достоинства | Что мешает готовому внедрению |
| --- | --- | --- | --- |
| [One Button Audiobook Player](https://github.com/mganthon/theonebuttonaudiobookplayer) | Raspberry Pi, максимально простой аудиоплеер, управление одной кнопкой | Образец простого UX | По описанию предназначен для **одной** аудиокниги, нужен форк для библиотеки, форматов и Bluetooth; состояние поддержки проверить |
| [Phoniebox / RPi-Jukebox-RFID](https://github.com/MiczFlor/RPi-Jukebox-RFID) | Локальная музыка, аудиокниги/плейлисты, подкасты, GPIO/RFID и web UI | Наиболее зрелый набор пользовательских функций | Значительный объём компонентов; документация установок ориентирована на Bookworm/Legacy, Trixie и 512 МБ потребуют отдельного пилота |
| [Lauschkiste](https://github.com/ladidadida/lauschkiste) | Аудиокниги, музыка, подкасты, офлайн-загрузки Audiobookshelf, плагины Raspberry Pi/GPIO | Современная модульность, идея управления без экрана | Ранний **alpha**; сложнее минимального MVP, тест RAM и совместимости обязателен |
| [voicetunes](https://github.com/lukifer/voicetunes) | Офлайн-голосовой музыкальный плеер, voice2json, Mopidy, push-to-talk | Хороший UX-пример голосового ввода по кнопке | Больше компонентов, акцент на музыка/каталог; 512 МБ и локализация RU/UK не подтверждены |
| [Resona](https://github.com/mikegoatly/Resona) | Музыка, книги, sleep tunes, BT-подключение | Близкие функции и таймер сна | Сложный стек/интерфейс; не выбор по умолчанию для 512 МБ |
| [MPD](https://www.musicpd.org/) + GPIO + bookmarks | Сервис воспроизведения, очереди, управление | Долгоживущий headless музыкальный движок | Книжные закладки/главы и кнопки — отдельный слой, тесты A2DP и форматов |
| [mpv](https://mpv.io/) + JSON IPC + bookmarks | Воспроизведение файлов и сериализация позиции | Прямой file-based control для книг | Не готовый кнопочный плеер; надо проектировать state machine |
| [BlueALSA](https://github.com/arkq/bluez-alsa) | Bluetooth ↔ ALSA без десктопного аудиостека | Подходит для 512 МБ и headless | Это транспорт звука, не библиотека/плеер; стабильное сопряжение на HD-610 не доказано |

## Что рекомендовано

**Путь A: MVP без переписывания всего:** сравнить Phoniebox с лёгкой архитектурой MPD. Если Phoniebox укладывается в память и не мешает A2DP — использовать готовые механизмы управления библиотекой/кнопками. Если нет — взять только полезный UX и построить минимальный контроллер вокруг `mpv` или MPD. Для сверхпростого однокнопочного прототипа отдельно испытать One Button.

**Путь B: голос:** не привязывать STT к MVP. Прототип на USB-микрофоне и push-to-talk; исследовать `voicetunes`, `PocketSphinx`, `Vosk` на RAM, точность и RU/UK.

## План честного сравнения

1. Подтвердить выход 3,5 мм и BlueALSA с HD-610.
2. Установить кандидат в **отдельном тестовом окружении / после резервной копии**, не поверх принятого рабочего плеера.
3. Для каждого записать RSS, CPU, старт, поддерживаемые форматы, поведение после power loss, Bluetooth reconnect, кнопки.
4. Не использовать слепо `curl ... | bash` без просмотра install script и списка изменений; не выставлять web UI в интернет.
5. Зафиксировать выбор в ADR и оставить ссылки на исходники и лицензии перед заимствованием кода.

## Первоисточники

- https://github.com/mganthon/theonebuttonaudiobookplayer
- https://github.com/MiczFlor/RPi-Jukebox-RFID
- https://github.com/MiczFlor/RPi-Jukebox-RFID/wiki/INSTALL
- https://github.com/ladidadida/lauschkiste
- https://pypi.org/project/lauschkiste/
- https://github.com/lukifer/voicetunes
- https://github.com/mikegoatly/Resona
- https://www.musicpd.org/
- https://mpv.io/
- https://github.com/arkq/bluez-alsa
