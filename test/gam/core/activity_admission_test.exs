Code.require_file("../helper.exs", __DIR__)

defmodule ExGAM.ActivityAdmissionTest do
  use ExUnit.Case, async: false

  alias ExGAM.Domain.Sequencer
  alias ExGAM.V04Test.{Fixture, Runtime}

  defmodule Store do
    def fetch(table, key) do
      case :ets.lookup(table, key) do
        [{^key, version, value}] -> {:ok, %{revision: version, value: value}}
        [] -> :not_found
      end
    end

    def put_new(table, key, value) do
      if :ets.insert_new(table, {key, 1, value}), do: {:ok, 1}, else: {:error, :exists}
    end

    def compare_and_swap(table, key, version, value) do
      next = {key, version + 1, value}

      case :ets.select_replace(table, [{{key, version, :_}, [], [{:const, next}]}]) do
        1 -> {:ok, version + 1}
        0 -> {:error, :conflict}
      end
    end

    def delete(table, key, version) do
      case :ets.select_delete(table, [{{key, version, :_}, [], [true]}]) do
        1 -> :ok
        0 -> {:error, :conflict}
      end
    end
  end

  setup do
    Runtime.reset(Fixture.default_now())
    table = :ets.new(:fences, [:public, :set])
    token = make_ref()
    f = Fixture.start_domain(activity_fence: {token, {Store, table}})
    on_exit(fn -> Fixture.stop_domain(f) end)
    %{f: f, table: table, token: token, origin: %{ref: "reconcile", revision: 0}}
  end

  test "revision retries are idempotent and cancelled activities cannot authorize a fresh Act",
       c do
    %{f: f, token: token, origin: origin} = c
    fence = &Sequencer.activity_fence(f.server, token, &1)
    context = Fixture.context(f)
    assert {:ok, _} = Fixture.observe_payment(f, Fixture.paid_evidence(f))
    candidate = Fixture.refund_candidate(f, 100)
    assert :ok = fence.({:register, origin.ref})
    assert :ok = fence.({:register, origin.ref})
    assert :ok = fence.({:current, origin})
    revise = Map.merge(origin, %{transition_id: "edit", kind: :revise})
    assert {:ok, 1} = fence.({:advance, revise})
    assert {:ok, 1} = fence.({:advance, revise})
    assert {:error, :activity_transition_conflict} = fence.({:advance, %{revise | kind: :cancel}})
    assert {:error, :superseded} = fence.({:register, origin.ref})
    head = Sequencer.head(f.server)

    assert {:error, :superseded} =
             Sequencer.submit_activity(f.server, context, candidate, token, origin)

    assert Sequencer.head(f.server) == head
    current = %{origin | revision: 1}

    assert {:ok, %{act: %ExGAM.Act{}}} =
             Sequencer.submit_activity(f.server, context, candidate, token, current)

    assert {:ok, 2} =
             fence.({:advance, Map.merge(current, %{transition_id: "stop", kind: :cancel})})

    assert {:error, :superseded} = fence.({:current, %{origin | revision: 2}})
    assert {:error, :superseded} = fence.({:advance, %{revise | transition_id: "late"}})
    assert :ok = fence.({:retire, origin.ref})
    assert :ok = fence.({:retire, origin.ref})
    assert {:error, :unknown_activity} = fence.({:current, current})
  end

  test "untrusted callers, invalid origins and unreadable fence records fail closed", c do
    %{f: f, token: token, origin: origin} = c
    fence = &Sequencer.activity_fence(f.server, token, &1)
    assert {:error, :invalid_activity_fence_action} = fence.(:other)
    assert {:error, :invalid_activity_ref} = fence.({:register, ""})
    assert {:error, :invalid_activity_ref} = fence.({:retire, nil})
    assert {:error, :invalid_activity_transition} = fence.({:advance, origin})
    assert {:error, :invalid_activity_origin} = fence.({:current, %{}})
    assert {:error, :invalid_activity_origin} = fence.({:current, %{origin | revision: -1}})

    assert {:error, :untrusted_activity_transport} =
             Sequencer.activity_fence(f.server, make_ref(), {:register, origin.ref})

    assert {:error, :untrusted_activity_transport} =
             Sequencer.submit_activity(
               f.server,
               Fixture.context(f),
               Fixture.refund_candidate(f, 1),
               make_ref(),
               origin
             )

    assert :ok = fence.({:register, origin.ref})
    [{key, version, _value}] = :ets.tab2list(c.table)
    :ets.insert(c.table, {key, version, %{kind: :unknown}})
    assert {:error, :invalid_activity_fence} = fence.({:retire, origin.ref})
    :ets.delete(c.table)

    for action <- [{:register, origin.ref}, {:current, origin}, {:retire, origin.ref}] do
      assert {:error, :activity_fence_store_unavailable} = fence.(action)
    end
  end
end
