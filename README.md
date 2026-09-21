# Проектная работа: шардирование, репликация и масштабирование

Решение проектной работы спринта 4 для интернет-магазина «Мобильный мир».

## Состав репозитория

| Путь | Содержание |
|---|---|
| `mongo-sharding/` | Задание 2: два шарда MongoDB |
| `mongo-sharding-repl/` | Задание 3: два шарда, по три реплики в каждом |
| `sharding-repl-cache/` | Задание 4: реплицированные шарды и Redis |
| `architecture.drawio` | Итоговая схема заданий 1, 5 и 6; пять страниц |
| `architecture.md` | Архитектурный документ по заданиям 7–10 |

Исходный PoC оставлен в корне для сравнения. Исполняемым итоговым решением
является каталог `sharding-repl-cache`.

## Быстрый запуск итогового решения

Требования: минимум 2 CPU, 4 ГБ RAM, Docker Desktop, Docker Compose v2 и Bash.

```bash
cd sharding-repl-cache
docker compose up -d
bash ./scripts/init-cluster.sh
docker compose ps
```

Используется требуемый образ приложения `kazhem/pymongo_api:1.0.0`.

Проверка:

- http://localhost:8080 — JSON с топологией MongoDB и состоянием кеша;
- http://localhost:8080/docs — Swagger UI;
- http://localhost:8080/helloDoc/count — 1000 документов;
- http://localhost:8080/helloDoc/users — кешируемый запрос.

Проверка времени ответа Redis:

```bash
bash ./scripts/check-cache.sh
```

Ожидаемый результат второго запроса — менее 100 мс.

## Что должно быть видно при проверке

- topology MongoDB — `Sharded`;
- `mongos` используется как точка подключения приложения;
- два шарда: `shard1ReplSet` и `shard2ReplSet`;
- в каждом shard replica set один Primary и две Secondary;
- в `somedb.helloDoc` находится 1000 документов, распределённых по шардам;
- `cache_enabled` равен `true`;
- повторный вызов `/helloDoc/users` обслуживается Redis.

Подробные команды диагностики и остановки находятся в README каждого стенда.
Одновременно запускайте только один вариант: все они публикуют порт 8080.
