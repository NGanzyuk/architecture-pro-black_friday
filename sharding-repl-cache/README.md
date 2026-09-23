# MongoDB: шардирование, репликация и Redis

Финальный исполняемый стенд для заданий 2–4:

- два шарда MongoDB;
- три узла в каждом shard replica set;
- `mongos` и одноузловой config server replica set;
- Redis с персистентностью AOF;
- приложение `kazhem/pymongo_api:1.0.0`.

## Запуск

Остановите другие варианты проекта, использующие порт 8080, затем выполните:

```bash
docker compose up -d
bash ./scripts/init-cluster.sh
docker compose ps
```

Приложение доступно по адресам:

- http://localhost:8080;
- http://localhost:8080/docs;
- http://localhost:8080/helloDoc/count;
- http://localhost:8080/helloDoc/users.

В корневом JSON должны быть:

- `mongo_topology_type: "Sharded"`;
- два шарда, каждый с тремя адресами replica set;
- `collections.helloDoc.documents_count: 1000`;
- `cache_enabled: true`.

## Проверка кеша

Эндпоинт `/helloDoc/users` специально выполняет первый запрос примерно одну
секунду. Результат кешируется на 60 секунд. Запустите проверку сразу после
инициализации:

```bash
bash ./scripts/check-cache.sh
```

Второй запрос должен выполниться быстрее `0.100 s`. Для повторной проверки после
истечения TTL подождите 60 секунд либо очистите кеш:

```bash
docker compose exec -T redis redis-cli FLUSHDB
```

## Ручная диагностика

```bash
docker compose exec -T mongos mongosh --quiet --eval 'sh.status()'
docker compose exec -T shard1-1 mongosh --quiet --eval 'rs.status().members.forEach((m) => print(`${m.name}: ${m.stateStr}`))'
docker compose exec -T shard2-1 mongosh --quiet --eval 'rs.status().members.forEach((m) => print(`${m.name}: ${m.stateStr}`))'
docker compose exec -T redis redis-cli DBSIZE
```

## Остановка

```bash
docker compose down
```

Полный сброс MongoDB и Redis: `docker compose down -v`.
