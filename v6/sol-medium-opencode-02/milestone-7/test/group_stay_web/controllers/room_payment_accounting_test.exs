defmodule GroupStayWeb.RoomPaymentAccountingTest do
  use GroupStayWeb.ConnCase

  defp open_operation do
    %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => "group",
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "advance_purchase",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 1_000},
        %{"room_id" => "b", "nightly_rate_cents" => 2_000}
      ]
    }
  end

  defp operation(type, id, attrs) do
    Map.merge(
      %{"operation_id" => id, "type" => type, "occurred_on" => "2026-10-02"},
      attrs
    )
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "allocates funding in room and operation order and reduces a payment in reverse fill order",
       %{conn: conn} do
    assert [_, _, _] =
             submit(conn, [
               open_operation(),
               operation("record_cash_payment", "pay-1", %{
                 "group_id" => "group",
                 "amount_cents" => 1_500
               }),
               operation("record_cash_payment", "pay-2", %{
                 "group_id" => "group",
                 "amount_cents" => 500
               })
             ])

    group = conn |> get("/api/v1/groups/group") |> json_response(200) |> Map.fetch!("data")

    assert Enum.map(group["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) ==
             [{"a", 1_000}, {"b", 1_000}]

    reduction =
      operation("reduce_cash_payment", "reduce", %{
        "payment_operation_id" => "pay-1",
        "amount_cents" => 750,
        "expected_revision" => 3
      })

    assert [result] = submit(conn, [reduction])
    assert result["outstanding_deposit_cents"] == 1_750
    assert result["revision"] == 4
    assert submit(conn, [reduction]) == [result]

    group = conn |> get("/api/v1/groups/group") |> json_response(200) |> Map.fetch!("data")

    assert Enum.map(group["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) ==
             [{"a", 750}, {"b", 500}]

    payment = conn |> get("/api/v1/payments/pay-1") |> json_response(200) |> Map.fetch!("data")
    assert payment["recorded_cents"] == 1_500
    assert payment["held_cents"] == 750
    assert payment["reduced_cents"] == 750

    assert Enum.sum(
             Map.take(
               payment,
               ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
             )
             |> Map.values()
           ) == 1_500
  end

  test "cancels selected rooms in original order and leaves other room accounting unchanged", %{
    conn: conn
  } do
    assert [_, _] =
             submit(conn, [
               open_operation(),
               operation("record_cash_payment", "pay", %{
                 "group_id" => "group",
                 "amount_cents" => 1_500
               })
             ])

    assert [cancelled] =
             submit(conn, [
               operation("cancel_rooms", "cancel-room", %{
                 "group_id" => "group",
                 "room_ids" => ["b", "a"]
               })
             ])

    assert cancelled["cancelled_room_ids"] == ["a", "b"]
    assert cancelled["retained_cents"] == 1_500

    group = conn |> get("/api/v1/groups/group") |> json_response(200) |> Map.fetch!("data")
    assert group["status"] == "cancelled"
    assert group["deposit_due_cents"] == 0

    assert [invalid] =
             submit(conn, [
               operation("cancel_rooms", "cancel-again", %{
                 "group_id" => "group",
                 "room_ids" => ["a"]
               })
             ])

    assert invalid["code"] == "group_not_active"
  end

  test "charges back held and refunded cash and reconciles the payment", %{conn: conn} do
    flexible = %{open_operation() | "rate_plan" => "flexible"}

    assert [_, _, _] =
             submit(conn, [
               flexible,
               operation("record_cash_payment", "pay", %{
                 "group_id" => "group",
                 "amount_cents" => 500
               }),
               operation("cancel_group", "cancel", %{
                 "group_id" => "group",
                 "occurred_on" => "2026-11-26"
               })
             ])

    assert [charged] =
             submit(conn, [
               operation("charge_back_payment", "chargeback", %{
                 "payment_operation_id" => "pay",
                 "expected_revision" => 3
               })
             ])

    assert charged["charged_back_cents"] == 500
    assert charged["revision"] == 4

    statement = conn |> get("/api/v1/payments/pay") |> json_response(200) |> Map.fetch!("data")
    assert statement["refunded_cents"] == 0
    assert statement["charged_back_cents"] == 500

    ledger = conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 500

    assert [rejected] =
             submit(conn, [
               operation("charge_back_payment", "chargeback-again", %{
                 "payment_operation_id" => "pay"
               })
             ])

    assert rejected["code"] == "payment_not_chargeable"
  end

  test "payment endpoint distinguishes missing and non-payment operations", %{conn: conn} do
    assert conn |> get("/api/v1/payments/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    assert [_] = submit(conn, [open_operation()])

    assert conn |> get("/api/v1/payments/open") |> json_response(422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }
  end

  test "chargeback of converted cash creates and later clears a credit shortfall", %{conn: conn} do
    source = %{open_operation() | "rate_plan" => "flexible"}

    target = %{
      open_operation()
      | "operation_id" => "open-target",
        "group_id" => "target",
        "arrival_on" => "2027-08-01",
        "departure_on" => "2027-08-02"
    }

    assert Enum.all?(
             submit(conn, [
               source,
               operation("record_cash_payment", "pay", %{
                 "group_id" => "group",
                 "amount_cents" => 100
               }),
               operation("cancel_group", "issue-credit", %{
                 "group_id" => "group",
                 "occurred_on" => "2026-11-26",
                 "refund_method" => "hotel_credit"
               }),
               target,
               operation("apply_hotel_credit", "apply-credit", %{
                 "group_id" => "target",
                 "amount_cents" => 110,
                 "occurred_on" => "2027-01-01"
               }),
               operation("charge_back_payment", "chargeback", %{
                 "payment_operation_id" => "pay"
               })
             ]),
             &(&1["status"] == "applied")
           )

    ledger =
      conn |> get("/api/v1/ledger?on=2027-01-01") |> json_response(200) |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 110
    assert ledger["credit_shortfall_cents"] == 110

    assert [cancelled] =
             submit(conn, [
               operation("cancel_group", "cancel-target", %{
                 "group_id" => "target",
                 "occurred_on" => "2027-06-01"
               })
             ])

    assert cancelled["status"] == "applied"

    ledger =
      conn |> get("/api/v1/ledger?on=2027-06-01") |> json_response(200) |> Map.fetch!("data")

    assert ledger["credit_liability_cents"] == 0
    assert ledger["credit_shortfall_cents"] == 0
  end
end
