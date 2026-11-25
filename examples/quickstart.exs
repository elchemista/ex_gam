Code.require_file("outbox.ex", __DIR__)

{:ok, ledger} = ExGAM.Ledger.Store.ETS.start_link([])
IO.inspect(Outbox.Example.run({ExGAM.Ledger.Store.ETS, server: ledger}), label: "proposal")
