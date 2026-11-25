# Ledger stores

A domain receives an explicit store as a module or `{module, options}`. Store configuration belongs to the host. Governance operations use the same public API for every adapter.

| Adapter under `ExGAM.Ledger.Store` | Host wiring | Lifetime |
| --- | --- | --- |
| `ETS` | Supervise `{ETS, name: MyApp.Ledger}` and pass `{ETS, server: MyApp.Ledger}`. | One owner process. Development and ephemeral work. |
| `Disk` | Supervise `{Disk, name: MyApp.Ledger, path: directory}` and pass `{Disk, server: MyApp.Ledger}`. | Local directory with a single writer and filesystem durability barriers. |
| `Mnesia` | Provision the Mnesia schema and durable replicas, call `Mnesia.ensure_tables/1`, then pass the adapter with the same table options. | Transactional durable tables with majority commits. |
| `Postgres` | Provide an application-owned Ecto Repo, migrate the database and pass `{Postgres, repo: MyApp.Repo, table_prefix: "gam"}`. | PostgreSQL transaction commit. The host manages connections, backups and database durability. |

Aliases in this table refer to the adapter modules. The bundled `Mock` can wrap another store to exercise conflicting appends and ambiguous acknowledgements.

## PostgreSQL with an Ecto Repo

Include `:ecto_sql` and `:postgrex` in the **host** dependencies and supervise a Repo using `Ecto.Adapters.Postgres`. ETS and Disk users need neither package. Generate the SQL once using the exact schema and table prefix selected for the domain.

```elixir
alias ExGAM.Ledger.Store.Postgres

{:ok, %{up: up, down: down}} =
  Postgres.migration_sql(schema: "public", table_prefix: "gam")
```

Copy the statements from `up` and `down` into the corresponding directions of a versioned host migration, in the returned order. Each list item is one statement and can be passed to `Ecto.Migration.execute/1`. Freezing that SQL in the migration keeps historical migrations reproducible across library upgrades. Apply the migration before starting the domain.

```elixir
store = {ExGAM.Ledger.Store.Postgres, repo: MyApp.Repo, schema: "public", table_prefix: "gam"}
ExGAM.start_domain(domain_ref, store, host_options)
```

The adapter uses a per-domain advisory lock, a revision check and a transaction for the batch and its head. Writes request synchronous commit. PostgreSQL must provide the durability and failover guarantees advertised by the host. A custom schema must already exist. For an existing installation use its original schema and table names. The default table prefix is `spectre_ledger`. See `ExGAM.Ledger.Store.Postgres.migration_sql/1` for the generated DDL.

## Implement a different database

Declare `@behaviour ExGAM.Ledger.Store` and implement these callbacks.

| Callback | Contract |
| --- | --- |
| `append(domain, batch_id, payloads, expected_revision, opts)` | Commit all entries, the identity index and the new head atomically. Enforce the expected predecessor. A matching replay returns the original committed revision, a changed batch identity must be rejected, and a stale competing writer gets a conflict. |
| `lookup_batch(domain, batch_id, opts)` | Retrieve the committed batch coordinates and identity, or return `:not_found`. This lets recovery distinguish a committed retry from a fresh append. |
| `load(domain, opts)` | Read a coherent snapshot with a matching head. Return `:not_found` for an absent domain. |
| `export(domain, opts)` | Export a coherent canonical representation suitable for verification. |
| `load_from/3` | Optional indexed suffix read. The ledger layer can fall back to a full snapshot. |
| `head/2`, `read_batch/3` | Optional indexed head and complete batch reads. Configure both when using a separate projection store. |

Use the canonical entry and identity routines in `ExGAM.Ledger.Entry`. A successful append acknowledges the stated durability boundary. If commit may have happened but its acknowledgement was lost, return `{:error, :ambiguous}` so the domain can resolve it by batch ID. Serialize competing writers in the backend across the whole deployment. The application should hold one authoritative history per domain.

The development suite covers duplicate identities, conflicting revisions, read-after-restart and lost acknowledgement. See `ExGAM.Ledger.Store` for the callbacks and `ExGAM.Ledger.Store.ETS` for a reference implementation. [PostgreSQL contract tests](https://github.com/elchemista/ex_gam/blob/main/test/gam/core/postgres_adapter_test.exs)
