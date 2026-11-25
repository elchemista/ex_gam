# Imported kernel fixtures; synthetic ingress is test-only.
Code.require_file("v0_4/support/fixture.ex", __DIR__)
Code.require_file("support/duty_frontier_assertions.ex", __DIR__)
Code.require_file("support/governed_boundary_case.ex", __DIR__)

unless Process.whereis(ExGAM.Test.ClockOwner) do
  {:ok, _pid} =
    Agent.start(
      fn ->
        ExGAM.V04Test.Runtime.reset(ExGAM.V04Test.Fixture.default_now())
      end,
      name: ExGAM.Test.ClockOwner
    )
end
