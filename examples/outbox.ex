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

# A stand-in for the application's database. It can store a note and then lose
# the acknowledgement, as a remote database might during a connection failure.
defmodule Outbox.Backend do
  def start_link, do: Agent.start_link(fn -> %{notes: %{}, next_reply: :ok} end)
  def notes(outbox), do: Agent.get(outbox, & &1.notes)
  def lose_next_reply(outbox), do: Agent.update(outbox, &%{&1 | next_reply: :timeout})

  def append(outbox, destination, act_ref, text) do
    Agent.get_and_update(outbox, fn state ->
      notes = Map.put(state.notes, {destination, act_ref}, text)
      {state.next_reply, %{notes: notes, next_reply: :ok}}
    end)
  end
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
    %{"destination" => destination, "text" => text} = act.consequence

    case Outbox.Backend.append(outbox, destination, act.ref, text) do
      :ok ->
        {:ok, receipt} =
          ExGAM.Attempt.Executor.outcome_evidence(
            act,
            attempt,
            :succeeded,
            ExGAM.Clock.System.now(),
            payload: %{"stored_note_ref" => act.ref}
          )

        {:ok, %{evidence: [receipt], details_ref: "outbox:stored:" <> act.ref}}

      :timeout ->
        {:error, :ambiguous, %{evidence: [], details_ref: "outbox:missing-reply:" <> act.ref}}
    end
  end
end

# Application policy. The owner grants the note-writer one operation on one
# destination for one hour. The Constitution names a reviewer for outstanding duties.
defmodule Outbox.Policy do
  alias ExGAM.{Constitution, Genesis, HostProfile, Mandate, Principal, Row, Surface}
  alias Outbox.Executor

  @domain "outbox:domain"
  @scope "outbox:scope"
  @class "note.append"
  @purpose "outbox:record-note"
  @genesis "outbox:genesis"
  @attestation "outbox:local-policy:v1"

  def build(now) do
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

    # A Row describes the kinds of effects an operation uses. Appending needs an external attempt.
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
        expires_at: now + :timer.hours(1),
        source_ref: @genesis,
        revocation: %{"mode" => :cascade, "controller_refs" => [owner.ref]}
      })

    # Genesis ties the starting permission and policy to this particular Domain.
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

    [
      genesis: genesis,
      principals: principals,
      surface: surface,
      host_profile: profile,
      constitution: constitution,
      root_mandates: [mandate],
      genesis_verifier: {Genesis.Verifier.Allowlist, attestation_refs: [@attestation]}
    ]
  end
end

defmodule Outbox.Example do
  def start(store) do
    policy = Outbox.Policy.build(ExGAM.Clock.System.now())
    domain_ref = policy[:genesis].domain_ref
    [mandate] = policy[:root_mandates]

    token = :crypto.strong_rand_bytes(32)

    {:ok, _session} =
      Agent.start_link(fn -> {token, mandate.holder_ref} end, name: Outbox.Session)

    {:ok, outbox} = Outbox.Backend.start_link()
    secret = :crypto.strong_rand_bytes(32)

    broker =
      {ExGAM.Secret.Broker.Passthrough,
       domain_ref: domain_ref, checkout_receipt_secret: secret, capability: outbox}

    options =
      policy ++
        [
          ingress: Outbox.Ingress,
          executors: [Outbox.Executor],
          broker: broker,
          checkout_receipt_secret: secret
        ]

    {:ok, domain} = ExGAM.start_domain(domain_ref, store, options)
    %{domain: domain, mandate: mandate, session_token: token, outbox: outbox}
  end
end

# The entry point a controller or job calls. Only the request ID, destination
# and text come from the request. Identity comes from the authenticated Scope.
defmodule Outbox.Notes do
  def append(scope, mandate, request_id, destination, text) do
    candidate = %{
      identity_key: request_id,
      class: "note.append",
      target_refs: [destination],
      consequence: %{"text" => text, "destination" => destination},
      requested_mandate_ref: mandate.ref,
      row: %{attempt: true},
      proposer_ref: scope.context.authenticated_principal_ref,
      accountable_ref: mandate.accountable_ref,
      scope_ref: ExGAM.Scope.ref(scope),
      purpose_ref: "outbox:record-note",
      executor_ref: Outbox.Executor.executor_ref(),
      executor_contract_ref: Outbox.Executor.contract_ref(),
      observation_window_ms: 5_000
    }

    ExGAM.propose(scope, candidate)
  end
end
