defmodule ExGAM.Telemetry do
  @moduledoc false

  def emit(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [event, measurements, metadata])
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
