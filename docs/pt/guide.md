# Por que o disco do ClickHouse® fica cheio no Langfuse e no SigNoz auto-hospedados e como resolver

*[English](../guide.md) · [Español](../es/guide.md) · [Русский](../ru/guide.md) · [日本語](../ja/guide.md) · [中文](../zh/guide.md). Se as versões divergirem, vale a versão em inglês.*

Seu servidor do Langfuse ou do SigNoz está ficando sem espaço em disco, mas os
seus traces são pequenos. Na maioria dos relatos públicos, quem ocupa o espaço é
o próprio ClickHouse®, com as tabelas de log do sistema (system log tables),
como `system.trace_log` e `system.text_log`, que por padrão não têm limite de
tamanho. O ClickStack tem o mesmo problema.

Este guia mostra como confirmar isso com uma única consulta somente leitura,
liberar o espaço agora e evitar que o problema volte sem cair nas armadilhas
conhecidas. Você não precisa de nenhuma ferramenta extra.

*Testado com as imagens padrão de `clickhouse/clickhouse-server` 24.8, 25.12 e
26.9 (os comandos do SigNoz, com 25.5 e 25.12), com o serviço e a configuração
do ClickHouse tirados dos arquivos compose do Langfuse e do SigNoz.*

## Resumo

1. **Verifique.** Execute uma consulta somente leitura em `system.parts`. Se as tabelas `system.*_log` forem maiores que os seus dados, o problema são os logs do próprio ClickHouse.
2. **Libere espaço agora.** Esvazie os logs grandes com `TRUNCATE`. Para uma tabela acima de 50 GB, adicione `SETTINGS max_table_size_to_drop = 0`.
3. **Evite que volte.** Adicione um arquivo em `config.d` com um TTL (tempo de vida) para cada log (no `opentelemetry_span_log`, o TTL vai dentro de `<engine>`) e depois reinicie o ClickHouse.
4. **Faça a limpeza.** Remova as cópias `*_log_0`, `*_log_1` que a reinicialização deixa para trás.
5. **Continua cheio?** Verifique os logs dos contêineres Docker, as linhas excluídas e as partes (parts) presas no disco. No Langfuse, atualize o Langfuse antes de passar o ClickHouse para a 26.8+.

## 1. O que está ocupando o disco? Uso de disco do ClickHouse por tabela

Salve esta consulta como `size.sql`. Ela lista as maiores tabelas por tamanho
em disco:

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

**Langfuse (docker compose).** Execute isto na pasta onde está o
`docker-compose.yml` do Langfuse. O arquivo compose dele já define
`CLICKHOUSE_USER` e `CLICKHOUSE_PASSWORD` dentro do contêiner:

```sh
docker compose exec -T clickhouse sh -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --readonly=1 --format PrettyCompact' < size.sql
```

**SigNoz (docker compose).** O contêiner geralmente se chama
`signoz-clickhouse` (confira com `docker ps`). O `users.xml` do SigNoz deixa o
usuário `default` sem senha:

```sh
docker exec -i signoz-clickhouse clickhouse-client --readonly=1 --format PrettyCompact < size.sql
```

`--readonly=1` deixa a sessão em modo somente leitura: o ClickHouse recusa
qualquer alteração.

**Como interpretar.** Compare as linhas de `system` com os seus próprios dados
(`default` no Langfuse, `signoz_*` no SigNoz). Se `system.trace_log` ou
`system.text_log` estiver no topo, vá para a seção 2.

## 2. Como liberar espaço em disco agora mesmo?

Abra um cliente com permissão de escrita:

```sh
# Langfuse
docker compose exec clickhouse sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD"'
# SigNoz
docker exec -it signoz-clickhouse clickhouse-client
```

Esvazie os logs grandes:

```sql
TRUNCATE TABLE system.trace_log;
TRUNCATE TABLE system.text_log;
TRUNCATE TABLE system.metric_log;
TRUNCATE TABLE system.query_log;
```

Isso exclui apenas os dados de diagnóstico do próprio ClickHouse, não os seus
traces, e não exige reinicialização.

