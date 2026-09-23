# Архитектурный документ: данные «Мобильного мира»

## 1. Контекст и принципы

Система должна выдерживать резкие пики до 50 000 запросов/с, не создавать
«горячие» узлы из-за популярных категорий и сохранять корректность остатков,
корзин и статусов заказов. Решения ниже основаны на трёх принципах:

1. Шард-ключ выбирается по фактическим шаблонам запросов, а не только по
   структуре документа.
2. Поля с монотонным ростом и низкой кардинальностью не используются как
   единственный shard key.
3. Для критических операций свежесть данных важнее разгрузки Primary; чтение с
   Secondary применяется только там, где допустима устаревшая копия.

## 2. Задание 7. Схемы коллекций и шардирование MongoDB

### 2.1. `products`

Пример документа:

```javascript
{
  _id: UUID("..."),                 // идентификатор товара
  name: "Смартфон X",
  category: "electronics",
  price: Decimal128("49990.00"),
  stock_by_zone: {
    moscow: 50,
    kaliningrad: 30
  },
  attributes: {
    color: "black",
    size: null
  },
  updated_at: ISODate("2026-09-10T10:00:00Z")
}
```

Кандидаты: `_id`, `category`, `geozone`, составной ключ
`{category, _id}`. Выбран `{_id: "hashed"}`.

Обоснование:

- чтение карточки и обновление остатков конкретного товара становятся
  адресными запросами к одному шарду;
- хеширование равномерно распределяет популярные и непопулярные товары;
- `category` нельзя использовать отдельно: категория `electronics` создаст
  горячий диапазон;
- поиск по категории будет scatter-gather, поэтому он обслуживается отдельным
  индексом и при росте может быть вынесен в поисковый read model.

Индексы и шардирование:

```javascript
use shop
db.products.createIndex({ category: 1, price: 1 })
db.products.createIndex({ updated_at: -1 })
sh.shardCollection("shop.products", { _id: "hashed" })
```

Списание остатка выполняется атомарным условным обновлением на документе товара:

```javascript
db.products.updateOne(
  { _id: productId, "stock_by_zone.moscow": { $gte: quantity } },
  { $inc: { "stock_by_zone.moscow": -quantity }, $set: { updated_at: new Date() } }
)
```

Успешное списание определяется по `modifiedCount: 1`. Для заказа из нескольких
товаров потребуется транзакция, резервирование запасов или Saga; один shard key
сам по себе не обеспечивает междокументную атомарность.

### 2.2. `orders`

```javascript
{
  _id: UUID("..."),
  customer_id: UUID("..."),
  created_at: ISODate("2026-09-10T10:05:00Z"),
  items: [
    {
      product_id: UUID("..."),
      name: "Смартфон X",           // исторический снимок
      quantity: 1,
      unit_price: Decimal128("49990.00")
    }
  ],
  status: "created",
  total: Decimal128("49990.00"),
  geozone: "moscow",
  updated_at: ISODate("2026-09-10T10:05:00Z")
}
```

Кандидаты: `_id`, `customer_id`, `created_at`, `geozone`. Выбран
`{customer_id: "hashed"}`.

- история одного клиента маршрутизируется на один шард;
- разные клиенты равномерно распределены;
- `created_at` как первый ключ создал бы горячий хвост;
- `geozone` имеет низкую кардинальность и создаёт перекос крупных регионов;
- получение статуса должно передавать `customer_id` вместе с `order_id`.

```javascript
db.orders.createIndex({ customer_id: 1, created_at: -1 })
db.orders.createIndex({ customer_id: 1, _id: 1 })
db.orders.createIndex({ status: 1, updated_at: 1 })
sh.shardCollection("shop.orders", { customer_id: "hashed" })
```

Поскольку `_id` не является префиксом shard key, его глобальную уникальность
нужно обеспечивать генерацией UUID в приложении. Запрос только по `_id` будет
scatter-gather; публичный API заказа должен сохранять контекст клиента.

### 2.3. `carts`

Для двух способов идентификации владельца вводится нормализованное поле
`owner_key`: `user:<user_id>` или `session:<session_id>`.

