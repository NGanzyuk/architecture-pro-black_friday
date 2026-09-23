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

echo "Инициализация shard1ReplSet..."
docker compose exec -T shard1-1 mongosh --quiet <<'EOF'
try {
  rs.status();
  print("shard1ReplSet уже инициализирован");
} catch (error) {
  rs.initiate({
    _id: "shard1ReplSet",
    members: [
      { _id: 0, host: "shard1-1:27017", priority: 2 },
      { _id: 1, host: "shard1-2:27017", priority: 1 },
      { _id: 2, host: "shard1-3:27017", priority: 1 }
    ]
  });
}
EOF

echo "Инициализация shard2ReplSet..."
docker compose exec -T shard2-1 mongosh --quiet <<'EOF'
try {
  rs.status();
  print("shard2ReplSet уже инициализирован");
} catch (error) {
  rs.initiate({
    _id: "shard2ReplSet",
    members: [
      { _id: 0, host: "shard2-1:27017", priority: 2 },
      { _id: 1, host: "shard2-2:27017", priority: 1 },
      { _id: 2, host: "shard2-3:27017", priority: 1 }
    ]
  });
}
EOF
wait_for_primary shard1-1
wait_for_primary shard2-1

echo "Подключение replica set как шардов и загрузка данных..."
docker compose exec -T mongos mongosh --quiet <<'EOF'
const configDb = db.getSiblingDB("config");
const shardIds = configDb.shards.find({}, { _id: 1 }).toArray().map((item) => item._id);

if (!shardIds.includes("shard1ReplSet")) {
  sh.addShard("shard1ReplSet/shard1-1:27017,shard1-2:27017,shard1-3:27017");
}
if (!shardIds.includes("shard2ReplSet")) {
  sh.addShard("shard2ReplSet/shard2-1:27017,shard2-2:27017,shard2-3:27017");
}

sh.enableSharding("somedb");
const namespace = "somedb.helloDoc";
if (!configDb.collections.findOne({ _id: namespace, dropped: { $ne: true } })) {
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

echo "Состояние shard1ReplSet:"
docker compose exec -T shard1-1 mongosh --quiet \
  --eval 'rs.status().members.forEach((m) => print(`${m.name}: ${m.stateStr}`))'

echo "Состояние shard2ReplSet:"
docker compose exec -T shard2-1 mongosh --quiet \
  --eval 'rs.status().members.forEach((m) => print(`${m.name}: ${m.stateStr}`))'

echo "Документы на shard1:"
docker compose exec -T shard1-1 mongosh --quiet \
  --eval 'print(db.getSiblingDB("somedb").helloDoc.countDocuments({}))'

echo "Документы на shard2:"
docker compose exec -T shard2-1 mongosh --quiet \
  --eval 'print(db.getSiblingDB("somedb").helloDoc.countDocuments({}))'

echo "Готово. Откройте http://localhost:8080"
