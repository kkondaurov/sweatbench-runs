defmodule GroupStayWeb.OperationControllerTest do
  @moduledoc """
  Coverage of the durable operation read endpoint: it exposes the stored
  result of a remembered operation, applied or rejected, and nothing else.
  """

  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerHelpers

  test "returns the stored result of an applied operation" do
    post_batch([open_group_operation("op-1")])
    conn = post_batch([pay_operation("op-2", "group-81", 5_000)])
    original = hd(results(conn))

    conn = get_operation("op-2")

    assert json_response(conn, 200) == %{"data" => original}
  end

  test "returns the stored result of a rejected operation" do
    post_batch([open_group_operation("op-1")])

    conn = post_batch([pay_operation("op-2", "group-81", 999_999)])
    original = hd(results(conn))
    assert original["code"] == "payment_exceeds_outstanding"

    conn = get_operation("op-2")

    assert json_response(conn, 200) == %{"data" => original}
  end

  test "an unknown operation identifier is not found" do
    conn = get_operation("op-never")

    assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
  end
end