```javascript
{
  _id: UUID("..."),
  owner_key: "user:550e8400-e29b-41d4-a716-446655440000",
  user_id: UUID("..."),
  session_id: null,
  items: [
    { product_id: UUID("..."), quantity: 2 }
  ],
  status: "active",
  created_at: ISODate("2026-09-10T10:00:00Z"),
  updated_at: ISODate("2026-09-10T10:10:00Z"),
  expires_at: ISODate("2026-10-10T10:10:00Z"),
  version: NumberLong(7)
}
```

Выбран `{owner_key: "hashed"}`:

- получение активной гостевой и пользовательской корзины адресное;
- обновления разных владельцев равномерно распределяются;
- `status` и `expires_at` имеют плохую кардинальность и не подходят для shard key;
- при логине гостевая и пользовательская корзины могут находиться на разных
  шардах, поэтому слияние выполняется идемпотентным прикладным сценарием.

```javascript
db.carts.createIndex({ owner_key: 1, status: 1, updated_at: -1 })
db.carts.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 })
sh.shardCollection("shop.carts", { owner_key: "hashed" })
```

Алгоритм слияния:

1. Прочитать обе активные корзины.
2. Объединить товары по `product_id`, используя идемпотентный `merge_id`.
3. Записать пользовательскую корзину с проверкой `version`.
4. Пометить гостевую `abandoned`.
5. При конфликте версии повторить операцию; периодическая задача завершает
   незаконченные слияния.

## 3. Задание 8. Выявление и устранение горячих шардов

### 3.1. Набор метрик

| Группа | Метрики | Сигнал проблемы |
|---|---|---|
| Нагрузка | read/write ops/s по шарду, active/queued operations, connections | один шард устойчиво выше медианы более чем в 1.5 раза |
| Задержка | p95/p99 чтения и записи, время checkout соединения | превышение SLO 5–10 минут |
| Ресурсы | CPU, RAM, WiredTiger cache dirty/evicted, disk IOPS/latency, network | CPU > 75%, рост eviction или disk latency |
| Распределение | data size, document count и chunks по шарду, jumbo chunks | отклонение объёма или chunks более 20% |
| Balancer | состояние, активные/неуспешные миграции, длительность migration | балансировщик не успевает либо миграции ошибочны |
| Replica set | lag Secondary, oplog window, elections, недоступные members | lag выше бизнес-допуска или oplog window меньше времени восстановления |

Базовые команды диагностики:

```javascript
sh.status()
sh.getBalancerState()
sh.balancerCollectionStatus("shop.products")
db.getSiblingDB("admin").aggregate([{ $shardedDataDistribution: {} }])
db.getSiblingDB("admin").serverStatus()
rs.printSecondaryReplicationInfo()
```

Для постоянного мониторинга эти показатели экспортируются в Prometheus через
MongoDB exporter; в Grafana создаются панели и алерты. Алерт строится по
сочетанию нагрузки, latency и распределения, потому что высокий CPU сам по себе
не доказывает ошибку shard key.

### 3.2. Меры устранения

1. **Balancer.** Держать его включённым, следить за ошибками миграций и задавать
   окно балансировки вне пиков, если миграции конкурируют с продажами.
2. **Изменение shard key.** Для `products`, разбитых только по `category`,
   перейти на хешированный `_id`:

   ```javascript
   db.adminCommand({
     reshardCollection: "shop.products",
     key: { _id: "hashed" },
     numInitialChunks: 32
   })
   ```

3. **Добавление шардов.** Автоматизация добавляет ёмкость только после
   устойчивого превышения порогов; далее balancer переносит chunks. Добавление
   узла без исправления низкокардинального ключа не устранит горячую категорию.
4. **Ручное аварийное перемещение.** После определения горячего chunk:

   ```javascript
   db.adminCommand({
     moveChunk: "shop.products",
     find: { _id: productId },
     to: "shard2ReplSet"
   })
   ```

5. **Защита приложения.** Кешировать карточки и каталожные выдачи, ограничивать
   тяжёлые запросы, применять backpressure и не кешировать авторитетный остаток
   во время оформления заказа.

