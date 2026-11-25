defmodule ExGAM.Id.UUIDv7 do
  @moduledoc false

  @behaviour ExGAM.Id.Source

  @impl true
  def generate, do: UUIDv7.generate()
end
