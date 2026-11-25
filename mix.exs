defmodule ExGAM.MixProject do
  use Mix.Project

  @version "0.1.0"
  @homepage_url "https://spectre.guide/en/governed-act-model"
  @source_url "https://github.com/elchemista/ex_gam"

  def project do
    [
      app: :ex_gam,
      version: @version,
      elixir: "~> 1.19",
      name: "ExGAM",
      test_coverage: [summary: [threshold: 93]],
      test_ignore_filters: [
        &String.contains?(&1, "/support/"),
        &String.ends_with?(&1, "/helper.exs")
      ],
      description:
        "Elixir/OTP implementation of the Governed Act Model with supervised domains and pluggable ledger stores.",
      homepage_url: @homepage_url,
      source_url: @source_url,
      # OTP 28 reports opaque type mismatches for MapSet values in struct defaults.
      # Use the same opacity setting as the upstream Spectre kernel.
      dialyzer: [plt_ignore_apps: [:ex_gam], flags: [:no_opaque]],
      docs: [
        main: "readme",
        source_ref: @version,
        assets: %{"examples" => "examples"},
        extras: ["README.md", "docs/storage.md", "docs/spectre.md", "CHANGELOG.md", "LICENSE"],
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
        name: "ex_gam",
        maintainers: ["elchemista"],
        files: ~w(lib examples docs mix.exs README.md CHANGELOG.md LICENSE .formatter.exs),
        licenses: ["Apache-2.0"],
        links: %{
          "Manifesto" => @homepage_url,
          "Formal model" => "https://github.com/elchemista/gam",
          "GitHub" => @source_url,
          "Documentation" => "https://hexdocs.pm/ex_gam",
          "Changelog" => "https://hexdocs.pm/ex_gam/changelog.html"
        }
      ],
      deps: [
        {:uuid_v7, "~> 0.6.0"},
        {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: :dev, runtime: false},
        {:stream_data, "~> 1.4", only: :test}
      ]
    ]
  end

  def application do
    [mod: {ExGAM.Application, []}, extra_applications: [:logger, :crypto, :mnesia]]
  end
end