Resharding и массовые миграции запускаются контролируемо: они потребляют диск и
сеть и способны временно увеличить latency. До операции проверяются резервная
копия, свободное место и отсутствие конкурирующих index build.

### 3.3. Zoned (tag-aware) sharding

Zoned sharding добавляет к обычному балансированию явное правило размещения:
диапазон значений shard key связывается с зоной, а зона — с одним или несколькими
шардами. Balancer оставляет chunks этого диапазона только на шардах его зоны.
Механизм полезен для географической локализации данных, соблюдения требований к
месту хранения, разделения hot/cold-данных и размещения особенно нагруженной
части каталога на более производительном оборудовании.

Для «Мобильного мира» возможен отдельный вариант для горячей категории
`electronics`. Ключ должен начинаться с поля, по которому задаётся зона, а
хешированная часть распределяет товары внутри неё:

```javascript
sh.shardCollection(
  "shop.products",
  { category: 1, _id: "hashed" }
)

// Имена условные: это два отдельных производительных shard replica set.
sh.addShardToZone("hotShard1ReplSet", "HOT_ELECTRONICS")
sh.addShardToZone("hotShard2ReplSet", "HOT_ELECTRONICS")

sh.updateZoneKeyRange(
  "shop.products",
  { category: "electronics", _id: MinKey },
  { category: "electronics", _id: MaxKey },
  "HOT_ELECTRONICS"
)
```

Нижняя граница диапазона включается, верхняя не включается. В зону обязательно
включаются как минимум два шарда: назначение всей горячей категории одному
шарду только закрепило бы hotspot. Незонированные категории balancer может
распределять по остальным доступным шардам обычным способом.

Это не бесплатная замена выбранному в задании 7 ключу `{_id: "hashed"}`. При
ключе `{category: 1, _id: "hashed"}` запрос по одному `_id` без `category`
становится scatter-gather, поэтому API должен передавать оба значения либо
использовать отдельный lookup/read model. Переход существующей коллекции требует
контролируемого resharding. Zones следует применять при реальном требовании к
локализации или отдельному классу оборудования; обычный перекос сначала
устраняется хорошим shard key, достаточным числом chunks и работой balancer.

## 4. Задание 9. Чтение с реплик и консистентность

Для денежных операций и остатков используются `writeConcern: "majority"` и
`readConcern: "majority"`. Чтение с Primary обеспечивает read-your-writes в
пользовательском сценарии; Secondary используется для допускающих задержку
read model.

| Коллекция и операция | Узел | Допустимый lag | Обоснование |
|---|---|---:|---|
| `products`: карточка, описание, атрибуты | `secondaryPreferred` | целевой ≤30 с | редко меняющиеся данные, устаревание не ведёт к продаже |
| `products`: каталог по категории/цене | `secondaryPreferred` | целевой ≤30 с | большой объём чтений, допустима небольшая задержка выдачи |
| `products`: фактический остаток перед резервированием | Primary | 0 с | устаревший остаток создаёт oversell |
| `orders`: подтверждение сразу после создания | Primary | 0 с | требуется read-your-writes |
| `orders`: текущий статус, оплата, сборка | Primary | 0 с | устаревший статус вызывает повтор оплаты или неверное действие |
| `orders`: история старых заказов | `secondaryPreferred` | целевой ≤10 с | записи в основном неизменяемы; UI может повторить чтение с Primary для последнего заказа |
| `carts`: активная корзина | Primary | 0 с | пользователь должен сразу видеть добавление и удаление товара |
| `carts`: слияние, оформление, смена статуса | Primary | 0 с | нужна проверка версии и последовательность изменений |
| `carts`: abandoned-аналитика и отчёты | Secondary | ≤90 с | асинхронный сценарий не влияет на покупку |

Пример подключения для некритичных read model:

```text
mongodb://mongos:27017/shop?readPreference=secondaryPreferred&maxStalenessSeconds=90
```

MongoDB не разрешает `maxStalenessSeconds` меньше 90 секунд. Поэтому значения
10–30 секунд в таблице — внутренний SLO, контролируемый метриками replication
lag. Если это жёсткая гарантия, операция должна читать Primary; параметр 90 с
служит только грубым предохранителем от сильно отставшей Secondary.

