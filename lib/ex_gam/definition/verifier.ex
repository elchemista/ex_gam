defmodule ExGAM.Definition.Verifier do
  @moduledoc """
  Optional static diagnostic for a host's immutable authoring format.

  The kernel accepts portable Definitions without interpreting an Agent DSL.
  A verifier can inspect fixed declarations against a Surface, but its report
  is never a substitute for live admission, consent or executor validation.
  """

  @doc "Checks the immutable Definition against the supplied governed Surface."
  @callback verify(ExGAM.Surface.t(), ExGAM.Definition.t()) ::
              {:ok, ExGAM.Surface.definition_report()} | {:error, term()}
end
