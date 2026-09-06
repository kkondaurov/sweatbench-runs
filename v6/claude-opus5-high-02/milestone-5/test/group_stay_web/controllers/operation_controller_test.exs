defmodule GroupStayWeb.OperationControllerTest do
  use GroupStayWeb.ConnCase, async: false

  test "reports the stored result of an applied operation" do
    result = submit_one(open_group(%{"rooms" => [room("room-a", 10_000)]}))

    assert read_operation("op-open") == {200, %{"data" => result}}
  end

  test "reports the stored result of a rejected operation" do
    result = submit_one(record_cash_payment())
    assert result["code"] == "group_not_found"

    assert read_operation("op-pay") == {200, %{"data" => result}}
  end

  test "exposes the result and nothing else about the record" do
    submit_one(open_group(%{"rooms" => [room("room-a", 10_000)]}))

    {200, body} = read_operation("op-open")

    assert body == %{
             "data" => %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-81",
               "deposit_due_cents" => 6_000,
               "revision" => 1
             }
           }
  end

  test "an identifier that was never committed is not found" do
    assert read_operation("op-never-sent") ==
             {404, %{"error" => %{"code" => "operation_not_found"}}}
  end

  test "an operation that could not name itself is not remembered" do
    assert submit_one(Map.delete(open_group(), "operation_id"))["operation_id"] == nil

    assert {404, %{"error" => %{"code" => "operation_not_found"}}} = read_operation("op-open")
  end

  test "a rejected reuse of an identifier does not replace the stored result" do
    applied = submit_one(open_group())

    assert submit_one(open_group(%{"property_id" => "other"}))["code"] == "operation_id_conflict"

    assert read_operation("op-open") == {200, %{"data" => applied}}
  end
end