O Langfuse lê o `system.query_log` para acompanhar algumas consultas que ele
mesmo executa ([#13123](https://github.com/langfuse/langfuse/issues/13123)). Por
isso, esvazie essa tabela, mas não a desative.

### TRUNCATE falha com Code 359? Tabelas acima de 50 GB

O ClickHouse se recusa a remover ou esvaziar uma tabela maior que
`max_table_size_to_drop` (padrão: 50.000.000.000 bytes, cerca de 46,6 GiB). O
limite também vale para `TRUNCATE`, e com uma tabela maior o comando falha com
`Code: 359 ... (TABLE_SIZE_EXCEEDS_MAX_DROP_SIZE_LIMIT)`.

Logs grandes chegam, sim, a esse limite: o `text_log` da
[discussão #15024 do Langfuse](https://github.com/orgs/langfuse/discussions/15024)
tinha 59,20 GiB. Há duas formas de contornar isso.

**Opção A.** Desative o limite para um único comando:

```sql
-- ClickHouse 23.12+: desativa o limite só para este comando
TRUNCATE TABLE system.text_log SETTINGS max_table_size_to_drop = 0;
```

**Opção B.** Crie o arquivo de flag de uso único e depois execute o `TRUNCATE`
normal:

```sh
docker compose exec clickhouse sh -c 'touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table'
```

(SigNoz: `docker exec signoz-clickhouse sh -c '...'` com o mesmo comando.)
O ClickHouse apaga a flag depois do primeiro `DROP` ou `TRUNCATE` que precisar
dela, então crie-a de novo antes da próxima tabela grande.

O espaço voltou, mas os logs recomeçam a crescer imediatamente. A seção 4
impede isso. A seção 3 explica por que acontece.

## 3. Por que o trace_log e o text_log ficam tão grandes?

O ClickHouse grava os próprios dados de diagnóstico em tabelas do banco de
dados `system`: `query_log`, `trace_log`, `text_log`, `metric_log` e outras. A
[documentação](https://clickhouse.com/docs/reference/system-tables/overview)
diz com todas as letras: “By default, table growth is unlimited.” (Por padrão,
o crescimento da tabela é ilimitado.)

As [configurações padrão](https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml)
recentes definem um TTL só para alguns logs pequenos (desde a 25.9, o
`processors_profile_log` guarda 30 dias), não para os grandes. Dois valores
padrão fazem os grandes crescerem rápido:

- o profiler de consultas (query profiler) fica ligado e grava em `trace_log` amostras de pilha (stack samples) das consultas em execução;
- o `text_log` armazena o log do servidor no nível `trace`.

Exemplos públicos:

- **Langfuse [#13123](https://github.com/langfuse/langfuse/issues/13123):** o `system.trace_log` tinha 66,86 GiB, enquanto as tabelas do Langfuse listadas ali (`traces`, `observations`, `scores`) somavam cerca de 51 MiB. Os mantenedores decidiram não alterar os padrões do ClickHouse e, em vez disso, adicionaram uma [página de FAQ](https://langfuse.com/faq/all/reduce-clickhouse-disk-size).
- **SigNoz [#12050](https://github.com/SigNoz/signoz/issues/12050):** mais de 80 GB de logs do sistema (incluindo uma cópia `trace_log_0`) contra menos de 500 MB de telemetria. Esvaziar as tabelas `system.*` liberou cerca de 80 GB. O novo instalador Foundry do SigNoz define TTLs; instalações mais antigas com docker compose não têm.
- **Chart do Helm do ClickStack, [PR #275](https://github.com/ClickHouse/ClickStack-helm-charts/pull/275):** um volume de 10 Gi chegou a 100% depois de 10 dias, com 5,2 GB de logs do servidor em nível trace e um `system.text_log` de 3,7 GB, contra ~70 MB de telemetria. O PR, incorporado em setembro de 2026, adiciona um TTL de 7 dias.

## 4. Como configurar um TTL nas tabelas de log do sistema do ClickHouse?

Um TTL faz o ClickHouse excluir sozinho as linhas antigas dos logs. Configure-o
**depois** do `TRUNCATE` da seção 2, por causa da forma como o ClickHouse o
aplica.

Quando você adiciona um TTL e reinicia o servidor, o ClickHouse não reduz a
tabela antiga. Ele a renomeia para `trace_log_0`, com todas as linhas, e cria
uma nova com o TTL. Se você esvaziou a tabela antes, essas cópias são
minúsculas, e o passo 4 as remove.

Execute o SQL abaixo no mesmo cliente com permissão de escrita da seção 2.

### Passo 1: quais logs não têm TTL?

```sql
SELECT name,
       formatReadableSize(total_bytes) AS size,
       extract(engine_full, 'TTL [^S]*') AS ttl
FROM system.tables
WHERE database = 'system' AND engine LIKE '%MergeTree' AND match(name, '_log(_[0-9]+)?$')
ORDER BY total_bytes DESC;
```

Um `ttl` vazio significa que o log é mantido para sempre. Nomes como
`trace_log_0` são cópias antigas; o passo 4 as remove.

### Passo 2: adicione um arquivo de TTL em config.d

Salve isto como `clickhouse-ttl.xml` ao lado do `docker-compose.yml`:

```xml
<clickhouse>
    <!-- Mantém 7 dias dos logs do próprio ClickHouse. Liste só os logs que o seu servidor tem. -->
    <query_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></query_log>
    <trace_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></trace_log>
    <text_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></text_log>
    <metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></metric_log>
    <asynchronous_metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></asynchronous_metric_log>
    <part_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></part_log>

    <!-- A configuração padrão define este log com <engine>, então um <ttl> separado
         impede o servidor de iniciar (ClickHouse#88366). O TTL vai dentro. -->
    <opentelemetry_span_log>
        <engine>ENGINE = MergeTree PARTITION BY toYYYYMM(finish_date) ORDER BY (finish_date, finish_time_us) TTL finish_date + INTERVAL 7 DAY DELETE</engine>
    </opentelemetry_span_log>
</clickhouse>
```

Monte-o no serviço `clickhouse` (mantenha as linhas de volume que você já tem):

```yaml
  clickhouse:
    volumes:
      - ./clickhouse-ttl.xml:/etc/clickhouse-server/config.d/clickhouse-ttl.xml:ro
```

Três armadilhas neste passo:

- **O `opentelemetry_span_log` recebe o TTL dentro de `<engine>`.** A configuração padrão define esse log com `<engine>` e, segundo a [documentação](https://clickhouse.com/docs/reference/system-tables/overview), isso entra em conflito com `<ttl>`. O servidor então é encerrado com o erro `If 'engine' is specified for system table, TTL parameters should be specified directly inside 'engine'` ([ClickHouse #88366](https://github.com/ClickHouse/ClickHouse/issues/88366)). Copie `PARTITION BY` e `ORDER BY` do resultado de `SELECT engine_full FROM system.tables WHERE database = 'system' AND name = 'opentelemetry_span_log'` (a configuração do SigNoz também ordena por `trace_id`). Ou desative o log com `<opentelemetry_span_log remove="1"/>` ([documentação de escalabilidade](https://langfuse.com/self-hosting/configuration/scaling) do Langfuse). `remove` não exclui a tabela existente, então remova-a você mesmo.
- **Liste só os logs que o seu servidor tem.** O que ativa um log é a seção dele na configuração (o `config.xml` padrão desativa o `session_log` deixando a seção dele comentada). O [`config.xml`](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml) do próprio SigNoz não ativa o `text_log`, então, no SigNoz, apague essa linha. Adicione também o `processors_profile_log`, que não tem TTL nesse arquivo.
- **Configurações de perfil ficam em users.d, não em config.d.** Se você também desligar o profiler de consultas (`query_profiler_real_time_period_ns` e `query_profiler_cpu_time_period_ns` = 0, como na documentação de escalabilidade do Langfuse), coloque esse bloco `<profiles>` em `users.d/`. Em `config.d/`, ele é ignorado silenciosamente ([trigger.dev #4343](https://github.com/triggerdotdev/trigger.dev/issues/4343)).

### Passo 3: reinicie o ClickHouse

O TTL de `config.d` só entra em vigor quando o servidor reinicia
([Altinity KB](https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/)).
Recarregar a configuração não basta. Com compose:

```sh
docker compose up -d clickhouse     # recria o contêiner com a nova montagem
docker compose ps clickhouse
```

Se o ClickHouse ficar reiniciando sem parar, o motivo está no log de erros
dele, dentro do contêiner. O `docker compose logs` pode não mostrá-lo:

```sh
docker cp "$(docker compose ps -aq clickhouse)":/var/log/clickhouse-server/clickhouse-server.err.log .
tail -n 20 clickhouse-server.err.log
```

### Passo 4: remova as cópias antigas trace_log_0

Depois da reinicialização, cada log alterado tem uma cópia como `trace_log_0`
(e depois `_1`, `_2` a cada nova alteração). A cópia mantém todas as linhas
antigas e não tem TTL (nota de atualização do PR #275 do ClickStack,
[Sentry snuba #7311](https://github.com/getsentry/snuba/issues/7311)).

Esta consulta gera os comandos `DROP` para você. Leia-os e depois cole-os no
cliente:

```sql
SELECT 'DROP TABLE system.' || name || ' SETTINGS max_table_size_to_drop = 0;'
FROM system.tables
WHERE database = 'system' AND match(name, '_log_[0-9]+$');
```

O ClickHouse não grava mais nessas tabelas. `DROP` não pode ser desfeito.

### Passo 5: confira o resultado

Execute de novo a consulta do passo 1. Todo log grande deve mostrar um TTL, e
não deve sobrar nenhum nome com `_N`.

O ClickHouse remove as linhas expiradas durante as mesclagens (merges), por
padrão no máximo uma vez a cada 4 horas
([`merge_with_ttl_timeout`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout)),
então o tamanho diminui ao longo das próximas horas.

Um script pode fazer a verificação por você: o
[diskvet](https://github.com/Protemir/diskvet) executa a verificação do passo 1
em modo somente leitura e imprime os comandos `TRUNCATE`, o arquivo de TTL e a
lista de `DROP` para as suas tabelas, com a flag para as tabelas acima do
limite de remoção (veja a seção 7).

## 5. O disco continua cheio? Para onde mais vai o espaço

Compare o `df -h` com o tamanho total de todas as partes
(`SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts`). Se o uso do
disco for muito maior que isso, o espaço está fora das tabelas do ClickHouse.

### Os logs dos contêineres Docker estão enchendo o disco?

O driver de log padrão do Docker, `json-file`, não tem limite de tamanho (o
padrão de `max-size` é `-1`; veja a [documentação do Docker](https://docs.docker.com/engine/logging/drivers/json-file/)).
No [Langfuse #16339](https://github.com/langfuse/langfuse/issues/16339), o log
do contêiner do ClickHouse chegou a 89,1 GiB e encheu um disco raiz de 244 GiB.

Encontre os maiores:

```sh
sudo sh -c 'du -h /var/lib/docker/containers/*/*-json.log | sort -h | tail -5'
docker ps -a --no-trunc --format '{{.ID}} {{.Names}}'   # o nome da pasta é o ID do contêiner
```

Para resolver, adicione um bloco `logging:` a cada serviço do
`docker-compose.yml`. No #16339, os mantenedores do Langfuse recomendaram fazer
isso em todos os contêineres, não só no do ClickHouse. O
[arquivo compose](https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml)
do SigNoz já define `50m` × 3.

```yaml
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
```

Depois execute `docker compose up -d --force-recreate`: as opções de log só
valem para contêineres recém-criados. Recriar também remove o arquivo de log
antigo; no #16339, isso liberou 81 GiB.

Duas observações:

- Se o seu daemon do Docker usa outro driver de log, configure a retenção nesse driver em vez de adicionar este bloco, porque `driver: json-file` o substitui.
- O README do Langfuse ([PR #16363](https://github.com/langfuse/langfuse/pull/16363)) descreve como fazer isso para o daemon inteiro: definir `max-size` e `max-file` como padrões do daemon, depois reiniciar o Docker e recriar os contêineres. Ele também desaconselha truncar ou rotacionar esses arquivos com ferramentas externas.

### Os arquivos de log do próprio ClickHouse estão grandes?

O ClickHouse também grava arquivos de log comuns em `/var/log/clickhouse-server`
(um volume no compose do Langfuse). Por padrão, eles ficam no nível `trace`,
são rotacionados ao atingir 1000M e até 10 arquivos antigos são mantidos
([documentação do `logger`](https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger)).

O PR #275 do ClickStack usa os valores abaixo. Salve-os como outro arquivo em
`config.d`, monte-o da mesma forma que o arquivo de TTL e reinicie o ClickHouse (seção 4,
passo 3):

```xml
<clickhouse>
    <logger><level>information</level><size>100M</size><count>10</count></logger>
</clickhouse>
```

### Por que linhas excluídas continuam ocupando espaço?

A retenção de dados do Langfuse remove as linhas antigas com uma
[exclusão leve (lightweight `DELETE`)](https://clickhouse.com/docs/reference/statements/delete).
O ClickHouse apenas marca essas linhas; o espaço volta quando a parte passa por
uma mesclagem.

As mesclagens em segundo plano ignoram partes maiores que
[`max_bytes_to_merge_at_max_space_in_pool`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool)
(150 GiB), e partições (partitions) mensais antigas raramente são mescladas. Na
[discussão #13969 do Langfuse](https://github.com/orgs/langfuse/discussions/13969),
uma partição de maio de ~802 GiB tinha ~85% de linhas excluídas.

Encontre as partições com linhas excluídas:

```sql
SELECT database, table, partition_id, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active AND has_lightweight_delete
GROUP BY database, table, partition_id
ORDER BY sum(bytes_on_disk) DESC;
```

Depois aplique a máscara de exclusão, uma partição por vez
([APPLY DELETED MASK](https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask)):

```sql
ALTER TABLE default.observations APPLY DELETED MASK IN PARTITION ID '202605';
```

**Cuidado:** esta é uma mutação pesada (heavyweight mutation). Ela reescreve as partes
afetadas, então precisa de espaço livre para as novas cópias e gera carga no
disco. Execute-a fora do horário de pico e acompanhe com
`SELECT * FROM system.mutations WHERE NOT is_done`. No #13969, ela liberou
~360 GiB por réplica em ~17 minutos.

Desde a v3.179.0, o worker do Langfuse pode fazer isso de forma agendada:
`LANGFUSE_CLICKHOUSE_DELETED_MASK_CLEANER_ENABLED=true` (desativado por padrão;
veja `.env.prod.example`, [PR #14035](https://github.com/langfuse/langfuse/pull/14035)).

### Há partes antigas presas no disco? (partes inativas e desanexadas)

```sql
SELECT database, table, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size,
       min(remove_time) AS oldest, max(refcount) AS max_refcount
FROM system.parts
WHERE NOT active
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC;
```

As partes inativas (inactive parts) são sobras das mesclagens. O ClickHouse as
exclui depois de
[`old_parts_lifetime`](https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime)
(480 s), quando nenhuma consulta as usa mais (`refcount` = 1).

Se elas se acumularem (na discussão #15024 do Langfuse, chegaram a 112,55 GiB) e
`oldest` for de horas atrás, procure consultas demoradas em `system.processes` e
interrompa-as com `KILL QUERY WHERE query_id = '...'`.

As partes desanexadas (detached parts) ficam no disco até você removê-las:

```sql
SELECT database, table, reason, count() AS parts,
       formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.detached_parts
GROUP BY database, table, reason;
```

Verifique `reason` primeiro. Remova uma parte com
`ALTER TABLE <db>.<table> DROP DETACHED PART '<name>' SETTINGS allow_drop_detached = 1`,
em vez de apagar pastas.

## 6. Vai atualizar o ClickHouse? Confira isto antes

- **Langfuse + ClickHouse 26.8 ou mais recente: atualize o Langfuse primeiro.** O ClickHouse 26.8 mudou o padrão de `input_format_read_datetime_number_as_raw_value` de 1 para 0. Versões mais antigas do Langfuse enviam valores `DateTime64` como números em milissegundos, e na 26.8+ eles acabam gravados como `9999-12-31 23:59:59` ([Langfuse #16858](https://github.com/langfuse/langfuse/issues/16858): de 0,59% a 21,43% das gravações por projeto). A correção é o [PR #16892](https://github.com/langfuse/langfuse/pull/16892) (portado para a v3 no [PR #16957](https://github.com/langfuse/langfuse/pull/16957)), lançado no Langfuse v4.28.0 e v3.225.7. O Langfuse particiona por mês, então essas linhas vão parar na partição `999912`. Verifique a sua versão e procure por elas:

  ```sql
  SELECT version();
  SELECT database, table, partition_id, count() AS parts
  FROM system.parts
  WHERE active AND startsWith(partition_id, '9999')
  GROUP BY database, table, partition_id;
  ```

- **Depois de qualquer atualização, execute de novo a consulta do passo 1 da seção 4.** Quando uma versão muda o esquema de um log, o ClickHouse renomeia a tabela atual e cria uma nova, então surgem novas cópias `_N`. Remova-as como no passo 4.

## 7. Verifique tudo de uma vez

O [diskvet](https://github.com/Protemir/diskvet) é um script de código aberto
(Apache-2.0) e somente leitura que executa a maioria das verificações acima e
imprime um relatório com os comandos de correção. Ele não consegue ver os
arquivos de log do Docker, mas mostra quanto do disco está fora das partes do
ClickHouse. O relatório é em inglês.

Na máquina com o `docker-compose.yml` do Langfuse (leia o `checks.sql` antes de
executá-lo):

```sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/diskvet.sh
curl -fsSLO https://github.com/Protemir/diskvet/releases/latest/download/checks.sql
sh diskvet.sh report --docker auto > report.md
```

Para o SigNoz, use `--docker signoz-clickhouse`.

Ele lê apenas metadados das tabelas `system.*` (`system.tables`,
`system.parts`, `system.disks`, `system.detached_parts`, `system.mutations`,
`system.part_log` e mais algumas), com `readonly=2` e limites de recursos. Ele
nunca lê as linhas das suas tabelas, nem o `system.query_log`, nem o texto das
consultas, e não envia nada para lugar nenhum. Nada é executado sozinho: você lê cada
correção e a executa.

Uma versão que roda a cada hora e avisa antes de o disco encher está a caminho
(um beta gratuito será aberto em outubro de 2026).

## Fontes

Documentação e código-fonte do ClickHouse:

- Visão geral das tabelas do sistema (crescimento ilimitado, `<engine>` versus `<ttl>`, renomeação ao mudar o esquema): https://clickhouse.com/docs/reference/system-tables/overview
- `config.xml` padrão (logs sem TTL, motor de tabela do `opentelemetry_span_log`, `text_log` e logger em `trace`, `session_log` comentado): https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/config.xml
- `max_table_size_to_drop`, configuração do servidor e `force_drop_table`: https://clickhouse.com/docs/reference/settings/server-settings/settings/max-table#max_table_size_to_drop
- `max_table_size_to_drop`, configuração de consulta: https://clickhouse.com/docs/reference/settings/session-settings/max#max_table_size_to_drop
- Ajuste do limite no nível da consulta desde a 23.12: https://github.com/ClickHouse/ClickHouse/pull/57452
- A flag é removida após o uso (`checkCanBeDropped`): https://github.com/ClickHouse/ClickHouse/blob/master/src/Interpreters/Context.cpp
- TRUNCATE: https://clickhouse.com/docs/reference/statements/truncate
- Erro de TTL no `opentelemetry_span_log`: https://github.com/ClickHouse/ClickHouse/issues/88366
- Configurações do MergeTree: `merge_with_ttl_timeout` (14.400 s) https://clickhouse.com/docs/reference/settings/merge-tree-settings/merge-with#merge_with_ttl_timeout, `old_parts_lifetime` (480 s) https://clickhouse.com/docs/reference/settings/merge-tree-settings/other#old_parts_lifetime, `max_bytes_to_merge_at_max_space_in_pool` (150 GiB) https://clickhouse.com/docs/reference/settings/merge-tree-settings/max-bytes#max_bytes_to_merge_at_max_space_in_pool
- Rotação do log do servidor (`logger`: `level`, `size`, `count`): https://clickhouse.com/docs/reference/settings/server-settings/settings/other#logger
- Exclusão leve (lightweight DELETE): https://clickhouse.com/docs/reference/statements/delete
- APPLY DELETED MASK: https://clickhouse.com/docs/reference/statements/alter/apply-deleted-mask
- system.parts: https://clickhouse.com/docs/reference/system-tables/parts
- system.detached_parts: https://clickhouse.com/docs/reference/system-tables/detached_parts
- DROP DETACHED PART: https://clickhouse.com/docs/reference/statements/alter/partition
- `allow_drop_detached`: https://clickhouse.com/docs/reference/settings/session-settings/allow#allow_drop_detached
- system.mutations: https://clickhouse.com/docs/reference/system-tables/mutations
- KILL QUERY: https://clickhouse.com/docs/reference/statements/kill
- Altinity KB, “System tables ate my disk” (é preciso reiniciar): https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-system-tables-eat-my-disk/

Docker:

- Driver de log json-file (o padrão de `max-size` é -1; contêineres existentes mantêm as configurações antigas): https://docs.docker.com/engine/logging/drivers/json-file/

Langfuse:

- FAQ, como reduzir o tamanho do ClickHouse em disco: https://langfuse.com/faq/all/reduce-clickhouse-disk-size
- Documentação de escalabilidade, tabelas de log do sistema do ClickHouse: https://langfuse.com/self-hosting/configuration/scaling
- #13123, tabelas do sistema crescem sem limite: https://github.com/langfuse/langfuse/issues/13123
- #16339, log do Docker sem limite: https://github.com/langfuse/langfuse/issues/16339
- PR #16363, rotação de logs do Docker no README (padrões do daemon, sem truncamento externo): https://github.com/langfuse/langfuse/pull/16363
- Discussão #13969, linhas com exclusão leve: https://github.com/orgs/langfuse/discussions/13969
- Discussão #15024, partes inativas e text_log de 59 GiB: https://github.com/orgs/langfuse/discussions/15024
- PR #14035, limpeza com a máscara de exclusão (lançada na v3.179.0): https://github.com/langfuse/langfuse/pull/14035, https://github.com/langfuse/langfuse/releases/tag/v3.179.0
- #16858, DateTime64 no ClickHouse 26.8+: https://github.com/langfuse/langfuse/issues/16858
- PR #16892 e a versão portada para a v3, PR #16957: https://github.com/langfuse/langfuse/pull/16892, https://github.com/langfuse/langfuse/pull/16957
- Versões com a correção: https://github.com/langfuse/langfuse/releases/tag/v4.28.0, https://github.com/langfuse/langfuse/releases/tag/v3.225.7

SigNoz, ClickStack e outros:

- SigNoz #12050, mais de 80 GB de logs do sistema: https://github.com/SigNoz/signoz/issues/12050
- `config.xml` e `users.xml` do ClickHouse no SigNoz v0.129.0: https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/config.xml, https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/common/clickhouse/users.xml
- `docker-compose.yaml` do SigNoz v0.129.0 (contêiner `signoz-clickhouse`, `max-size: 50m`, `max-file: "3"`): https://github.com/SigNoz/signoz/blob/v0.129.0/deploy/docker/docker-compose.yaml
- Chart do Helm do ClickStack, PR #275: https://github.com/ClickHouse/ClickStack-helm-charts/pull/275
- Sentry snuba #7311, cópias `*_log_N` sem TTL: https://github.com/getsentry/snuba/issues/7311
- trigger.dev #4343, configurações de perfil ignoradas em config.d: https://github.com/triggerdotdev/trigger.dev/issues/4343

---

ClickHouse é uma marca registrada da ClickHouse, Inc. O diskvet não é afiliado à ClickHouse, Inc.
Langfuse, SigNoz e ClickStack são marcas de seus respectivos proprietários.
