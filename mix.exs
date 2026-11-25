defmodule ExGAM.MixProject do
  use Mix.Project

  @source_url "https://github.com/elchemista/ex_gam"

  def project do
    [
      app: :ex_gam,
      version: "0.1.0",
      elixir: "~> 1.19",
      name: "ExGAM",
      test_ignore_filters: [
        &String.contains?(&1, "/support/"),
        &String.ends_with?(&1, "/helper.exs")
      ],
      description: "Governed Act Model kernel and supervised domains for Elixir/OTP",
      source_url: @source_url,
      docs: [
        main: "ExGAM",
        source_ref: "main",
        groups_for_modules: [
          "Host API": [ExGAM, ExGAM.Domain, ExGAM.Scope, ExGAM.Proposal.Result, ExGAM.Audit],
          "Host behaviours": [
            ExGAM.Ingress,
            ExGAM.Attempt.Executor,
            ExGAM.Attempt.Observer,
            ExGAM.Secret.Broker,
            ExGAM.Genesis.Verifier,
            ExGAM.Payload.Store,
            ExGAM.Domain.Projection.Store,
            ExGAM.Domain.Recovery.Policy
          ],
          "Ledger and stores": ~r/^ExGAM\.Ledger(?:\.|$)/,
          "Governance records": [
            ExGAM.Mandate,
            ExGAM.Evidence,
            ExGAM.Act,
            ExGAM.Duty,
            ExGAM.Principal,
            ExGAM.Constitution,
            ExGAM.Genesis,
            ExGAM.HostProfile,
            ExGAM.Surface,
            ExGAM.Row,
            ExGAM.Candidate,
            ExGAM.Decision,
            ExGAM.Outcome
          ]
        ]
      ],
      package: [
        files: ~w(lib examples docs mix.exs README.md LICENSE .formatter.exs),
        licenses: ["Apache-2.0"],
        links: %{"Source" => @source_url}
      ],
      deps: [
        {:uuid_v7, "~> 0.6.0"},
        {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
        {:stream_data, "~> 1.4", only: :test}
      ]
    ]
  end

  def application do
    [mod: {ExGAM.Application, []}, extra_applications: [:logger, :crypto, :mnesia]]
  end
end