## 5. Задание 10. Миграция на Cassandra

### 5.1. Что переносить

| Данные | Решение | Причина |
|---|---|---|
| История заказов и события статусов | переносить | высокая запись, чтение по клиенту/заказу, естественная денормализация |
| Каталожный read model | переносить | большой поток чтений и предсказуемые запросы по id/категории |
| Корзины и сессии | переносить | высокая частота записи, TTL, независимые партиции владельцев |
| Авторитетные остатки | оставить в транзакционном хранилище | конкурентное условное списание и риск oversell |
| Платёжная проводка | оставить в транзакционном ledger | нужны строгие инварианты, аудит и межзаписная целостность |

Cassandra применяется не как универсальная замена MongoDB, а как набор
query-oriented таблиц. Одни и те же данные денормализуются в несколько таблиц;
каждая обслуживает конкретный запрос без полного сканирования.

### 5.2. Keyspace и репликация

```sql
CREATE KEYSPACE mobile_world
WITH replication = {
  'class': 'NetworkTopologyStrategy',
  'dc1': 3,
  'dc2': 3
}
AND durable_writes = true;
```

`NetworkTopologyStrategy` размещает реплики с учётом дата-центров и rack. Для
пользовательских операций применяется `LOCAL_QUORUM`, чтобы не добавлять
межрегиональный RTT. Асинхронная репликация доставляет данные во второй регион.

### 5.3. Таблицы заказов

```sql
CREATE TABLE mobile_world.orders_by_customer_month (
  customer_id uuid,
  order_month date,
  created_at timestamp,
  order_id uuid,
  status text,
  total decimal,
  geozone text,
  items_json text,
  PRIMARY KEY ((customer_id, order_month), created_at, order_id)
) WITH CLUSTERING ORDER BY (created_at DESC, order_id ASC)
  AND read_repair = 'NONE';

CREATE TABLE mobile_world.order_by_id (
  order_id uuid PRIMARY KEY,
  customer_id uuid,
  created_at timestamp,
  status text,
  total decimal,
  geozone text,
  updated_at timestamp
) WITH read_repair = 'BLOCKING';
```

`(customer_id, order_month)` — bucketed partition key. Он ограничивает рост
партиции, а `created_at` обеспечивает эффективную сортировку истории. Отдельная
таблица `order_by_id` нужна для адресного чтения статуса: Cassandra моделируется
под запросы, а не через вторичные join.

### 5.4. Таблицы товаров

```sql
CREATE TABLE mobile_world.product_by_id (
  product_id uuid PRIMARY KEY,
  name text,
  category text,
  price decimal,
  attributes_json text,
  updated_at timestamp
) WITH read_repair = 'NONE';

CREATE TABLE mobile_world.products_by_category_bucket (
  category text,
  bucket tinyint,
  price decimal,
  product_id uuid,
  name text,
  attributes_json text,
  PRIMARY KEY ((category, bucket), price, product_id)
) WITH CLUSTERING ORDER BY (price ASC, product_id ASC)
  AND read_repair = 'NONE';
```

`bucket = hash(product_id) mod 16`. Популярная категория распределяется по 16
партициям вместо одной горячей. Каталожный сервис параллельно читает 16
партиций и объединяет отсортированные результаты. Число bucket фиксируется в
версии схемы и меняется контролируемой миграцией.

### 5.5. Корзины и сессии

```sql
CREATE TABLE mobile_world.cart_meta_by_owner (
  owner_key text PRIMARY KEY,
  cart_id uuid,
  status text,
  created_at timestamp,
  updated_at timestamp,
  version bigint
) WITH read_repair = 'BLOCKING';

CREATE TABLE mobile_world.cart_items_by_owner (
  owner_key text,
  product_id uuid,
  quantity int,
  updated_at timestamp,
  PRIMARY KEY ((owner_key), product_id)
) WITH read_repair = 'NONE';

CREATE TABLE mobile_world.session_by_id (
  session_id text PRIMARY KEY,
  user_id uuid,
  payload text,
  updated_at timestamp
) WITH read_repair = 'NONE';
```

