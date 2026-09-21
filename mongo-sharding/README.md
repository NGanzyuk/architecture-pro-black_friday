# MongoDB: шардирование

Стенд реализует первый вариант архитектуры: `pymongo-api` подключается к
маршрутизатору `mongos`, который распределяет коллекцию `somedb.helloDoc`
между двумя шардами. Каждый шард на этом этапе состоит из одного узла.
Одноузловые replica set используются потому, что современный MongoDB требует
replica set для подключения шарда к кластеру; отказоустойчивость добавляется в
следующем варианте проекта.

## Запуск

Требования: Docker Desktop, Docker Compose v2, Git Bash (или другой Bash).

```bash
docker compose up -d
bash ./scripts/init-cluster.sh
docker compose ps
```

Скрипт можно запускать повторно: он проверяет существующую конфигурацию и
обновляет 1000 тестовых документов без создания дублей.

## Проверка

Откройте:

- http://localhost:8080 — состояние MongoDB;
- http://localhost:8080/docs — Swagger UI;
- http://localhost:8080/helloDoc/count — общее количество документов.

Корневой ответ должен содержать:

- `mongo_topology_type: "Sharded"`;
- `mongo_is_mongos: true`;
- два элемента в `shards`;
- `collections.helloDoc.documents_count: 1000`.

Распределение документов можно проверить напрямую:

```bash
docker compose exec -T shard1 mongosh --quiet --eval 'print(db.getSiblingDB("somedb").helloDoc.countDocuments({}))'
docker compose exec -T shard2 mongosh --quiet --eval 'print(db.getSiblingDB("somedb").helloDoc.countDocuments({}))'
```

## Остановка

```bash
docker compose down
```

Для полного сброса данных используйте `docker compose down -v`, затем повторите
запуск и инициализацию.
