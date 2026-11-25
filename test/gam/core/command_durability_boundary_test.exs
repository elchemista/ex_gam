Code.require_file("../helper.exs", __DIR__)

defmodule ExGAM.CommandDurabilityBoundaryTest do
  use ExGAM.Test.GovernedBoundaryCase, async: false

  alias ExGAM.Domain.Command.{Durability, Input}
  alias ExGAM.Domain.Command.Evidence, as: EvidenceCommand
  alias ExGAM.Domain.{Configuration, Event, Transaction}
  alias ExGAM.Domain.Sequencer.State
  alias ExGAM.Ledger.Store.Mock
  alias ExGAM.V04Test.Fixture

  defmodule InvalidId do
    def generate, do: :not_an_identifier
  end

  defmodule BrokenClock do
    def now, do: raise(ArgumentError, "private clock detail")
  end

  setup c do
    mock = start_supervised!({Mock, store: c.f.store_config})

    {:ok, config} =
      Configuration.new(
        c.f.sequencer_opts
        |> Keyword.put(:store, {Mock, server: mock})
        |> Keyword.put(:projection_store, nil)
      )

    %{state: State.new(config, c.attempted), mock: mock}
  end

  test "CAS recovery hands the new prefix to planning exactly once and consumes a retry", c do
    :ok = Mock.push(c.mock, {:append, :before, {:error, :conflict}})

    assert {:ok, state, :replan} =
             append(c, 2, fn recovered, left ->
               assert left == 1
               assert recovered.projection === c.attempted
               {:ok, recovered, :replan}
             end)

    assert state.halted_reason == nil
    assert Fixture.snapshot(c.f).revision == c.attempted.revision
    assert Enum.count(Mock.calls(c.mock), &(&1.operation == :append)) == 1
  end

  test "exhausted conflicts halt, while ordinary storage rejection leaves a usable prefix", c do
    :ok = Mock.push(c.mock, {:append, :before, {:error, :disk_full}})
    assert {:error, state, :disk_full} = append(c, 0)
    assert state === c.state
    refute_received {:stop_halted, _}
    :ok = Mock.push(c.mock, {:append, :before, {:error, :conflict}})
    assert {:error, halted, :conflict_retries_exhausted} = append(c, 0)
    assert halted.halted_reason == :conflict_retries_exhausted
    assert_receive {:stop_halted, :conflict_retries_exhausted}
    assert Fixture.snapshot(c.f).revision == c.attempted.revision
  end

  test "failed recovery cannot retry using the obsolete projection", c do
    :ok =
      Mock.push(c.mock, [
        {:append, :before, {:error, :conflict}},
        {:load_from, :before, {:error, :unreadable_history}}
      ])

    assert {:error, halted, {:durable_recovery_failed, :unreadable_history}} = append(c, 1)
    assert halted.halted_reason == :unreadable_history
    assert_receive {:stop_halted, :unreadable_history}
  end

  test "identifier and preflight clock faults fail before touching storage", c do
    assert {:error, _, {:invalid_operational_identifier, :atom}} =
             append(%{c | state: %{c.state | id_source: InvalidId}}, 0)

    state = %{c.state | clock: BrokenClock}
    assert {:error, halted, {:preflight_duty_repair_failed, reason}} = Durability.preflight(state)
    assert match?({:trusted_clock_failed, _}, reason)
    assert halted.projection === c.attempted
    assert_receive {:stop_halted, {:preflight_duty_repair_failed, ^reason}}
    assert Mock.calls(c.mock) == []
  end

  test "Evidence recording preserves requested shape, deduplicates persistence and is idempotent",
       c do
    assert {:ok, next, [receipt, same]} = EvidenceCommand.record(c.state, [c.receipt, c.receipt])
    assert receipt === same
    assert receipt === c.receipt
    assert next.projection.revision == c.state.projection.revision + 1
    assert {:ok, ^next, ^receipt} = EvidenceCommand.record(next, receipt)
    assert {:ok, ^next, [^receipt]} = EvidenceCommand.record(next, [receipt])
    assert Enum.count(Mock.calls(c.mock), &(&1.operation == :append)) == 1
    assert {:error, :invalid_evidence_input} = EvidenceCommand.normalize([])
    assert {:error, :invalid_evidence_input} = EvidenceCommand.normalize(nil)
    assert {:error, _} = EvidenceCommand.normalize([receipt, %{}])

    assert {:ok, _, [^receipt]} =
             Input.record_executor_evidence(next, c.act.ref, c.attempt.ref, [receipt])
  end

  test "Evidence acquisition and Scope checks precede append", c do
    {:ok, future} =
      ExGAM.Evidence.new(%{c.receipt | ref: nil, observed_at: c.act.committed_at + 1})

    assert {:error, same, {:evidence_from_future, ref, _}} =
             EvidenceCommand.record(c.state, future)

    assert ref == future.ref
    assert same === c.state
    assert {:error, ^same, _} = Input.finish_observation(c.state, nil, c.receipt)
    assert {:error, ^same, _} = Input.finish_turn(c.state, nil, c.receipt, [])

    assert {:error, ^same, _} =
             Input.record_executor_evidence(c.state, "missing-act", c.attempt.ref, [c.receipt])

    assert Mock.calls(c.mock) == []
    assert {:ok, now} = Transaction.trusted_recorded_at(c.state)
    assert now == c.act.committed_at
  end

  test "a failed preflight answers every caller waiting for a batch", c do
    alias ExGAM.Domain.Sequencer
    token = make_ref()
    first = make_ref()
    second = make_ref()
    pending = :queue.from_list([%{from: {self(), first}}, %{from: {self(), second}}])

    state = %{
      c.state
      | clock: BrokenClock,
        pending: pending,
        pending_count: 2,
        batch_size: 1,
        flush: {token, nil}
    }

    assert {:noreply, halted} = Sequencer.dispatch_info({:flush, token}, state)
    assert {:preflight_duty_repair_failed, _} = reason = halted.halted_reason
    assert_receive {^first, {:error, ^reason}}
    assert_receive {^second, {:error, {:sequencer_halted, ^reason}}}
    assert :queue.is_empty(halted.pending)
    assert halted.pending_count == 0
    assert Mock.calls(c.mock) == []
  end

  test "a scheduled reconciliation with a failed clock halts at the last verified revision", c do
    alias ExGAM.Domain.Sequencer
    token = make_ref()
    state = %{c.state | clock: BrokenClock, reconciliation: {token, nil}}
    assert {:noreply, halted} = Sequencer.dispatch_info({:reconcile, token}, state)
    assert {:reconciliation_failed, _} = reason = halted.halted_reason
    assert_receive {:stop_halted, ^reason}
    assert halted.projection == state.projection
  end

  test "ingress completions never resume a halted sequencer or turn an error into a context", c do
    alias ExGAM.Domain.Sequencer

    for {halted_reason, expected} <- [
          {nil, :session_expired},
          {:storage_failed, {:sequencer_halted, :storage_failed}}
        ] do
      monitor = Process.monitor(self())
      reply = make_ref()
      timer = Process.send_after(self(), :late, 60_000)
      job = %{timer: timer, operation: {:authenticate, c.f.refs.scope}, from: {self(), reply}}
      state = %{c.state | halted_reason: halted_reason, ingress_jobs: %{monitor => job}}

      assert {:noreply, next} =
               Sequencer.dispatch_info({monitor, {:error, :session_expired}}, state)

      assert_receive {^reply, {:error, ^expected}}
      assert next.ingress_jobs == %{}
      assert next.projection == state.projection
    end
  end

  test "conflicting evidence writes retry from the confirmed predecessor", c do
    :ok = Mock.push(c.mock, [{:append, :before, {:error, :conflict}}])
    assert {:ok, next, receipt} = EvidenceCommand.record(c.state, c.receipt)
    assert receipt == c.receipt
    assert next.projection.revision == c.attempted.revision + 1
    assert Enum.count(Mock.calls(c.mock), &(&1.operation == :append)) == 2
  end

  test "an existing evidence ID with different stored content cannot be reused", c do
    state = c.state
    state = put_in(state.projection.evidence[c.receipt.ref], c.payment)

    assert {:error, ^state, {:evidence_identity_conflict, ref}} =
             EvidenceCommand.record(state, c.receipt)

    assert ref == c.receipt.ref
    assert Mock.calls(c.mock) == []
  end

  test "outcome retries preserve a single durable observation and reject identity conflicts", c do
    alias ExGAM.Domain.Command.Observation
    outcome = Fixture.outcome(c.f, c.act, c.attempt, :ambiguous)
    assert {:error, _, _} = Observation.record(c.state, %{})
    :ok = Mock.push(c.mock, [{:append, :before, {:error, :conflict}}])
    assert {:ok, next, ^outcome} = Observation.record(c.state, outcome)
    assert {:ok, ^next, ^outcome} = Observation.record(next, outcome)
    damaged = put_in(next.projection.outcomes[outcome.ref], :invalid)

    assert {:error, ^damaged, {:outcome_identity_conflict, ref}} =
             Observation.record(damaged, outcome)

    assert ref == outcome.ref
  end

  test "a missing ledger and a failing identifier source cannot produce a successful recovery",
       c do
    :ok = Mock.push(c.mock, [{:load_from, :before, :not_found}])
    assert {:error, :domain_ledger_disappeared} = Transaction.recover_verified(c.state)
    assert {:error, _} = Transaction.operational_id(%{c.state | id_source: BrokenClock})
  end

  test "a domain without a Mind rejects turn input before starting ingress", c do
    alias ExGAM.Domain.Sequencer
    context = Fixture.context(c.f)
    head = Sequencer.head(c.f.server)
    assert {:error, :mind_not_configured} = Sequencer.begin_turn(c.f.server, context, %{}, [])

    assert {:error, {:unknown_options, :sequencer, [:unsafe]}} =
             Sequencer.open_scope(c.f.server, context, %{}, unsafe: true)

    assert head == Sequencer.head(c.f.server)
  end

  test "derived executor evidence requires every authorized parent to be durable", c do
    alias ExGAM.Evidence

    {:ok, derived} =
      Evidence.new(%{c.receipt | ref: nil, provenance: :derived, parent_refs: [c.payment.ref]})

    state = c.state
    missing = %{state | projection: %{state.projection | evidence: %{}}}

    assert {:error, ^missing, {:evidence_not_found, ref}} =
             Input.record_executor_evidence(missing, c.act.ref, c.attempt.ref, [derived])

    assert ref == c.payment.ref

    assert {:ok, _, [^derived]} =
             Input.record_executor_evidence(state, c.act.ref, c.attempt.ref, [derived])
  end

  defp append(c, retries, on_conflict \\ fn _, _ -> flunk("unexpected replanning") end) do
    {:ok, payload} = Event.record(:evidence, c.receipt)

    Durability.append(
      c.state,
      [payload],
      c.act.committed_at,
      retries,
      fn projection -> {:ok, %{c.state | projection: projection}, :committed} end,
      on_conflict
    )
  end
end
