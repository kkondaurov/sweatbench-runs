defmodule GroupStayWeb.GuestCreditControllerTest do
  use GroupStayWeb.ConnCase

  @batch_path "/api/v1/partner-batches"

  defp run(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@batch_path, Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp payment_op(group_id, amount_cents) do
    %{
      "operation_id" => "op-pay-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(op_id, group_id, occurred_on) do
    %{
      "operation_id" => op_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "refund_method" => "hotel_credit"
    }
  end

  defp credit(conn, guest_id \\ "guest-22", query \\ "") do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit#{query}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp issue_lot(conn, op_id, group_id, cash_cents, occurred_on, open_overrides \\ %{}) do
    run(conn, [
      open_op(group_id, open_overrides),
      payment_op(group_id, cash_cents),
      cancel_op(op_id, group_id, occurred_on)
    ])
  end

  test "returns zero credit for a guest with no lots", %{conn: conn} do
    assert credit(conn) == %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
  end

  test "returns issued lots with their remaining cents and expiry", %{conn: conn} do
    assert [_, _, _] =
             issue_lot(conn, "cancel-17", "group-a", 5_000, "2027-05-02", %{
               "occurred_on" => "2027-04-01",
               "arrival_on" => "2027-06-10",
               "departure_on" => "2027-06-13"
             })

    assert credit(conn) == %{
             "guest_id" => "guest-22",
             "available_cents" => 5_500,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-17",
                 "remaining_cents" => 5_500,
                 "expires_on" => "2028-05-02"
               }
             ]
           }
  end

  test "omits exhausted lots", %{conn: conn} do
    assert [_, _, _] = issue_lot(conn, "cancel-1", "group-a", 1_000, "2026-10-20")
    assert [_] = run(conn, [open_op("group-b")])

    assert [applied] =
             run(conn, [
               %{
                 "operation_id" => "op-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-10-21",
                 "group_id" => "group-b",
                 "amount_cents" => 1_100
               }
             ])

    assert applied["status"] == "applied"
    assert credit(conn) == %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
  end

  test "omits expired lots as of the requested date", %{conn: conn} do
    assert [_, _, _] = issue_lot(conn, "cancel-1", "group-a", 1_000, "2026-10-20")

    assert credit(conn, "guest-22", "?on=2027-10-20")["available_cents"] == 1_100
    assert credit(conn, "guest-22", "?on=2027-10-21")["available_cents"] == 0
    assert credit(conn, "guest-22", "?on=2027-10-21")["lots"] == []
  end

  test "orders lots by expiry and then source operation", %{conn: conn} do
    assert [_, _, _] = issue_lot(conn, "cancel-late", "group-a", 1_000, "2026-10-25")
    assert [_, _, _] = issue_lot(conn, "cancel-b", "group-b", 1_000, "2026-10-20")
    assert [_, _, _] = issue_lot(conn, "cancel-a", "group-c", 1_000, "2026-10-20")

    assert Enum.map(credit(conn)["lots"], & &1["source_operation_id"]) ==
             ~w(cancel-a cancel-b cancel-late)
  end

  test "rejects an unusable on date", %{conn: conn} do
    response = get(conn, "/api/v1/guests/guest-22/credit?on=not-a-date")

    assert json_response(response, 422) == %{"error" => %{"code" => "invalid_date"}}
  end
end
