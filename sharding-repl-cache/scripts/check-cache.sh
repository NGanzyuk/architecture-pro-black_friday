#!/usr/bin/env bash
set -euo pipefail

endpoint="http://localhost:8080/helloDoc/users"

echo "Первый запрос (чтение MongoDB и заполнение кеша):"
curl --silent --output /dev/null --write-out 'HTTP %{http_code}, %{time_total} s\n' "$endpoint"

echo "Повторный запрос (ожидается ответ из Redis быстрее 100 мс):"
curl --silent --output /dev/null --write-out 'HTTP %{http_code}, %{time_total} s\n' "$endpoint"
