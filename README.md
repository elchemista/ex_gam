# ExGAM

[![CI on main](https://github.com/elchemista/ex_gam/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/elchemista/ex_gam/actions/workflows/ci.yml?query=branch%3Amain)
[![Hex.pm version](https://img.shields.io/hexpm/v/ex_gam?label=Hex.pm)](https://hex.pm/packages/ex_gam)
[![Hex.pm downloads](https://img.shields.io/hexpm/dt/ex_gam?label=downloads)](https://hex.pm/packages/ex_gam)
[![HexDocs API reference](https://img.shields.io/badge/HexDocs-API-4e2a8e)](https://hexdocs.pm/ex_gam/)
[![Apache 2.0 license](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

[![Tested Elixir versions](https://img.shields.io/badge/Elixir-1.19%20%7C%201.20-6e4a7e)](https://github.com/elchemista/ex_gam/blob/main/.github/workflows/ci.yml)
[![Tested Erlang/OTP versions](https://img.shields.io/badge/Erlang%2FOTP-28%20%7C%2029-a90533)](https://github.com/elchemista/ex_gam/blob/main/.github/workflows/ci.yml)
[![Static checks with Credo and Dialyzer](https://img.shields.io/badge/static%20checks-Credo%20%2B%20Dialyzer-40556b)](https://github.com/elchemista/ex_gam/actions/workflows/ci.yml)
[![Minimum combined test coverage](https://img.shields.io/badge/coverage%20minimum-93%25-33664b)](https://github.com/elchemista/ex_gam/blob/main/mix.exs)

ExGAM is an Elixir/OTP library for the Governed Act Model. Give a **Domain** a policy and a ledger. Authenticate a caller, open a **Scope**, and propose a concrete consequence. The kernel checks the Mandate and Evidence and commits the Act before releasing a capability to the executor. The resulting decision, attempt, outcome and outstanding Duties can be recovered from the ledger.

The package was extracted from the GAM implementation in Spectre. Its Mix application is `:ex_gam` and its public entry point is `ExGAM`. An application can use it directly with its own authentication, executors and storage.

The GAM manifesto introduces Mandate, Evidence, Act and Duty. The GAM repository contains the formal specification and the Lean 4 proofs for the reference kernel. A refinement proof connecting this OTP implementation to the Lean profile remains open. [GAM repository](https://github.com/elchemista/gam) · [GAM manifesto on Spectre Guide](https://spectre.guide/en/governed-act-model)

[![Formal GAM model: four laws proved in Lean 4](https://raw.githubusercontent.com/elchemista/gam/main/docs/badges/lean-laws.svg)](https://github.com/elchemista/gam/blob/main/lean/GAM/Theorems/Consequences.lean)
[![Formal GAM kernel: step and replay verified](https://raw.githubusercontent.com/elchemista/gam/main/docs/badges/kernel.svg)](https://github.com/elchemista/gam/blob/main/lean/GAM/Kernel.lean)

## Try a governed operation

With Elixir 1.19 or later in the 1.x series, run these commands from this checkout.

```sh
mix deps.get
mix run examples/quickstart.exs
mix test --warnings-as-errors
```

Run `mix docs` to generate the browsable API reference in `doc/index.html`.

The example grants a single service permission to append a note to one outbox. Its ingress authenticates a local session token. Its executor writes the note and returns receipt evidence bound to the actual Act and Attempt. The example checks the outbox contents and all three stages of the result. It uses an ephemeral ETS ledger and a development credential broker. [Runnable host implementation](examples/outbox.ex) · [ETS wiring](examples/quickstart.exs)

## Embed in a Mix application

To use the Hex release, add the following dependency to the host's `mix.exs` and run `mix deps.get`.

```elixir
{:ex_gam, "~> 0.1.0"}
```

For sibling checkouts, add `{:ex_gam, path: "../ex_gam"}` to the host's dependencies. A host in another directory can use the corresponding relative path. Mix starts the ExGAM OTP application, which supervises the domain registry, domain supervisor, local receipt claims and notifications. The host supervises the chosen store and any external clients.

```elixir
# Inside your host supervisor's children list
{ExGAM.Ledger.Store.ETS, name: MyApp.GovernanceLedger}
```

The host supplies the bootstrap records, trusted adapters and the concrete proposal. With those in place the host can submit a proposal.

```elixir
alias ExGAM, as: GAM

store = {GAM.Ledger.Store.ETS, server: MyApp.GovernanceLedger}

with {:ok, domain} <- GAM.start_domain(domain_ref, store, host_options),
     {:ok, context} <- GAM.authenticate(domain, scope_ref, request),
     {:ok, scope} <- GAM.open_scope(domain, context, opened_at: System.system_time(:millisecond)),
     {:ok, result} <- GAM.propose(scope, candidate) do
  GAM.Proposal.Result.status(result)
end
```

Start each domain once. Subsequent operations reuse its handle or resolve its registered reference. A host that wants its own supervision order can use `ExGAM.Domain.child_spec/1` with `:domain_ref`, `:store` and the same domain options. A recovered client authenticates again before using `resume_scope/2`. An `{:ok, result}` means a proposal was processed. Inspect `result.primary` or `Proposal.Result.status/1` for admission, attempt and outcome separately.

## Public API and behaviours

| Task | Application interface |
| --- | --- |
| Start and address a domain | `ExGAM.start_domain/3`, `ExGAM.Domain.whereis/1`, `ExGAM.head/1` |
| Authenticate and open work | `authenticate/3`, `open_scope/3`, `resume_scope/2` on `ExGAM` |
| Record an observation and propose an effect | `ExGAM.observe/2`, `ExGAM.propose/2`, `ExGAM.Proposal.Result.status/1` |
| Inspect and govern | `ExGAM.view/1`, `authority/1`, `delegate_mandate/3`, `revoke_mandate/3`, `dispose_duty/3` |
| Read and verify a ledger snapshot | `ExGAM.Ledger.load/2`, `ExGAM.Audit.verify/3` |
| Define policy and records | `Principal.new/1`, `Mandate.new/1`, `Surface.new/1`, `Genesis.new/1` and the other typed constructors under `ExGAM` |

| Host extension | Contract and implementations |
| --- | --- |
| Caller identity and observed input | Implement `ExGAM.Ingress` with a stable reference, `authenticate/5` and `observe/4`. The ingress derives the principal and trusted bindings from host authentication. |
| Execution and outcome evidence | Implement `ExGAM.Attempt.Executor` with `executor_ref/0`, `contract_ref/0` and `execute/4`. Use `outcome_evidence/5` to bind the observation to the committed attempt. |
| Credential release | Implement `ExGAM.Secret.Broker`. The bundled `Passthrough` implementation supports development. A mediated deployment supplies its own broker and credential boundary. |
| Recognition of the initial authority | Implement `ExGAM.Genesis.Verifier`. The included `Allowlist` checks attestation references recognized by the host. |
| Ledger persistence | Implement `ExGAM.Ledger.Store`. ETS, Disk, Mnesia and PostgreSQL adapters ship with the library. |
| Payload and projection storage | `ExGAM.Payload.Store` manages external content and retention. `ExGAM.Domain.Projection.Store` holds derived state and recovery checkpoints. The ledger remains authoritative. |

Host-authored code constructs records through their public constructors and sends operations through the `ExGAM` facade. The sequencer, projection internals and raw ledger writer are implementation boundaries. [Storage guide](docs/storage.md) · [Connecting Spectre](docs/spectre.md)

## Source and license

Derived from `lib/spectre/gam`, its facade, canonical codec and kernel tests at Spectre commit `83daf2425b73f8249b5ea4579a3605e65cbc5134`. Package version 0.1.0 exposes the inherited governed runtime API version 0.4.0 via `ExGAM.version/0`. Distributed under Apache-2.0. [Upstream source](https://github.com/elchemista/spectre/tree/83daf2425b73f8249b5ea4579a3605e65cbc5134/lib/spectre/gam) · [License](LICENSE)
