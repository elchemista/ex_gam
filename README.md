# ExGAM

ExGAM lets an Elixir application check who may perform an operation, record what it authorized, and track what actually happened. For example, a note-writing service may append to the team outbox. What happens if it asks to write to a private outbox, or if the database stores the note but the reply gets lost? The runnable example covers all three cases.

[![CI on main](https://github.com/elchemista/ex_gam/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/elchemista/ex_gam/actions/workflows/ci.yml?query=branch%3Amain)
[![Hex.pm version](https://img.shields.io/hexpm/v/ex_gam?label=Hex.pm)](https://hex.pm/packages/ex_gam)
[![Hex.pm downloads](https://img.shields.io/hexpm/dt/ex_gam?label=downloads)](https://hex.pm/packages/ex_gam)
[![HexDocs API reference](https://img.shields.io/badge/HexDocs-API-4e2a8e)](https://hexdocs.pm/ex_gam/)
[![Apache 2.0 license](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

[![Tested Elixir versions](https://img.shields.io/badge/Elixir-1.19%20%7C%201.20-6e4a7e)](https://github.com/elchemista/ex_gam/blob/main/.github/workflows/ci.yml)
[![Tested Erlang/OTP versions](https://img.shields.io/badge/Erlang%2FOTP-28%20%7C%2029-a90533)](https://github.com/elchemista/ex_gam/blob/main/.github/workflows/ci.yml)
[![Static checks with Credo and Dialyzer](https://img.shields.io/badge/static%20checks-Credo%20%2B%20Dialyzer-40556b)](https://github.com/elchemista/ex_gam/actions/workflows/ci.yml)
[![Minimum combined test coverage](https://img.shields.io/badge/coverage%20minimum-96%25-33664b)](https://github.com/elchemista/ex_gam/blob/main/mix.exs)

## Try a governed operation

From a checkout with Elixir 1.19 or 1.20, run the following commands.

```sh
mix deps.get
mix run examples/quickstart.exs
```

The application owner gives the `note-writer` service permission to append notes to `outbox:notes` for one hour. The example submits three requests using the same authenticated session. Each row shows the result of a real call.

| Request | Decision | What the application sees |
| --- | --- | --- |
| Append “hello” to `outbox:notes` | Admitted | The executor writes the note and returns a receipt. The outcome is `:succeeded`. |
| Append “hello” to `outbox:private` | Refused | That destination is outside the permission. The executor receives no call and the contents of the outbox stay the same. |
| Append to `outbox:notes` when the database reply gets lost | Admitted | The executor reports `:ambiguous`. ExGAM records an open duty for review. Sending the same write again could duplicate the effect. |

[Run the three requests](examples/quickstart.exs) · [Read the policy, session adapter and executor](examples/outbox.ex)

## What the GAM terms mean

A **policy** is the rule the application owner chooses. Here it answers three ordinary questions. Who can write? The note-writer. Where? The team outbox. Who can resolve an uncertain write? A reviewer. The example's `Outbox.Policy.build/1` expresses those choices as Elixir records.

| Term | Meaning in this application |
| --- | --- |
| **Domain** | The running instance that applies the outbox policy and owns its history. Operations that share this policy and history go through the same Domain. Its **ledger** records decisions, attempts and receipts. The outbox backend stores the actual note. |
| **Scope** | A named workspace for related requests. The service authenticates with its session token, opens `outbox:scope`, and submits all three requests there. |
| **Mandate** | A grant of authority. The owner's grant names the note-writer, the permitted operation, the destination, the executor and the expiry. |
| **Candidate** | One proposed write, such as “append ‘hello’ to the team outbox.” The host builds it from the request and the authenticated caller. |
| **Act** | The immutable record of the exact write ExGAM has admitted. ExGAM commits it before starting an **Attempt**, the recorded invocation of the executor. A refused request has a decision and no Act. |
| **Evidence** | An observation with a source. On success the executor returns a receipt bound to that Act and Attempt. A policy can also require evidence before admission. |
| **Duty** | An obligation that someone must resolve. In the lost-reply case it refers to the uncertain Act. The reviewer can use the Act reference to check the database. The Duty stays open until an authorized decision records how it was resolved. |

In the policy code, the **Surface** declares `note.append` and its two inputs, text and destination. The **Mandate** grants that operation to this service. The **Constitution** sets domain-wide rules, including who can review an uncertain outcome. **Genesis** binds those initial records to this Domain when it starts. [Policy implementation](examples/outbox.ex)

## Where ExGAM fits in your application

Put the proposal in the controller or job that receives a write request. Put the database write or external API call in the executor. ExGAM runs the executor after it has checked and recorded the request.

```text
Controller or job → proposes a write → ExGAM checks the Mandate
                                        ├─ refused  → decision returned to caller
                                        └─ admitted → Act and Attempt recorded
                                                        ↓
                                                Your executor writes
                                                        ↓
                                          Receipt, or open Duty if uncertain
```

To try the first two requests interactively, start `iex -S mix` in this checkout and paste the code below. `Outbox.Example.start/1` is the example application's startup code. It builds the policy, registers the session adapter and executor, and calls `ExGAM.start_domain/3` once.

```elixir
Code.require_file("examples/outbox.ex")
{:ok, ledger} = ExGAM.Ledger.Store.ETS.start_link([])
app = Outbox.Example.start({ExGAM.Ledger.Store.ETS, server: ledger})

{:ok, context} = ExGAM.authenticate(app.domain, "outbox:scope", app.session_token)
{:ok, scope} = ExGAM.open_scope(app.domain, context, opened_at: ExGAM.Clock.System.now())

{:ok, saved} = Outbox.Notes.append(scope, app.mandate, "note:1", "outbox:notes", "hello")
ExGAM.Proposal.Result.status(saved).primary
# %{admission: :admitted, act_committed?: true, attempted?: true, outcome: :succeeded}

{:ok, denied} = Outbox.Notes.append(scope, app.mandate, "note:2", "outbox:private", "hello")
denied.primary.decision.reasons
# [:mandate_absent] — no Mandate covers the private destination.
```

`Outbox.Notes.append/5` is an ordinary application function. It puts the text and destination in a Candidate, takes the caller's identity from the authenticated Scope, and calls `ExGAM.propose(scope, candidate)`. Both calls above return `{:ok, result}` because each request received a decision. Use the decision to report a refusal and the observed outcome to report whether a write succeeded. [Application function and executor](examples/outbox.ex)

## Embed in a Mix application

Add `{:ex_gam, "~> 0.1.0"}` to your dependencies for the Hex release, or `{:ex_gam, path: "../ex_gam"}` for a sibling checkout. Run `mix deps.get`. Mix starts ExGAM's OTP application.

1. **At startup**, supervise the ledger store and start the Domain with your policy and adapters. The demo uses ETS and a local credential broker. For a ledger that survives application restarts, choose a persistent store such as PostgreSQL. Keep the initial policy records so you can reopen the same history. [Storage guide](docs/storage.md)
2. **At login or job intake**, implement the `authenticate/5` callback of `ExGAM.Ingress` using your existing authentication. In the demo the token identifies the note-writer. In your app the adapter could validate a Phoenix session or a worker credential. Open the Scope for the work. After reconnecting, authenticate again and use `ExGAM.resume_scope/2` for an existing Scope.
3. **At the write boundary**, expose a function like `Outbox.Notes.append/5` and route governed writes through it. Keep the credential for the side effect with your broker and executor. To use Ecto, for example, put the insert where `Outbox.Executor.execute/4` calls `Outbox.Backend.append/4`. Return receipt Evidence after the database confirms the write.
4. **When handling the result**, use `ExGAM.Proposal.Result.status/1` to distinguish admission, attempt and outcome. For an ambiguous outcome, surface the open obligation with `ExGAM.duties(scope, status: :open)` so an authorized reviewer can follow up.

For a fixed supervision tree, put `{ExGAM.Ledger.Store.ETS, name: MyApp.GovernanceLedger}` before the Domain child. Give `ExGAM.Domain.child_spec/1` the policy and adapter options along with `:domain_ref` and `store: {ExGAM.Ledger.Store.ETS, server: MyApp.GovernanceLedger}`. Request handlers can then call `ExGAM.lookup_domain/1` to obtain the running handle.

## Public API and behaviours

Run `mix docs` to build the API reference at `doc/index.html` and `mix test --warnings-as-errors` to run the library's tests.

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

## The formal model

ExGAM was extracted from Spectre. Applications can use it directly with their own authentication, executors and storage. The GAM manifesto introduces the four forms and four laws. The separate GAM repository contains the Lean 4 specification and proofs for its reference kernel. A refinement proof connecting this OTP implementation to that kernel remains open. [GAM repository](https://github.com/elchemista/gam) · [GAM manifesto on Spectre Guide](https://spectre.guide/en/governed-act-model)

[![Formal GAM model: four laws proved in Lean 4](https://raw.githubusercontent.com/elchemista/gam/main/docs/badges/lean-laws.svg)](https://github.com/elchemista/gam/blob/main/lean/GAM/Theorems/Consequences.lean)
[![Formal GAM kernel: step and replay verified](https://raw.githubusercontent.com/elchemista/gam/main/docs/badges/kernel.svg)](https://github.com/elchemista/gam/blob/main/lean/GAM/Kernel.lean)

## Source and license

Derived from `lib/spectre/gam`, its facade, canonical codec and kernel tests at Spectre commit `83daf2425b73f8249b5ea4579a3605e65cbc5134`. Package version 0.1.0 exposes the inherited governed runtime API version 0.4.0 via `ExGAM.version/0`. Distributed under Apache-2.0. [Upstream source](https://github.com/elchemista/spectre/tree/83daf2425b73f8249b5ea4579a3605e65cbc5134/lib/spectre/gam) · [License](LICENSE)
