# Connecting Spectre to ExGAM

This library hosts the governed kernel and its Domain supervision tree. Spectre continues to own its AgentServer, caller authorization, managed bootstrap policy, ingress, executors, credential integration and result callbacks.

1. Add `{:ex_gam, path: "../../personal/ex_gam"}` to the Spectre Mix dependencies for the current checkout layout. Adjust the relative path when the projects are located elsewhere.
2. At the kernel call sites use `alias ExGAM, as: GAM` or replace qualified `Spectre.GAM.*` references with `ExGAM.*`. Update struct patterns, behaviours, callback types, configured module names and direct registry references together. A struct's module is part of its Elixir type.
3. Let Mix start the `:ex_gam` application as a dependency. Remove the embedded kernel's child from the Spectre supervision tree when switching over. Keep the host's ledger owner or Repo ahead of any domains using it.
4. Retain Spectre's host-facing `submit/4`, `revoke/1` and `resolve_duty/4` entry points in its own facade. They send messages to the AgentServer and enforce its caller contract. Underneath, the managed integration calls ExGAM's authenticated domain APIs.
5. Stop the old domain writer before attaching the new one to the same ledger. Keep the domain reference, persisted policy, attestation verifier, stable adapter references and backend options. Start the recovered domain, compare its revision and head digest, audit its snapshot with the original constitution, then authenticate and resume scopes through the new runtime.

The extraction keeps the SPCV v1 wire format, the existing canonical record tags, hash inputs and built-in contract references, including historical `spectre:` identifiers. Use durable ledger records for handoff. A live PID, struct from the old namespace, checkout capability or in-flight request requires explicit host handling. Application-specific fields containing module names and separately persisted host checkpoints need their own compatibility check.

The projection-load telemetry event in this library is `[:ex_gam, :projection, :load]`. A host that consumes the embedded runtime's telemetry needs to update its subscription.

The outbox example calls the same `ExGAM` facade as a Spectre adapter. [Run the example](../README.md#try-a-governed-operation)