Записи корзины и сессии получают TTL при записи:

```sql
INSERT INTO mobile_world.session_by_id
  (session_id, user_id, payload, updated_at)
VALUES (?, ?, ?, toTimestamp(now()))
USING TTL 2592000;
```

Все элементы корзины одного владельца находятся в одной партиции. Изменения
нескольких строк одной корзины допускают logged batch внутри этой партиции.
Слияние гостевой и пользовательской партиций выполняется приложением
идемпотентно; cross-partition batch не используется.

### 5.6. Горячие партиции и масштабирование

Cassandra распределяет partition key по token ring с помощью consistent
hashing. При добавлении узла перемещается только часть диапазонов токенов, а не
весь набор данных. Риски контролируются следующим образом:

- месячные buckets ограничивают историю одного крупного клиента;
- category buckets устраняют горячую `electronics`;
- в метриках отслеживаются размер партиций, requests/partition, dropped
  mutations, pending compactions и p99 latency;
- запрос обязан содержать partition key; `ALLOW FILTERING` не используется в
  пользовательском пути;
- крупные партиции дополнительно разбиваются на дневные buckets или большее
  количество hash buckets.

### 5.7. Hinted Handoff, Read Repair и Anti-Entropy Repair

| Сущность | Hinted Handoff | Read Repair | Anti-Entropy Repair |
|---|---|---|---|
| `order_by_id` | да, для кратких отказов | `BLOCKING`, чтение `LOCAL_QUORUM` | ежедневный incremental repair, полный по регламенту |
| История заказов | да | `NONE`: данные почти неизменяемы, важна write atomicity partition | регулярный incremental repair |
| Каталог | да | `NONE`, приоритет низкой latency | периодический repair; read model можно перестроить |
| Метаданные корзины | да | `BLOCKING`, нужен монотонный статус/version | частый incremental repair в пределах `gc_grace_seconds` |
| Элементы корзины и сессии | да | `NONE`, сохраняется partition-level write atomicity | repair до истечения tombstone/TTL-окон |

Hinted Handoff ускоряет восстановление после краткого отказа, но является best
effort и не заменяет repair. Blocking Read Repair даёт монотонные quorum-чтения
ценой дополнительной latency. Anti-Entropy Repair сравнивает реплики по Merkle
tree и является обязательной плановой операцией; Cassandra не запускает его
автоматически.

Пример настроек и запуска:

```yaml
hinted_handoff_enabled: true
max_hint_window: 3h
```

```bash
nodetool repair -pr
```

Repair выполняется оркестратором по узлам и диапазонам с ограничением
параллелизма, чтобы не перегрузить сеть и диски в пик продаж.

## 6. Ссылки на документацию

- [MongoDB: Sharding](https://www.mongodb.com/docs/manual/sharding/)
- [MongoDB: Reshard a Collection](https://www.mongodb.com/docs/manual/core/sharding-reshard-a-collection/)
- [MongoDB: Zones](https://www.mongodb.com/docs/manual/core/zone-sharding/)
- [MongoDB: sh.updateZoneKeyRange()](https://www.mongodb.com/docs/manual/reference/method/sh.updateZoneKeyRange/)
- [MongoDB: maxStalenessSeconds](https://www.mongodb.com/docs/manual/core/read-preference-staleness/)
- [Apache Cassandra: Data Modeling](https://cassandra.apache.org/doc/latest/cassandra/developing/data-modeling/intro.html)
- [Apache Cassandra: Dynamo architecture and NetworkTopologyStrategy](https://cassandra.apache.org/doc/latest/cassandra/architecture/dynamo.html)
- [Apache Cassandra: Hinted Handoff](https://cassandra.apache.org/doc/stable/cassandra/managing/operating/hints.html)
- [Apache Cassandra: Repair](https://cassandra.apache.org/doc/latest/cassandra/managing/operating/repair.html)
- [Apache Cassandra: Read Repair](https://cassandra.apache.org/doc/4.0/cassandra/operating/read_repair.html)
