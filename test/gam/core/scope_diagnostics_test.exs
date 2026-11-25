Code.require_file("../helper.exs", __DIR__)

defmodule ExGAM.ScopeDiagnosticsTest do
  use ExGAM.Test.GovernedBoundaryCase, async: false

  alias ExGAM.Domain.Sequencer
  alias ExGAM.Scope.{Diagnostics, View}
  alias ExGAM.V04Test.Fixture

  test "an interaction follows recorded evidence to its decision and execution, with bounded pages",
       c do
    f = c.f

    invocation =
      observe(f, {:spectre_skill_invocation, "cmd"}, %{
        command_id: "cmd",
        interaction: "thread",
        skill: "lookup",
        private: "internal detail"
      })

    lifecycle =
      observe(f, {:spectre_server_lifecycle, "task"}, %{
        event: %{
          origin_id: "thread",
          phase: :stopped,
          reason: %{detail: "internal detail"},
          token: "internal detail"
        }
      })

    other =
      observe(f, {:spectre_skill_invocation, "elsewhere"}, %{
        command_id: "elsewhere",
        interaction: "another"
      })

    candidate =
      Fixture.refund_candidate(f, 15,
        identity_key: "spectre:managed:cmd",
        evidence_refs: [c.payment.ref, invocation.ref]
      )

    assert {:ok, %{decision: decision, act: act, grant: grant}} =
             Sequencer.submit(f.server, Fixture.context(f), candidate)

    assert {:ok, ^act, attempt, _} = Sequencer.consume_grant(f.server, grant)
    projection = Sequencer.projection(f.server)
    scope = f.refs.scope
    assert {:ok, full} = Diagnostics.page(projection, scope, interaction: "thread")
    records = Map.new(full.records, &{&1.ref, &1})

    assert %{kind: :evidence, event: :spectre_skill_invocation, skill: "lookup"} =
             records[invocation.ref]

    assert records[lifecycle.ref].lifecycle == %{phase: :stopped, reason: nil}
    assert records[decision.ref].kind == :decision
    assert records[attempt.ref].act_ref == act.ref
    refute Map.has_key?(records, other.ref)
    refute Map.has_key?(records, c.act.ref)
    refute inspect(full) =~ "internal detail"
    assert full.counts.evidence == 2

    assert {:ok, first} = Diagnostics.page(projection, scope, interaction: "thread", limit: 2)

    assert {:ok, rest} =
             Diagnostics.page(projection, scope, interaction: "thread", cursor: first.next_cursor)

    assert first.records ++ rest.records == full.records
    assert rest.next_cursor == nil

    assert {:error, :invalid_cursor} =
             Diagnostics.page(projection, scope,
               interaction: "another",
               cursor: first.next_cursor
             )

    assert {:error, :invalid_cursor} =
             Diagnostics.page(projection, "another",
               interaction: "thread",
               cursor: first.next_cursor
             )

    assert {:error, :stale_cursor} =
             Diagnostics.page(c.attempted, scope,
               interaction: "thread",
               cursor: first.next_cursor
             )
  end

  test "display reasons retain only codes and scalar values", c do
    reasons = [:denied, {:unavailable, "private"}, {"private", 123}, %{"private" => 1}]
    projection = c.attempted
    projection = put_in(projection.decisions[c.decision.ref].reasons, reasons)
    assert {:ok, page} = Diagnostics.page(projection, c.f.refs.scope, [])
    decision = Enum.find(page.records, &(&1.ref == c.decision.ref))
    assert decision.reason_codes == [:denied, :unavailable, :redacted, :redacted]
    refute inspect(page.records) =~ "private"

    assert {:error, :invalid_diagnostic_options} =
             Diagnostics.page(projection, c.f.refs.scope, :all)
  end

  test "scope reads reject missing or malformed openings and unsupported collections", c do
    scope = c.f.refs.scope
    assert {:error, {:invalid_scope_ref, ""}} = View.from_projection(c.pending, "")
    assert {:error, :invalid_domain_projection} = View.from_projection(nil, scope)
    assert {:error, :invalid_scope_collection} = View.records(c.pending, scope, :secrets)
    corrupt = c.pending
    corrupt = put_in(corrupt.catalog.scopes[scope], %{})
    assert {:error, {:invalid_scope_opening, ^scope}} = View.from_projection(corrupt, scope)
  end

  test "only a cancellation belonging to the authenticated scope appears in its view", c do
    cancel = %{
      reason: :mandate_expired,
      cause_ref: c.f.mandate.ref,
      cancelled_at: c.f.mandate.expires_at
    }

    state = %{
      c.pending
      | pending_dispatches: MapSet.new(),
        terminal_dispatches: %{
          c.act.ref => {:cancelled, cancel},
          "foreign" => {:cancelled, cancel}
        }
    }

    assert {:ok, view} = View.from_projection(state, c.f.refs.scope)
    assert view.dispatch_cancellations == [Map.put(cancel, :act_ref, c.act.ref)]
  end

  defp observe(fixture, proposition, payload) do
    evidence = Fixture.paid_evidence(fixture, proposition: proposition, payload: payload)
    assert {:ok, ^evidence} = Fixture.observe_payment(fixture, evidence)
    evidence
  end
end
