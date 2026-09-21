#!/usr/bin/env bash
set -euo pipefail

wait_for_primary() {
  local service="$1"
  local attempts=60

  until docker compose exec -T "$service" mongosh --quiet \
    --eval 'quit(db.hello().isWritablePrimary ? 0 : 1)' >/dev/null 2>&1; do
    attempts=$((attempts - 1))
    if [ "$attempts" -eq 0 ]; then
      echo "Не удалось дождаться Primary у сервиса $service" >&2
      exit 1
    fi
    sleep 2
  done
}

echo "Инициализация config server replica set..."
docker compose exec -T configsrv mongosh --quiet <<'EOF'
try {
  rs.status();
  print("configReplSet уже инициализирован");
} catch (error) {
  rs.initiate({
    _id: "configReplSet",
    configsvr: true,
    members: [{ _id: 0, host: "configsrv:27017" }]
  });
}
EOF
wait_for_primary configsrv

echo "Инициализация одноузловых replica set, необходимых для шардов..."
docker compose exec -T shard1 mongosh --quiet <<'EOF'
try {
  rs.status();
  print("shard1ReplSet уже инициализирован");
} catch (error) {
  rs.initiate({
    _id: "shard1ReplSet",
    members: [{ _id: 0, host: "shard1:27017" }]
  });
}
EOF

docker compose exec -T shard2 mongosh --quiet <<'EOF'
try {
  rs.status();
  print("shard2ReplSet уже инициализирован");
} catch (error) {
  rs.initiate({
    _id: "shard2ReplSet",
    members: [{ _id: 0, host: "shard2:27017" }]
  });
}
EOF
wait_for_primary shard1
wait_for_primary shard2

echo "Подключение шардов к mongos и настройка коллекции..."
docker compose exec -T mongos mongosh --quiet <<'EOF'
const configDb = db.getSiblingDB("config");
const shardIds = configDb.shards.find({}, { _id: 1 }).toArray().map((item) => item._id);

if (!shardIds.includes("shard1ReplSet")) {
  sh.addShard("shard1ReplSet/shard1:27017");
}
if (!shardIds.includes("shard2ReplSet")) {
  sh.addShard("shard2ReplSet/shard2:27017");
}

sh.enableSharding("somedb");

const namespace = "somedb.helloDoc";
const collectionMetadata = configDb.collections.findOne({ _id: namespace, dropped: { $ne: true } });
if (!collectionMetadata) {
  sh.shardCollection(namespace, { _id: "hashed" }, false, { numInitialChunks: 4 });
}

const collection = db.getSiblingDB("somedb").helloDoc;
for (let i = 0; i < 1000; i += 1) {
  collection.updateOne(
    { _id: i },
    { $set: { age: i, name: `ly${i}` } },
    { upsert: true }
  );
}

print(`Общее количество документов: ${collection.countDocuments({})}`);
sh.status();
EOF

echo "Документы на shard1:"
docker compose exec -T shard1 mongosh --quiet \
  --eval 'print(db.getSiblingDB("somedb").helloDoc.countDocuments({}))'

echo "Документы на shard2:"
docker compose exec -T shard2 mongosh --quiet \
  --eval 'print(db.getSiblingDB("somedb").helloDoc.countDocuments({}))'

echo "Готово. Откройте http://localhost:8080"
