Code.require_file("outbox.ex", __DIR__)

alias ExGAM.Proposal.Result
alias Outbox.{Backend, Notes}

# Application startup. The Domain uses an ETS ledger and the owner's policy.
{:ok, ledger} = ExGAM.Ledger.Store.ETS.start_link([])
app = Outbox.Example.start({ExGAM.Ledger.Store.ETS, server: ledger})

# The ingress adapter resolves the session to the note-writer. Open its workspace.
{:ok, context} = ExGAM.authenticate(app.domain, "outbox:scope", app.session_token)
{:ok, scope} = ExGAM.open_scope(app.domain, context, opened_at: ExGAM.Clock.System.now())

# A request within the Mandate reaches the executor and produces a receipt.
{:ok, saved} = Notes.append(scope, app.mandate, "note:1", "outbox:notes", "hello")

%{admission: :admitted, act_committed?: true, attempted?: true, outcome: :succeeded} =
  IO.inspect(Result.status(saved).primary, label: "Append to notes")

[receipt] = saved.primary.evidence
act_ref = saved.primary.act.ref
^act_ref = receipt.payload["stored_note_ref"]
stored = Backend.notes(app.outbox)
%{{"outbox:notes", ^act_ref} => "hello"} = stored

# Same service and operation, different destination. The outbox receives no write.
{:ok, denied} = Notes.append(scope, app.mandate, "note:2", "outbox:private", "hello")

%{admission: :refused, act_committed?: false, attempted?: false, outcome: nil} =
  IO.inspect(Result.status(denied).primary, label: "Append to private")

[:mandate_absent] = IO.inspect(denied.primary.decision.reasons, label: "Refusal reason")
^stored = Backend.notes(app.outbox)

# A lost acknowledgement leaves the write uncertain to the caller.
:ok = Backend.lose_next_reply(app.outbox)
{:ok, uncertain} = Notes.append(scope, app.mandate, "note:3", "outbox:notes", "follow up")

%{admission: :admitted, act_committed?: true, attempted?: true, outcome: :ambiguous} =
  IO.inspect(Result.status(uncertain).primary, label: "Append with lost reply")

{:ok, [duty]} = ExGAM.duties(scope, status: :open)
%{class: :ambiguous_outcome, status: :open, act_ref: uncertain_ref} = duty
^uncertain_ref = uncertain.primary.act.ref
%{{"outbox:notes", ^uncertain_ref} => "follow up"} = Backend.notes(app.outbox)
IO.inspect(duty.class, label: "Open duty for the reviewer")
