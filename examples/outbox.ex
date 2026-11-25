# This local application grants one service the right to put a note into one outbox.
defmodule Outbox.Ingress do
  use ExGAM.Ingress, ref: "outbox:ingress:v1"

  @impl true
  def authenticate(domain, scope, presented_token, generation, _opts) do
    {token, principal_ref} = Agent.get(Outbox.Session, & &1)

    if presented_token === token do
      ExGAM.SubmissionContext.new(%{
        domain_ref: domain,
        scope_ref: scope,
        authenticated_principal_ref: principal_ref,
        authentication_ref: "outbox:local-login",
        ingress_ref: ref(),
        channel_ref: "outbox:local-channel",
        session_ref: "outbox:local-session",
        host_generation: generation
      })
    else
      {:error, :unknown_session}
    end
  end

  # This example only accepts outcome evidence produced by its own executor.
  @impl true
  def observe(_context, _input, _now, _opts), do: {:error, :unsupported_observation}
end

defmodule Outbox.Executor do
  @behaviour ExGAM.Attempt.Executor
  {:ok, principal} = ExGAM.Principal.new(%{kind: :service, attributes: %{"name" => "outbox"}})
  @principal principal
  def principal, do: @principal

  @impl true
  def executor_ref, do: @principal.ref
  @impl true
  def contract_ref, do: "outbox:append:v1"

  @impl true
  def execute(act, attempt, outbox, _opts) do
    Agent.update(outbox, &Map.put(&1, act.ref, act.consequence["text"]))
    now = ExGAM.Clock.System.now()

    {:ok, receipt} =
      ExGAM.Attempt.Executor.outcome_evidence(act, attempt, :succeeded, now,
        payload: %{"stored_note_ref" => act.ref}
      )

    {:ok, %{evidence: [receipt], details_ref: "outbox:stored:" <> act.ref}}
  end
end

defmodule Outbox.Example do
  alias ExGAM.{Constitution, Genesis, HostProfile, Mandate, Principal, Row, Surface}
  alias Outbox.{Executor, Ingress}

  @domain "outbox:domain"
  @scope "outbox:scope"
  @class "note.append"
  @purpose "outbox:record-note"
  @genesis "outbox:genesis"
  @attestation "outbox:local-policy:v1"

  def run(store) do
    now = ExGAM.Clock.System.now()
    {:ok, owner} = Principal.new(%{kind: :human, attributes: %{"name" => "owner"}})
    {:ok, user} = Principal.new(%{kind: :service, attributes: %{"name" => "note-writer"}})
    {:ok, reviewer} = Principal.new(%{kind: :human, attributes: %{"name" => "reviewer"}})
    principals = [owner, user, reviewer, Executor.principal()]

    duty_classes =
      ~w(ambiguous_outcome contradicted_outcome disputed_evidence scope_promise_overdue erasure_reduces_verifiability)

    constitution = %{
      "duty_rules" =>
        Map.new(duty_classes, &{&1, %{"disposition_authority_refs" => [reviewer.ref]}})
    }

    token = :crypto.strong_rand_bytes(32)
    {:ok, _session} = Agent.start_link(fn -> {token, user.ref} end, name: Outbox.Session)
    {:ok, outbox} = Agent.start_link(fn -> %{} end)
    {:ok, row} = Row.new(%{attempt: true})

    {:ok, contract} =
      ExGAM.Consequence.Contract.new(%{
        shape: %{"text" => "string", "destination" => "target_ref"}
      })

    {:ok, surface} =
      Surface.new(%{
        revision: 1,
        declarations: %{@class => row},
        consequence_contracts: %{@class => contract}
      })

    {:ok, profile} =
      HostProfile.new(%{
        mode: :development,
        declared_at: now,
        attestation_ref: "outbox:host",
        assumptions: ["local in-process example"]
      })

    {:ok, mandate} =
      Mandate.new(%{
        revision: 1,
        grantor_ref: owner.ref,
        holder_ref: user.ref,
        accountable_ref: owner.ref,
        executor_refs: [Executor.executor_ref()],
        executor_contract_refs: [Executor.contract_ref()],
        scope_refs: [@scope],
        target_refs: ["outbox:notes"],
        classes: [@class],
        ceiling: row,
        purpose_ref: @purpose,
        not_before: now,
        expires_at: now + 60_000,
        source_ref: @genesis,
        revocation: %{"mode" => :cascade, "controller_refs" => [owner.ref]}
      })

    {:ok, genesis} =
      Genesis.new(%{
        ref: @genesis,
        domain_ref: @domain,
        issued_at: now,
        attestation_ref: @attestation,
        principal_refs: Enum.map(principals, & &1.ref),
        root_mandate_refs: [mandate.ref],
        constitution_ref: Constitution.ref!(constitution),
        host_profile_ref: profile.ref,
        surface_ref: surface.ref,
        surface_revision: surface.revision
      })

    secret = :crypto.strong_rand_bytes(32)

    broker =
      {ExGAM.Secret.Broker.Passthrough,
       domain_ref: @domain, checkout_receipt_secret: secret, capability: outbox}

    {:ok, domain} =
      ExGAM.start_domain(@domain, store,
        ingress: Ingress,
        executors: [Executor],
        broker: broker,
        checkout_receipt_secret: secret,
        genesis: genesis,
        principals: principals,
        surface: surface,
        host_profile: profile,
        constitution: constitution,
        root_mandates: [mandate],
        genesis_verifier: {Genesis.Verifier.Allowlist, attestation_refs: [@attestation]}
      )

    {:ok, context} = ExGAM.authenticate(domain, @scope, token)
    {:ok, scope} = ExGAM.open_scope(domain, context, opened_at: ExGAM.Clock.System.now())

    candidate = %{
      identity_key: "note:1",
      class: @class,
      target_refs: ["outbox:notes"],
      consequence: %{"text" => "hello", "destination" => "outbox:notes"},
      requested_mandate_ref: mandate.ref,
      row: row,
      proposer_ref: user.ref,
      accountable_ref: owner.ref,
      scope_ref: @scope,
      purpose_ref: @purpose,
      executor_ref: Executor.executor_ref(),
      executor_contract_ref: Executor.contract_ref(),
      observation_window_ms: 5_000
    }

    {:ok, result} = ExGAM.propose(scope, candidate)

    %{primary: %{admission: :admitted, attempted?: true, outcome: :succeeded}} =
      status = ExGAM.Proposal.Result.status(result)

    ["hello"] = Agent.get(outbox, &Map.values/1)
    status
  end
end
