Code.require_file("../helper.exs", __DIR__)

defmodule ExGAM.HostProposalTest do
  use ExUnit.Case, async: false

  alias ExGAM.{Domain, Scope}
  alias ExGAM.Proposal.Result
  alias ExGAM.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    domain_ref = "v0.4:host-proposal:domain"

    f =
      Fixture.start_domain(
        namespace: "host-proposal",
        name: {:via, Registry, {ExGAM.Domain.Registry, domain_ref}},
        revocation_mode: :retained_controller,
        governance_allowed: true
      )

    on_exit(fn -> Fixture.stop_domain(f) end)
    domain = Domain.handle(f.server, f.refs.domain)
    {:ok, worker} = Scope.new(domain, Fixture.context(f))

    {:ok, controller} =
      Scope.new(domain, Fixture.context(f, authenticated_principal_ref: f.refs.grantor))

    %{f: f, worker: worker, controller: controller}
  end

  test "only a retained controller can revoke the grant and subsequent proposals observe revocation",
       c do
    %{f: f, controller: controller, worker: worker} = c
    assert {:ok, authority} = ExGAM.authority(controller)
    assert Enum.any?(authority.retained_revocation_controls, &(&1.mandate_ref == f.mandate.ref))
    assert {:ok, worker_authority} = ExGAM.authority(worker)
    assert worker_authority.retained_revocation_controls == []

    assert {:ok, denied} =
             ExGAM.revoke_mandate(worker, f.mandate.ref, identity_key: "not-controller")

    assert denied.primary.act == nil

    assert {:ok, result} =
             ExGAM.revoke_mandate(controller, f.mandate.ref, identity_key: "controller-revoke")

    assert result.primary.act.class == "mandate.revoke"
    assert {:ok, _} = Fixture.observe_payment(f, Fixture.paid_evidence(f))
    assert {:ok, refused} = ExGAM.propose(worker, Fixture.refund_candidate(f, 5))
    assert %{primary: %{act_committed?: false, attempted?: false}} = Result.status(refused)
    assert {:ok, ^refused} = ExGAM.recover_proposal(worker, refused)
  end

  test "recovering a proposal observes its existing attempt and leaves the ledger head fixed",
       c do
    %{f: f, worker: scope} = c
    assert {:ok, surface} = ExGAM.surface(scope)
    assert surface.ref == f.refs.surface
    assert {:ok, _} = Fixture.observe_payment(f, Fixture.paid_evidence(f))
    assert {:ok, result} = ExGAM.propose(scope, Fixture.refund_candidate(f, 5))

    assert %{primary: %{admission: :admitted, attempted?: true, outcome: :ambiguous}} =
             Result.status(result)

    assert {:ok, head} = ExGAM.head(scope.domain)
    assert {:ok, recovered} = ExGAM.recover_proposal(scope, result)
    assert recovered.primary.attempt == result.primary.attempt

    assert {:ok, %{pending?: false, terminal: {:attempt, attempt_ref}}} =
             ExGAM.dispatch_status(scope, result.primary.act.ref)

    assert attempt_ref == recovered.primary.attempt.ref
    assert {:ok, ^head} = ExGAM.head(scope.domain)
    assert {:ok, duties} = ExGAM.duties(scope, status: :all)
    assert Enum.any?(duties, &(&1.act_ref == result.primary.act.ref))

    assert {:error, {:invalid_duty_status_filter, :unknown}} =
             ExGAM.duties(scope, status: :unknown)
  end
end
