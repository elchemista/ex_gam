Code.require_file("../helper.exs", __DIR__)

defmodule ExGAM.PublicFacadeBoundaryTest do
  use ExUnit.Case, async: true

  alias ExGAM.Facade.Access

  test "authority and read APIs reject values that are not authenticated handles" do
    assert {:error, :authenticated_context_required} = ExGAM.open_scope(nil, nil)

    assert {:error, :invalid_governed_scope_opening} =
             ExGAM.open_scope(nil, nil, %{}, %{}, [])

    assert {:error, :invalid_turn} = ExGAM.open_turn(nil, "hello")
    assert {:error, :invalid_turn_continuation} = ExGAM.continue_turn(nil, nil, [])
    assert {:error, :invalid_scope} = ExGAM.surface(nil)
    assert {:error, :invalid_dispatch_query} = ExGAM.dispatch_status(nil, "act")
    assert {:error, :invalid_stateful_turn} = ExGAM.turn(nil, "hello", %{}, [])
    assert {:error, :invalid_presentation} = ExGAM.prepare_presentation(nil, %{})

    assert {:error, :invalid_principal_registration} =
             ExGAM.register_principal(nil, %{}, %{})

    assert {:error, :invalid_mandate_delegation} = ExGAM.delegate_mandate(nil, %{}, %{})
    assert {:error, :invalid_mandate_delegation} = ExGAM.issue_mandate(nil, %{}, %{})

    assert {:error, :invalid_mandate_devolution} =
             ExGAM.devolve_mandate(nil, "child", %{}, %{})

    assert {:error, :invalid_mandate_restriction} =
             ExGAM.restrict_mandate(nil, "prior", %{}, %{})

    assert {:error, :invalid_mandate_revocation} = ExGAM.revoke_mandate(nil, "mandate", %{})
    assert {:error, :invalid_duty_disposition} = ExGAM.dispose_duty(nil, %{}, %{})
    assert {:error, :invalid_erasure_request} = ExGAM.request_erasure(nil, %{}, %{})

    assert {:error, :authenticated_scope_required} = ExGAM.acts(nil)
    assert {:error, :authenticated_scope_required} = ExGAM.declassifications(nil)
    assert {:error, :authenticated_scope_required} = ExGAM.erasures(nil)
  end

  test "the shared facade boundary never interprets malformed host replies as success" do
    assert {:error, :context_domain_mismatch} = Access.context_domain_binding(nil, nil)

    assert {:error, {:invalid_sequencer_response, :query_failed}} =
             Access.sequencer_result(fn -> :unexpected_reply end, :query_failed)

    assert {:error, :durable_error} =
             Access.sequencer_result(fn -> {:error, :durable_error} end, :query_failed)

    assert {:error, :query_failed} =
             Access.sequencer_result(fn -> raise "private domain failure" end, :query_failed)

    assert {:error, {:invalid_keyword_options, :query}} = Access.validate_keyword(%{}, :query)

    assert {:error, {:invalid_keyword_options, :query}} =
             Access.nested_keyword([query: %{timeout: 10}], :query)
  end
end
