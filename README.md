Модификация PasarGuard Panel с поддержкой routing-заголовков для Happ и INCY.

Когда клиент с User-Agent Happ/* запрашивает подписку, панель отправляет
заголовок routing с содержимым поля "HAPP Routing".
Когда клиент с User-Agent INCY/* — содержимое поля "INCY Routing".

Deeplink-ссылки (профиль "el-duckVPN"):

  HAPP  https://github.com/idealzm/roscomvpn-routing/blob/main/HAPP/DEFAULT.DEEPLINK
  INCY  https://github.com/idealzm/roscomvpn-routing/blob/main/INCY/DEFAULT.DEEPLINK

Установка с нуля:

  sudo bash -c "$(curl -fsSL https://github.com/idealzm/el-duck-routing/raw/main/install-happ.sh)" @ install

Установка на уже работающую версию:

  cd /opt/pasarguard
  sudo curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64 -o /usr/bin/yq && sudo chmod +x /usr/bin/yq
  yq -i '.services.pasarguard.image = "ghcr.io/idealzm/el-duck-routing:happ-routing-v1"' docker-compose.yml
  docker compose pull && docker compose up -d

После установки:

  1. Открыть панель в браузере
  2. Settings > Subscriptions
  3. В поле HAPP Routing вставить deeplink для Happ
  4. В поле INCY Routing вставить deeplink для INCY
  5. Сохранить

Откат на оригинальную версию:

  cd /opt/pasarguard
  yq -i '.services.pasarguard.image = "pasarguard/panel"' docker-compose.yml
  docker compose pull && docker compose up -d

База данных и настройки не затрагиваются при замене образа.
Новые поля HAPP Routing и INCY Routing хранятся в JSON и совместимы
с оригинальной версией — при откате просто игнорируются.

GitHub Actions автоматически собирает образ при пуше в main.