defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  defp open(group_id, guest_id \\ "guest-1") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "hotel-1",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "#{group_id}-a", "nightly_rate_cents" => 5_000},
        %{"room_id" => "#{group_id}-b", "nightly_rate_cents" => 10_000}
      ]
    }
  end

  defp op(type, id, attrs) do
    Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => "2027-01-02"}, attrs)
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  test "allocates funding by room, cancels selected rooms, and reduces in reverse fill order", %{
    conn: conn
  } do
    [_, _, _, cancelled, reduced] =
      submit(conn, [
        open("group"),
        op("record_cash_payment", "pay-1", %{"group_id" => "group", "amount_cents" => 1_500}),
        op("record_cash_payment", "pay-2", %{"group_id" => "group", "amount_cents" => 1_000}),
        op("cancel_rooms", "cancel-b", %{
          "group_id" => "group",
          "room_ids" => ["group-b"],
          "expected_revision" => 3
        }),
        op("reduce_cash_payment", "reduce-1", %{
          "payment_operation_id" => "pay-1",
          "amount_cents" => 500,
          "expected_revision" => 4
        })
      ])

    assert cancelled == %{
             "operation_id" => "cancel-b",
             "status" => "applied",
             "group_id" => "group",
             "cancelled_room_ids" => ["group-b"],
             "refunded_cents" => 1_500,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 4
           }

    assert reduced["outstanding_deposit_cents"] == 500
    assert reduced["revision"] == 5

    group =
      build_conn() |> get("/api/v1/groups/group") |> json_response(200) |> Map.fetch!("data")

    assert group["status"] == "active"
    assert group["deposit_due_cents"] == 1_000
    assert group["cash_paid_cents"] == 500

    assert Enum.map(group["rooms"], &{&1["room_id"], &1["status"], &1["cash_paid_cents"]}) == [
             {"group-a", "active", 500},
             {"group-b", "cancelled", 0}
           ]

    assert build_conn() |> get("/api/v1/payments/pay-1") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "pay-1",
               "original_group_id" => "group",
               "recorded_cents" => 1_500,
               "held_cents" => 500,
               "refunded_cents" => 500,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 500,
               "charged_back_cents" => 0
             }
           }

    assert build_conn()
           |> get("/api/v1/payments/pay-2")
           |> json_response(200)
           |> get_in(["data", "refunded_cents"]) == 1_000
  end

  test "validates room cancellation atomically and returns room ids in original order", %{
    conn: conn
  } do
    [_, invalid, cancelled] =
      submit(conn, [
        open("group"),
        op("cancel_rooms", "invalid", %{
          "group_id" => "group",
          "room_ids" => ["group-a", "group-a"]
        }),
        op("cancel_rooms", "cancel", %{
          "group_id" => "group",
          "room_ids" => ["group-b", "group-a"]
        })
      ])

    assert invalid["code"] == "invalid_rooms"
    assert cancelled["cancelled_room_ids"] == ["group-a", "group-b"]

    group =
      build_conn() |> get("/api/v1/groups/group") |> json_response(200) |> Map.fetch!("data")

    assert group["status"] == "cancelled"
    assert group["deposit_due_cents"] == 0
  end

  test "charges back held and converted cash and reports a credit shortfall", %{conn: conn} do
    [_, _, _, _, _, chargeback] =
      submit(conn, [
        open("source"),
        op("record_cash_payment", "pay", %{"group_id" => "source", "amount_cents" => 2_000}),
        op("cancel_group", "make-credit", %{
          "group_id" => "source",
          "refund_method" => "hotel_credit"
        }),
        open("target"),
        op("apply_hotel_credit", "use-credit", %{"group_id" => "target", "amount_cents" => 2_200}),
        op("charge_back_payment", "chargeback", %{
          "payment_operation_id" => "pay",
          "expected_revision" => 3
        })
      ])

    assert chargeback["charged_back_cents"] == 2_000
    assert chargeback["group_id"] == "source"
    assert chargeback["revision"] == 4

    ledger =
      build_conn()
      |> get("/api/v1/ledger?on=2027-01-03")
      |> json_response(200)
      |> Map.fetch!("data")

    assert ledger["cash_converted_to_credit_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 2_000
    assert ledger["credit_liability_cents"] == 2_200
    assert ledger["credit_shortfall_cents"] == 2_200

    payment =
      build_conn() |> get("/api/v1/payments/pay") |> json_response(200) |> Map.fetch!("data")

    assert payment["converted_to_credit_cents"] == 0
    assert payment["charged_back_cents"] == 2_000

    target =
      build_conn() |> get("/api/v1/groups/target") |> json_response(200) |> Map.fetch!("data")

    assert target["revision"] == 2
  end

  test "returns stable payment lookup and reduction errors", %{conn: conn} do
    [_, rejected_payment, missing, wrong_type] =
      submit(conn, [
        open("group"),
        op("record_cash_payment", "rejected-pay", %{"group_id" => "group", "amount_cents" => 0}),
        op("reduce_cash_payment", "missing", %{
          "payment_operation_id" => "absent",
          "amount_cents" => 1
        }),
        op("reduce_cash_payment", "wrong-type", %{
          "payment_operation_id" => "open-group",
          "amount_cents" => 1
        })
      ])

    assert rejected_payment["code"] == "invalid_amount"
    assert missing["code"] == "operation_not_found"
    assert wrong_type["code"] == "payment_not_reducible"

    assert build_conn() |> get("/api/v1/payments/absent") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    assert build_conn() |> get("/api/v1/payments/rejected-pay") |> json_response(422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }
  end
end
