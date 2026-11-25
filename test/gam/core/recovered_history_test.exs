Code.require_file("../helper.exs", __DIR__)

defmodule ExGAM.RecoveredHistoryTest do
  use ExGAM.Test.GovernedBoundaryCase, async: false

  alias ExGAM.Audit.Report
  alias ExGAM.Domain.{Bootstrap, Configuration}
  alias ExGAM.Domain.Command.{Execution, Record}
  alias ExGAM.Domain.Sequencer.State, as: SequencerState
  alias ExGAM.GovernedAct.{Completeness, Integrity, State, View}

  test "audit reports an expired pending dispatch and integrity requires its cancellation", c do
    state = c.pending
    act_ref = c.act.ref
    mandate = c.f.mandate
    assert :ok = Integrity.validate(state, state.recorded_at)
    assert {:ok, report} = Report.build(state, state.recorded_at, mandate.expires_at)

    assert report.expired_dispatches == [
             %{act_ref: act_ref, mandate_ref: mandate.ref, expired_at: mandate.expires_at}
           ]

    assert {:error, {:dispatch_expiration_not_recorded, ^act_ref}} =
             Integrity.validate(state, mandate.expires_at)

    assert {:error, :invalid_audit_report_input} = Report.build(state, 100, 99)

    assert {:error, {:surface_revision_not_found, 77}} =
             Report.build(put_in(state.acts[act_ref].surface_revision, 77), state.recorded_at)

    assert {:error, _} = Report.build(%{state | event_metadata: %{}}, state.recorded_at)
  end

  test "an attempted Act with an elapsed observation deadline needs a recorded duty", c do
    state = c.attempted
    deadline = c.attempt.started_at + c.act.observation_window_ms
    assert :ok = Integrity.validate(state, deadline - 1)
    assert {:error, {:required_duty_not_materialized, key}} = Integrity.validate(state, deadline)
    assert key == {:ambiguous_outcome, c.act.ref, c.attempt.ref}
    assert {:ok, report} = Report.build(state, deadline)
    assert Enum.any?(report.pending_duty_causes, &(&1.cause_key == key))
  end

  test "a partial projection or damaged dispatch and reservation indexes cannot attest completeness",
       c do
    state = c.pending
    act_ref = c.act.ref
    assert {:error, :invalid_governed_fold} = Completeness.validate(nil)

    assert {:error, :complete_projection_required} =
             Completeness.validate(put_in(state.read_index.selection, MapSet.new()))

    assert {:error, {:act_reservation_not_recorded, ^act_ref}} =
             Completeness.validate(%{state | meter_reservations: %{}})

    assert {:error, {:invalid_meter_reservation, "missing"}} =
             Completeness.validate(put_in(state.meter_reservations["missing"], :reserved))

    assert {:error, {:dispatch_act_not_found, "unknown"}} =
             Completeness.validate(%{
               state
               | pending_dispatches: MapSet.put(state.pending_dispatches, "unknown")
             })

    assert {:error, {:invalid_act_dispatch_state, ^act_ref, {false, nil}}} =
             Completeness.validate(%{state | pending_dispatches: MapSet.new()})
  end

  test "structure checks and external Genesis recognition are independently required", c do
    state = c.before
    now = state.recorded_at
    opts = Keyword.delete(c.f.sequencer_opts, :genesis_verifier)
    assert :ok = Bootstrap.validate(c.f.refs.domain, opts, now)
    assert {:error, :genesis_verifier_required} = Bootstrap.prepare(c.f.refs.domain, opts, now)
    assert {:error, :invalid_domain_bootstrap} = Bootstrap.validate(nil, opts, now)

    assert {:error, :invalid_domain_bootstrap_records} =
             Bootstrap.records(Keyword.put(opts, :principals, [hd(opts[:principals]) | :broken]))

    assert {:error, :genesis_missing} = Integrity.validate(State.new("new"), now)

    assert {:error, :host_profile_missing} =
             Integrity.validate(put_in(state.catalog.host_profile_ref, nil), now)

    assert {:error, _} = Integrity.validate(%{state | constitution: %{unknown: :field}}, now)
    assert View.blocked_mandate_refs(state) == MapSet.new()
    assert View.blocked_effect_digests(state) == MapSet.new()
  end

  test "empty provisional suffixes preserve the verified head and malformed replay input is rejected",
       c do
    alias ExGAM.Domain.Projection
    alias ExGAM.GovernedAct.{Fold, Reads}
    state = c.attempted
    assert {:ok, ^state} = Fold.apply_payloads(state, [], state.recorded_at)
    assert {:error, :invalid_domain_payloads} = Fold.apply_payloads(state, [], -1)
    assert {:error, :invalid_governed_history} = Fold.replay_verified("", [], %{})
    assert {:error, :invalid_governed_batch} = Fold.append_batch(state, :missing)
    assert {:error, :invalid_domain_snapshot} = Projection.replay(:missing)
    row = {:row, :acts, c.act.ref}
    assert Reads.read(state, row) == state
    assert catch_throw(Reads.ensure(MapSet.new(), row)) == {:projection_not_loaded, row}
    assert :ok = Reads.ensure(MapSet.new([{:page, :acts, []}]), row)
  end

  test "a valid Grant still requires its exact Act and an active Mandate in the recovered projection",
       c do
    {:ok, config} = Configuration.new(c.f.sequencer_opts)
    state = SequencerState.new(config, c.pending)
    act_ref = c.act.ref
    mandate_ref = c.act.mandate_ref

    assert {:error, _, {:act_not_found, ^act_ref}} =
             Execution.consume(put_in(state.projection.acts, %{}), c.grant)

    assert {:error, _, :invalid_granted_act} =
             Execution.consume(put_in(state.projection.acts[act_ref], nil), c.grant)

    assert {:error, {:mandate_not_found, ^mandate_ref}} =
             Execution.mint_grant(put_in(state.projection.mandates, %{}), c.act)

    assert {:error, {:invalid_mandate_record, ^mandate_ref}} =
             Execution.mint_grant(put_in(state.projection.mandates[mandate_ref], nil), c.act)
  end

  test "a missing or conflicting durable record halts recovery with the original reason", c do
    {:ok, config} = Configuration.new(c.f.sequencer_opts)
    state = SequencerState.new(config, c.pending)
    record = c.payment

    for {index, reason} <- [
          {%{}, :missing},
          {%{record.ref => :different}, {:conflict, record.ref}}
        ] do
      assert {:error, halted, ^reason} =
               Record.recover(state, c.pending, index, record, :conflict, :missing)

      assert halted.halted_reason == reason
      assert_receive {:stop_halted, ^reason}
    end
  end
end
