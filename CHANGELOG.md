# Changelog

## 0.1.0

First standalone release of the Governed Act Model kernel for Elixir/OTP, extracted from Spectre.

- Start supervised domains, authenticate callers and submit governed proposals through `ExGAM`.
- Implement host behaviours for ingress, execution, evidence, credential release and ledger storage.
- Use the bundled ETS, Disk, Mnesia and PostgreSQL ledger adapters.
