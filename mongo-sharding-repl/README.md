# MongoDB: шардирование и репликация

Стенд содержит два шарда. Каждый шард — replica set из трёх узлов: один
Primary и две Secondary. При отказе Primary оставшиеся узлы проводят выборы и
одна из Secondary становится новой Primary.

## Запуск

Перед запуском остановите другие варианты проекта, поскольку они используют тот
же порт 8080.

```bash
docker compose up -d
bash ./scripts/init-cluster.sh
docker compose ps
```

Инициализация повторяемая и не создаёт дубли тестовых документов.

## Проверка

- http://localhost:8080 — общая информация;
- http://localhost:8080/docs — Swagger UI;
- http://localhost:8080/helloDoc/count — должно быть 1000 документов.

В корневом JSON ожидаются `mongo_topology_type: "Sharded"`, два шарда и строки
подключения каждого шарда с тремя участниками replica set.

Проверка ролей узлов:

```bash
docker compose exec -T shard1-1 mongosh --quiet --eval 'rs.status().members.forEach((m) => print(`${m.name}: ${m.stateStr}`))'
docker compose exec -T shard2-1 mongosh --quiet --eval 'rs.status().members.forEach((m) => print(`${m.name}: ${m.stateStr}`))'
```

Проверка распределения:

```bash
docker compose exec -T shard1-1 mongosh --quiet --eval 'print(db.getSiblingDB("somedb").helloDoc.countDocuments({}))'
docker compose exec -T shard2-1 mongosh --quiet --eval 'print(db.getSiblingDB("somedb").helloDoc.countDocuments({}))'
```

Остановка:

```bash
docker compose down
```

Полный сброс данных: `docker compose down -v`.
