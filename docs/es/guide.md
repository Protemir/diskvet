# Por qué ClickHouse® llena el disco en Langfuse y SigNoz autoalojados y cómo solucionarlo

*[English](../guide.md) · [Português](../pt/guide.md) · [Русский](../ru/guide.md) · [中文](../zh/guide.md). Si las versiones no coinciden, la inglesa es la correcta.*

Tu servidor de Langfuse o SigNoz se está quedando sin espacio en disco, pero tus trazas
ocupan poco. En la mayoría de los casos publicados, el espacio se lo lleva el
propio ClickHouse®: sus tablas de registro del sistema (system log tables), como
`system.trace_log` y `system.text_log`, que por defecto no tienen límite de
tamaño. ClickStack tiene el mismo problema.

Esta guía explica cómo confirmarlo con una sola consulta de solo lectura,
liberar el espacio ahora y evitar que el problema vuelva sin caer en las
trampas conocidas. No necesitas herramientas adicionales.

*Probado con las imágenes estándar de `clickhouse/clickhouse-server` 24.8, 25.12
y 26.9 (los comandos de SigNoz, con 25.5 y 25.12), con el servicio y la
configuración de ClickHouse tomados de los archivos compose de Langfuse y SigNoz.*

## Resumen

1. **Comprueba.** Ejecuta una consulta de solo lectura sobre `system.parts`. Si las tablas `system.*_log` ocupan más que tus datos, el problema son las tablas de registro del propio ClickHouse.
2. **Libera espacio ya.** Vacía las tablas de registro grandes con `TRUNCATE`. Para una tabla de más de 50 GB, añade `SETTINGS max_table_size_to_drop = 0`.
3. **Evita que vuelva.** Añade un archivo en `config.d` con un TTL (tiempo de vida) para cada tabla de registro; en `opentelemetry_span_log` el TTL va dentro de `<engine>`. Luego reinicia ClickHouse.
4. **Limpia.** Elimina las copias `*_log_0`, `*_log_1` que deja el reinicio.
5. **¿Sigue lleno?** Revisa los logs de los contenedores de Docker, las filas eliminadas y las partes (parts) atascadas. En Langfuse, actualiza Langfuse antes de pasar ClickHouse a 26.8+.

## 1. ¿Qué ocupa el disco? Uso de disco de ClickHouse por tabla

Guarda esta consulta como `size.sql`. Muestra las tablas más grandes según su
tamaño en disco:

```sql
SELECT database, table,
       formatReadableSize(sum(bytes_on_disk)) AS size,
       sum(rows) AS rows,
       count() AS parts
FROM system.parts
WHERE active
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 15;
```

**Langfuse (docker compose).** Ejecuta esto en la carpeta donde está el
`docker-compose.yml` de Langfuse. Su archivo compose ya define `CLICKHOUSE_USER`
y `CLICKHOUSE_PASSWORD` dentro del contenedor:

```sh
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --readonly=1 --format PrettyCompact' < size.sql
```

**SigNoz (docker compose).** El contenedor suele llamarse `signoz-clickhouse`
(compruébalo con `docker ps`). El `users.xml` de SigNoz deja al usuario
`default` sin contraseña:

```sh
docker exec -i signoz-clickhouse clickhouse-client --readonly=1 --format PrettyCompact < size.sql
```

`--readonly=1` pone la sesión en modo de solo lectura: ClickHouse rechaza
cualquier cambio.

**Cómo interpretarlo.** Compara las filas de `system` con tus propios datos
(`default` en Langfuse, `signoz_*` en SigNoz). Si `system.trace_log` o
`system.text_log` encabezan la lista, pasa a la sección 2.

## 2. ¿Cómo libero espacio en disco ahora mismo?

Abre un cliente con permisos de escritura:

```sh
# Langfuse
docker compose exec clickhouse sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD"'
# SigNoz
docker exec -it signoz-clickhouse clickhouse-client
```

Vacía las tablas de registro grandes:

```sql
TRUNCATE TABLE system.trace_log;
TRUNCATE TABLE system.text_log;
TRUNCATE TABLE system.metric_log;
TRUNCATE TABLE system.query_log;
```

