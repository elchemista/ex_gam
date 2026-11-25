defmodule ExGAM.Application do
  @moduledoc false

  use Application

  @doc false
  def child_spec(args) do
    %{id: __MODULE__, start: {__MODULE__, :start, [:normal, args]}, type: :supervisor}
  end

  @impl Application
  def start(_type, _args) do
    # Order is part of the lifetime boundary. A Registry restart invalidates
    # every downstream runtime, and losing the passthrough claim store also
    # invalidates Domains which could still hold one of its checkout receipts.
    children = [
      {Registry, keys: :unique, name: ExGAM.Domain.Registry},
      ExGAM.Secret.Broker.Passthrough,
      {ExGAM.Domain.Supervisor, name: ExGAM.Domain.Supervisor},
      # Observability loss must not restart authority or running Domains.
      {ExGAM.Domain.Notifications, []}
    ]

    Supervisor.start_link(children,
      strategy: :rest_for_one,
      name: ExGAM.ApplicationSupervisor
    )
  end
end
