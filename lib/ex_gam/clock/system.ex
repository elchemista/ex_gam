defmodule ExGAM.Clock.System do
  @moduledoc false

  @behaviour ExGAM.Clock

  @impl true
  def now, do: System.system_time(:millisecond)
end