Esto elimina solo los datos de diagnóstico del propio ClickHouse, no tus
trazas, y no requiere reiniciar.

Langfuse lee `system.query_log` para seguir algunas de sus propias consultas
([#13123](https://github.com/langfuse/langfuse/issues/13123)). Por eso, vacíala,
pero no la desactives.

### ¿TRUNCATE falla con Code 359? Tablas de más de 50 GB

ClickHouse no elimina ni vacía una tabla que supere `max_table_size_to_drop`
(por defecto, 50 000 000 000 bytes, unos 46.6 GiB). El límite también afecta a
`TRUNCATE`: con una tabla más grande, la sentencia falla con
`Code: 359 ... (TABLE_SIZE_EXCEEDS_MAX_DROP_SIZE_LIMIT)`.

Y las tablas de registro grandes sí llegan a ese límite: el `text_log` de la
[discusión #15024 de Langfuse](https://github.com/orgs/langfuse/discussions/15024)
ocupaba 59.20 GiB. Hay dos formas de sortearlo.

**Opción A.** Quita el límite para una sola sentencia:

```sql
-- ClickHouse 23.12+: quita el límite solo para esta sentencia
TRUNCATE TABLE system.text_log SETTINGS max_table_size_to_drop = 0;
```

**Opción B.** Crea el archivo flag de un solo uso y luego ejecuta el `TRUNCATE`
normal:

```sh
docker compose exec clickhouse sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'
```

(En SigNoz: `docker exec signoz-clickhouse sh -c '...'` con el mismo comando.)
ClickHouse elimina el flag después del primer `DROP` o `TRUNCATE` que lo
necesita, así que vuelve a crearlo antes de la siguiente tabla grande.

El espacio ya está libre, pero las tablas de registro empiezan a crecer de nuevo
enseguida. La sección 4 lo evita, y la sección 3 explica por qué pasa.

## 3. ¿Por qué trace_log y text_log son tan grandes?

ClickHouse escribe sus propios datos de diagnóstico en tablas de la base de
datos `system`: `query_log`, `trace_log`, `text_log`, `metric_log` y otras. La
[documentación](https://clickhouse.com/docs/reference/system-tables/overview)
lo dice claramente: «By default, table growth is unlimited» (por defecto, el
crecimiento de las tablas es ilimitado).

La [configuración por defecto](https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml)
de las versiones recientes define un TTL solo para algunas tablas de registro pequeñas (desde
25.9, `processors_profile_log` conserva 30 días), no para las grandes. Dos
valores por defecto hacen que las grandes crezcan rápido:

- el perfilador de consultas (query profiler) está activado y escribe en `trace_log` muestras de la pila de las consultas en ejecución;
- `text_log` guarda el log del servidor con nivel `trace`.

Casos públicos:

- **Langfuse [#13123](https://github.com/langfuse/langfuse/issues/13123):** `system.trace_log` ocupaba 66.86 GiB, mientras que las tablas de Langfuse que aparecen ahí (`traces`, `observations`, `scores`) sumaban unos 51 MiB. Los mantenedores decidieron no cambiar los valores por defecto de ClickHouse y, en su lugar, añadieron una [página de FAQ](https://langfuse.com/faq/all/reduce-clickhouse-disk-size).
- **SigNoz [#12050](https://github.com/SigNoz/signoz/issues/12050):** más de 80 GB en tablas de registro del sistema (incluida una copia `trace_log_0`) frente a menos de 500 MB de telemetría. Vaciar las tablas `system.*` liberó unos 80 GB. El nuevo instalador Foundry de SigNoz define los TTL; las instalaciones más antiguas con docker compose no los tienen.
- **Chart de Helm de ClickStack, [PR #275](https://github.com/ClickHouse/ClickStack-helm-charts/pull/275):** un volumen de 10 Gi llegó al 100% a los 10 días, con 5.2 GB de logs del servidor de nivel trace y un `system.text_log` de 3.7 GB, frente a ~70 MB de telemetría. El PR, integrado en septiembre de 2026, añade un TTL de 7 días.

## 4. ¿Cómo configuro un TTL en las tablas de registro del sistema de ClickHouse?

Con un TTL, ClickHouse elimina por sí solo las filas antiguas de las tablas de
registro. Configúralo **después** del `TRUNCATE` de la sección 2, por la forma
en que ClickHouse lo aplica.

Cuando añades un TTL y reinicias, ClickHouse no reduce la tabla antigua: la
renombra a `trace_log_0` con todas sus filas y crea una nueva con el TTL. Si la
vacías antes, estas copias quedan diminutas, y el paso 4 las elimina.

Ejecuta el SQL siguiente en el mismo cliente con permisos de escritura de la
sección 2.

### Paso 1: ¿qué tablas de registro no tienen TTL?

```sql
SELECT name,
       formatReadableSize(total_bytes) AS size,
       extract(engine_full, 'TTL [^S]*') AS ttl
FROM system.tables
WHERE database = 'system' AND engine LIKE '%MergeTree' AND match(name, '_log(_[0-9]+)?$')
ORDER BY total_bytes DESC;
```

Un `ttl` vacío significa que la tabla de registro conserva los datos para
siempre. Los nombres como `trace_log_0` son copias antiguas; el paso 4 las
elimina.

### Paso 2: añade un archivo de TTL en config.d

Guarda esto como `clickhouse-ttl.xml` junto a `docker-compose.yml`:

```xml
<clickhouse>
    <!-- Conserva 7 días de datos en las tablas de registro de ClickHouse. Incluye solo las que tiene tu servidor. -->
    <query_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></query_log>
    <trace_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></trace_log>
    <text_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></text_log>
    <metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></metric_log>
    <asynchronous_metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></asynchronous_metric_log>
    <part_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></part_log>

    <!-- La configuración estándar define esta tabla con <engine>, así que un <ttl> aparte
         impide que el servidor arranque (ClickHouse#88366). El TTL va dentro. -->
    <opentelemetry_span_log>
        <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(finish_date) ORDER BY (finish_date, finish_time_us) TTL finish_date + INTERVAL 7 DAY DELETE</engine>
    </opentelemetry_span_log>
</clickhouse>
```

Móntalo en el servicio `clickhouse` (conserva las líneas de volúmenes que ya
tienes):

```yaml
  clickhouse:
    volumes:
      - ./clickhouse-ttl.xml:/etc/clickhouse-server/config.d/clickhouse-ttl.xml:ro
```

Tres trampas en este paso:

- **En `opentelemetry_span_log`, el TTL va dentro de `<engine>`.** La configuración estándar define esta tabla de registro con `<engine>` y, según la [documentación](https://clickhouse.com/docs/reference/system-tables/overview), eso entra en conflicto con `<ttl>`. En ese caso, el servidor se detiene con el error `If 'engine' is specified for system table, TTL parameters should be specified directly inside 'engine'` ([ClickHouse #88366](https://github.com/ClickHouse/ClickHouse/issues/88366)). Copia `PARTITION BY` y `ORDER BY` del resultado de `SELECT engine_full FROM system.tables WHERE database = 'system' AND name = 'opentelemetry_span_log'` (la configuración de SigNoz también ordena por `trace_id`). O desactiva esta tabla de registro con `<opentelemetry_span_log remove="1"/>` ([documentación de escalado](https://langfuse.com/self-hosting/configuration/scaling) de Langfuse). `remove` no elimina la tabla existente, así que elimínala tú.
- **Incluye solo las tablas de registro que tiene tu servidor.** Lo que activa una tabla de registro es su sección en la configuración (el `config.xml` estándar desactiva `session_log` dejando su sección comentada). El [`config.xml`](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml) propio de SigNoz no activa `text_log`, así que en SigNoz borra esa línea de `clickhouse-ttl.xml`. Añade también ahí `processors_profile_log`, que no tiene TTL en el `config.xml` de SigNoz.
- **Los ajustes de perfil van en users.d, no en config.d.** Si además desactivas el perfilador de consultas (`query_profiler_real_time_period_ns` y `query_profiler_cpu_time_period_ns` = 0, como en la documentación de escalado de Langfuse), pon ese bloque `<profiles>` en `users.d/`. En `config.d/` se ignora sin ningún aviso ([trigger.dev #4343](https://github.com/triggerdotdev/trigger.dev/issues/4343)).

### Paso 3: reinicia ClickHouse

El TTL de `config.d` solo entra en vigor cuando el servidor se reinicia
([Altinity KB](https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/)).
Recargar la configuración no basta. Con compose:

```sh
docker compose up -d clickhouse     # recrea el contenedor con el nuevo montaje
docker compose ps clickhouse
```

Si ClickHouse se reinicia una y otra vez, la causa está en su log de errores,
dentro del contenedor. `docker compose logs` puede no mostrarla:

```sh
docker cp "$(docker compose ps -aq clickhouse)":/var/log/clickhouse-server/clickhouse-server.err.log .
tail -n 20 clickhouse-server.err.log
```

### Paso 4: elimina las copias antiguas trace_log_0

Después del reinicio, cada tabla de registro modificada tiene una copia como
`trace_log_0` (y luego `_1`, `_2` tras cambios posteriores). La copia conserva
todas las filas antiguas y no tiene TTL (nota de actualización del PR #275 de
ClickStack, [Sentry snuba #7311](https://github.com/getsentry/snuba/issues/7311)).

Esta consulta genera las sentencias `DROP` por ti. Léelas y luego pégalas en el
cliente:

```sql
SELECT 'DROP TABLE system.' || name || ' SETTINGS max_table_size_to_drop = 0;'
FROM system.tables
WHERE database = 'system' AND match(name, '_log_[0-9]+$');
```

ClickHouse ya no escribe en estas tablas. `DROP` no se puede deshacer.

### Paso 5: comprueba el resultado

Vuelve a ejecutar la consulta del paso 1. Todas las tablas de registro grandes
deberían mostrar un TTL, y no debería quedar ningún nombre con `_N`.

ClickHouse elimina las filas caducadas durante las fusiones (merges), por
defecto como mucho una vez cada 4 horas
([`merge_with_ttl_timeout`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout)),
así que el tamaño irá bajando en las próximas horas.

Un script puede hacer la comprobación por ti:
[diskvet](https://github.com/Protemir/diskvet) ejecuta la comprobación del paso 1
en modo de solo lectura e imprime los comandos `TRUNCATE`, el archivo de TTL y la
lista de `DROP` para tus tablas, con el flag para las tablas que superan el
límite de eliminación (consulta la sección 7).

## 5. ¿El disco sigue lleno? A dónde más va el espacio

Compara `df -h` con el tamaño total de todas las partes
(`SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts`). Si en el
disco hay mucho más que eso, el espacio está fuera de las tablas de ClickHouse.

### ¿Los logs de los contenedores de Docker llenan el disco?

El driver de logs por defecto de Docker, `json-file`, no tiene límite de tamaño
(`max-size` vale `-1` por defecto; consulta la [documentación de Docker](https://docs.docker.com/engine/logging/drivers/json-file/)).
En [Langfuse #16339](https://github.com/langfuse/langfuse/issues/16339), el log
del contenedor de ClickHouse llegó a 89.1 GiB y llenó un disco raíz de 244 GiB.

Busca los más grandes:

```sh
sudo sh -c 'du -h /var/lib/docker/containers/*/*-json.log | sort -h | tail -5'
docker ps -a --no-trunc --format '{{.ID}} {{.Names}}'   # el nombre de la carpeta es el ID del contenedor
```

Para solucionarlo, añade un bloque `logging:` a cada servicio de
`docker-compose.yml`. En #16339, los mantenedores de Langfuse recomendaron
hacerlo en todos los contenedores, no solo en el de ClickHouse. El
[archivo compose](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml)
de SigNoz ya define `50m` × 3.

```yaml
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
```

Luego ejecuta `docker compose up -d --force-recreate`: las opciones de logs solo
afectan a los contenedores creados de nuevo. Al recrearlos también se elimina el
archivo de log antiguo; en #16339 eso liberó 81 GiB.

Dos observaciones:

- Si tu daemon de Docker usa otro driver de logs, configura la retención en ese driver en lugar de añadir este bloque, porque `driver: json-file` lo sustituye.
- El README de Langfuse ([PR #16363](https://github.com/langfuse/langfuse/pull/16363)) describe cómo hacerlo para todo el daemon: definir `max-size` y `max-file` como valores por defecto del daemon, reiniciar Docker y recrear los contenedores. También desaconseja truncar o rotar estos archivos con herramientas externas.

### ¿Son grandes los archivos de log del propio ClickHouse?

ClickHouse también escribe archivos de log normales en `/var/log/clickhouse-server`
(un volumen en el compose de Langfuse). Por defecto usan el nivel `trace`, rotan
al llegar a 1000M y se conservan hasta 10 archivos antiguos
([documentación de `logger`](https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger)).

El PR #275 de ClickStack usa los valores siguientes. Guárdalos en otro archivo de
`config.d`, móntalo igual que el archivo de TTL y reinicia ClickHouse (sección 4,
paso 3):

```xml
<clickhouse>
    <logger><level>information</level><size>100M</size><count>10</count></logger>
</clickhouse>
```

### ¿Por qué las filas eliminadas siguen ocupando espacio?

La retención de datos de Langfuse elimina las filas antiguas con una
[eliminación ligera (lightweight `DELETE`)](https://clickhouse.com/docs/reference/statements/delete).
ClickHouse solo marca esas filas; el espacio se recupera cuando la parte se
fusiona.

Las fusiones en segundo plano omiten las partes que superan
[`max_bytes_to_merge_at_max_space_in_pool`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool)
(150 GiB), y las particiones (partitions) mensuales antiguas casi nunca se
fusionan. En la
[discusión #13969 de Langfuse](https://github.com/orgs/langfuse/discussions/13969),
una partición de mayo de ~802 GiB estaba formada en un ~85% por filas eliminadas.

Busca las particiones con filas eliminadas:

```sql
SELECT database, table, partition_id, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active AND has_lightweight_delete
GROUP BY database, table, partition_id
ORDER BY sum(bytes_on_disk) DESC;
```

Luego aplica la máscara de eliminación partición por partición
([APPLY DELETED MASK](https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask)):

```sql
ALTER TABLE default.observations APPLY DELETED MASK IN PARTITION ID '202605';
```

**Cuidado:** es una mutación pesada (heavyweight mutation). Reescribe las partes afectadas,
así que necesita espacio libre para las copias nuevas y carga el disco.
Ejecútala en horas de poca carga y sigue su avance con
`SELECT * FROM system.mutations WHERE NOT is_done`. En #13969 liberó ~360 GiB por
réplica en ~17 minutos.

Desde v3.179.0, el worker de Langfuse puede hacerlo de forma programada:
`LANGFUSE_CLICKHOUSE_DELETED_MASK_CLEANER_ENABLED=true` (desactivado por
defecto; consulta `.env.prod.example`, [PR #14035](https://github.com/langfuse/langfuse/pull/14035)).

### ¿Hay partes antiguas atascadas en el disco? (partes inactivas y separadas)

```sql
SELECT database, table, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size,
       min(remove_time) AS oldest, max(refcount) AS max_refcount
FROM system.parts
WHERE NOT active
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC;
```

Las partes inactivas (inactive parts) son restos de las fusiones. ClickHouse las
elimina cuando transcurre el plazo de
[`old_parts_lifetime`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime)
(480 s) y ninguna consulta las usa ya (`refcount` = 1).

Si se acumulan (en la discusión #15024 de Langfuse llegaron a 112.55 GiB) y
`oldest` es de hace horas, busca consultas de larga duración en `system.processes` y
detenlas con `KILL QUERY WHERE query_id = '...'`.

Las partes separadas (detached parts) permanecen en el disco hasta que las
elimines:

```sql
SELECT database, table, reason, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.detached_parts
GROUP BY database, table, reason;
```

Revisa primero `reason`. Elimina una parte con
`ALTER TABLE <db>.<table> DROP DETACHED PART '<name>' SETTINGS allow_drop_detached = 1`,
en lugar de borrar carpetas.

## 6. ¿Vas a actualizar ClickHouse? Revisa esto antes

- **Langfuse + ClickHouse 26.8 o posterior: actualiza Langfuse primero.** ClickHouse 26.8 cambió el valor por defecto de `input_format_read_datetime_number_as_raw_value` de 1 a 0. Las versiones antiguas de Langfuse envían los valores `DateTime64` como números en milisegundos, y en 26.8+ acaban guardados como `9999-12-31 23:59:59` ([Langfuse #16858](https://github.com/langfuse/langfuse/issues/16858): del 0.59% al 21.43% de las escrituras, según el proyecto). La corrección llegó con el [PR #16892](https://github.com/langfuse/langfuse/pull/16892) (llevado también a v3 en el [PR #16957](https://github.com/langfuse/langfuse/pull/16957)) y está publicada en Langfuse v4.28.0 y v3.225.7. Langfuse particiona por mes, así que esas filas acaban en la partición `999912`. Revisa tu versión y búscalas:

  ```sql
  SELECT version();
  SELECT database, table, partition_id, count() AS parts
  FROM system.parts
  WHERE active AND startsWith(partition_id, '9999')
  GROUP BY database, table, partition_id;
  ```

- **Después de cualquier actualización, vuelve a ejecutar la consulta del paso 1 de la sección 4.** Cuando una versión cambia el esquema de una tabla de registro, ClickHouse renombra la tabla actual y crea una nueva, así que aparecen nuevas copias `_N`. Elimínalas como en el paso 4.

## 7. Comprueba todo de una vez

[diskvet](https://github.com/Protemir/diskvet) es un script de código abierto
(Apache-2.0) y de solo lectura que ejecuta la mayoría de las comprobaciones
anteriores e imprime un informe con los comandos para solucionar cada problema.
No puede ver los archivos de log de Docker, pero muestra cuánto espacio del
disco está fuera de las partes de ClickHouse. El informe está en inglés.

En la máquina con el `docker-compose.yml` de Langfuse (lee `checks.sql` antes de
ejecutarlo):

```sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
sh diskvet.sh report --docker auto > report.md
```

Para SigNoz, usa `--docker signoz-clickhouse`.

Solo lee metadatos de las tablas `system.*` (`system.tables`,
`system.parts`, `system.disks`, `system.detached_parts`, `system.mutations`,
`system.part_log` y algunas más), con `readonly=2` y límites de recursos. Nunca
lee filas de tus tablas, ni `system.query_log`, ni textos de consultas, y no
envía nada a ninguna parte. Nada se ejecuta por sí solo: tú lees cada
corrección y la ejecutas.

Pronto habrá una versión que revisará el servidor cada hora y avisará antes de
que el disco se llene (la beta gratuita empezará en octubre de 2026).

## Fuentes

Documentación y código fuente de ClickHouse:

- Descripción general de las tablas del sistema (crecimiento ilimitado, `<engine>` frente a `<ttl>`, cambio de nombre al cambiar el esquema): https://clickhouse.com/docs/reference/system-tables/overview
- `config.xml` por defecto (tablas de registro sin TTL, motor de `opentelemetry_span_log`, `text_log` y logger con nivel `trace`, `session_log` comentado): https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml
- `max_table_size_to_drop`, ajuste del servidor y `force_drop_table`: https://clickhouse.com/docs/reference/settings/server-settings/settings/max-table#max_table_size_to_drop
- `max_table_size_to_drop`, ajuste de consulta: https://clickhouse.com/docs/reference/settings/session-settings/max#max_table_size_to_drop
- Cambio del límite a nivel de consulta desde 23.12: https://github.com/ClickHouse/ClickHouse/pull/57452
- El flag se elimina después de usarse (`checkCanBeDropped`): https://github.com/ClickHouse/ClickHouse/blob/master/src/Interpreters/Context.cpp
- TRUNCATE: https://clickhouse.com/docs/reference/statements/truncate
- Error de TTL en `opentelemetry_span_log`: https://github.com/ClickHouse/ClickHouse/issues/88366
- Ajustes de MergeTree: `merge_with_ttl_timeout` (14400 s) https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout, `old_parts_lifetime` (480 s) https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime, `max_bytes_to_merge_at_max_space_in_pool` (150 GiB) https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool
- Rotación del log del servidor (`logger`: `level`, `size`, `count`): https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger
- Eliminación ligera (lightweight DELETE): https://clickhouse.com/docs/reference/statements/delete
- APPLY DELETED MASK: https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask
- system.parts: https://clickhouse.com/docs/reference/system-tables/parts
- system.detached_parts: https://clickhouse.com/docs/reference/system-tables/detached_parts
- DROP DETACHED PART: https://clickhouse.com/docs/reference/statements/alter/partition
- `allow_drop_detached`: https://clickhouse.com/docs/reference/settings/session-settings/allow#allow_drop_detached
- system.mutations: https://clickhouse.com/docs/reference/system-tables/mutations
- KILL QUERY: https://clickhouse.com/docs/reference/statements/kill
- Altinity KB, «System tables ate my disk» (hace falta reiniciar): https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/

Docker:

- Driver de logs json-file (`max-size` vale -1 por defecto; los contenedores existentes mantienen los ajustes antiguos): https://docs.docker.com/engine/logging/drivers/json-file/

Langfuse:

- FAQ, cómo reducir el tamaño de ClickHouse en disco: https://langfuse.com/faq/all/reduce-clickhouse-disk-size
- Documentación de escalado, tablas de registro del sistema de ClickHouse: https://langfuse.com/self-hosting/configuration/scaling
- #13123, las tablas del sistema crecen sin límite: https://github.com/langfuse/langfuse/issues/13123
- #16339, log de Docker sin límite: https://github.com/langfuse/langfuse/issues/16339
- PR #16363, rotación de logs de Docker en el README (valores por defecto del daemon, sin truncado externo): https://github.com/langfuse/langfuse/pull/16363
- Discusión #13969, filas con eliminación ligera: https://github.com/orgs/langfuse/discussions/13969
- Discusión #15024, partes inactivas y text_log de 59 GiB: https://github.com/orgs/langfuse/discussions/15024
- PR #14035, limpieza con la máscara de eliminación (publicada en v3.179.0): https://github.com/langfuse/langfuse/pull/14035, https://github.com/langfuse/langfuse/releases/tag/v3.179.0
- #16858, DateTime64 en ClickHouse 26.8+: https://github.com/langfuse/langfuse/issues/16858
- PR #16892 y su versión para v3, PR #16957: https://github.com/langfuse/langfuse/pull/16892, https://github.com/langfuse/langfuse/pull/16957
- Versiones con la corrección: https://github.com/langfuse/langfuse/releases/tag/v4.28.0, https://github.com/langfuse/langfuse/releases/tag/v3.225.7

SigNoz, ClickStack y otros:

- SigNoz #12050, más de 80 GB en tablas de registro del sistema: https://github.com/SigNoz/signoz/issues/12050
- `config.xml` y `users.xml` de ClickHouse en SigNoz v0.129.0: https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml, https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/users.xml
- `docker-compose.yaml` de SigNoz v0.129.0 (contenedor `signoz-clickhouse`, `max-size: 50m`, `max-file: "3"`): https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml
- Chart de Helm de ClickStack, PR #275: https://github.com/ClickHouse/ClickStack-helm-charts/pull/275
- Sentry snuba #7311, copias `*_log_N` sin TTL: https://github.com/getsentry/snuba/issues/7311
- trigger.dev #4343, ajustes de perfil ignorados en config.d: https://github.com/triggerdotdev/trigger.dev/issues/4343

---

ClickHouse es una marca registrada de ClickHouse, Inc. diskvet no está afiliado a ClickHouse, Inc.
Langfuse, SigNoz y ClickStack son marcas de sus respectivos propietarios.
