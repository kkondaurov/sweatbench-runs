defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase, async: false

  test "funding fills rooms in order and selected cancellation preserves payment provenance", %{
    conn: conn
  } do
    results =
      post_batch(conn, [
        open("source", "guest", [100, 100, 100]),
        cash("source", "pay-1", 150),
        cash("source", "pay-2", 100),
        cancel_rooms("source", "cancel-middle", ["room-2"], "2026-11-26")
      ])

    assert List.last(results) == %{
             "operation_id" => "cancel-middle",
             "status" => "applied",
             "group_id" => "source",
             "cancelled_room_ids" => ["room-2"],
             "refunded_cents" => 100,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 4
           }

    group = group("source")

    assert group["rooms"] == [
             room_view("room-1", 100, "active", 100, 0),
             room_view("room-2", 100, "cancelled", 0, 0),
             room_view("room-3", 100, "active", 50, 0)
           ]

    assert Map.take(
             group,
             ~w(status lodging_total_cents deposit_due_cents deposit_paid_cents cash_paid_cents outstanding_deposit_cents)
           ) == %{
             "status" => "active",
             "lodging_total_cents" => 1_000,
             "deposit_due_cents" => 200,
             "deposit_paid_cents" => 150,
             "cash_paid_cents" => 150,
             "outstanding_deposit_cents" => 50
           }

    assert payment("pay-1") == %{
             "payment_operation_id" => "pay-1",
             "original_group_id" => "source",
             "recorded_cents" => 150,
             "held_cents" => 100,
             "refunded_cents" => 50,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }

    assert payment("pay-2")["refunded_cents"] == 50
    assert payment("pay-2")["held_cents"] == 50

    [duplicate, already_cancelled, unknown] =
      post_batch(build_conn(), [
        cancel_rooms("source", "duplicate", ["room-1", "room-1"], "2026-11-26"),
        cancel_rooms("source", "already-cancelled", ["room-2"], "2026-11-26"),
        cancel_rooms("source", "unknown-room", ["room-1", "missing"], "2026-11-26")
      ])

    assert Enum.map([duplicate, already_cancelled, unknown], & &1["code"]) ==
             ["invalid_rooms", "invalid_rooms", "invalid_rooms"]

    assert group("source")["revision"] == 4

    [cancelled] =
      post_batch(build_conn(), [
        cancel_rooms("source", "cancel-rest", ["room-3", "room-1"], "2026-11-26")
      ])

    assert cancelled["cancelled_room_ids"] == ["room-1", "room-3"]
    assert group("source")["status"] == "cancelled"
    assert group("source")["deposit_due_cents"] == 0
  end

  test "cash reductions remove the target payment in reverse fill order and are durable", %{
    conn: conn
  } do
    post_batch(conn, [open("g", "guest", [100, 100]), cash("g", "pay", 150)])

    reduction = %{
      "operation_id" => "reduce-1",
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-05",
      "payment_operation_id" => "pay",
      "amount_cents" => 75,
      "expected_revision" => 2
    }

    [first] = post_batch(build_conn(), [reduction])
    assert first["revision"] == 3
    assert first["outstanding_deposit_cents"] == 125

    assert Enum.map(group("g")["rooms"], & &1["cash_paid_cents"]) == [75, 0]
    assert payment("pay")["held_cents"] == 75
    assert payment("pay")["reduced_cents"] == 75

    assert post_batch(build_conn(), [reduction]) == [first]
    assert group("g")["revision"] == 3

    [too_much, stale, complete, empty] =
      post_batch(build_conn(), [
        reduce(reduction, "too-much", 76, nil),
        reduce(reduction, "stale", -1, 2),
        reduce(reduction, "complete", 75, 3),
        reduce(reduction, "empty", 1, 4)
      ])

    assert too_much["code"] == "reduction_exceeds_held_cash"
    assert stale["code"] == "stale_revision"
    assert complete["status"] == "applied"
    assert empty["code"] == "payment_not_reducible"
    assert payment("pay")["reduced_cents"] == 150

    ledger = ledger()
    assert ledger["cash_reduced_cents"] == 150
    assert ledger["cash_held_cents"] == 0
  end

  test "reduction and reconciliation distinguish missing and non-payment durable records", %{
    conn: conn
  } do
    post_batch(conn, [open("g", "guest", [100])])

    assert json_response(get(build_conn(), "/api/v1/payments/missing"), 404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    assert json_response(get(build_conn(), "/api/v1/payments/open-g"), 422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }

    [missing, wrong] =
      post_batch(build_conn(), [
        %{
          "operation_id" => "r-missing",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "missing",
          "amount_cents" => 1
        },
        %{
          "operation_id" => "r-wrong",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2026-10-05",
          "payment_operation_id" => "open-g",
          "amount_cents" => 1
        }
      ])

    assert missing["code"] == "operation_not_found"
    assert wrong["code"] == "payment_not_reducible"
  end

  test "chargeback reclassifies settled cash and exposes a spent-credit shortfall", %{conn: conn} do
    post_batch(conn, [
      open("source", "guest", [101, 100]),
      cash("source", "pay-1", 101),
      cash("source", "pay-2", 100),
      cancel_group("source", "convert", "2026-11-26", "hotel_credit"),
      open("target", "guest", [200]),
      credit("target", "spend", 150)
    ])

    assert ledger()["cash_converted_to_credit_cents"] == 201
    assert ledger()["credit_liability_cents"] == 221
    target_revision = group("target")["revision"]

    chargeback = %{
      "operation_id" => "chargeback",
      "type" => "charge_back_payment",
      "occurred_on" => "2026-11-25",
      "payment_operation_id" => "pay-1",
      "expected_revision" => 4
    }

    [result] = post_batch(build_conn(), [chargeback])
    assert result["charged_back_cents"] == 101
    assert result["revision"] == 5
    assert result["outstanding_deposit_cents"] == 0
    assert group("target")["revision"] == target_revision

    assert Map.take(
             ledger(),
             ~w(cash_converted_to_credit_cents cash_charged_back_cents credit_liability_cents credit_shortfall_cents)
           ) == %{
             "cash_converted_to_credit_cents" => 100,
             "cash_charged_back_cents" => 101,
             "credit_liability_cents" => 150,
             "credit_shortfall_cents" => 40
           }

    assert payment("pay-1")["converted_to_credit_cents"] == 0
    assert payment("pay-1")["charged_back_cents"] == 101
    assert payment("pay-2")["converted_to_credit_cents"] == 100

    [restored] = post_batch(build_conn(), [cancel_group("target", "restore", "2026-11-26")])
    assert restored["status"] == "applied"
    assert credit_balance("guest", "2026-11-26") == 110
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 110

    assert post_batch(build_conn(), [chargeback]) == [result]

    [again] =
      post_batch(build_conn(), [
        %{chargeback | "operation_id" => "chargeback-again", "expected_revision" => 5}
      ])

    assert again["code"] == "payment_not_chargeable"
  end

  test "partial hotel-credit cancellation computes one combined bonus and restores allocated credit",
       %{conn: conn} do
    post_batch(conn, [
      open("seed", "guest", [100]),
      cash("seed", "seed-pay", 100),
      cancel_group("seed", "seed-credit", "2026-11-26", "hotel_credit"),
      open("g", "guest", [55, 55]),
      cash("g", "cash", 5),
      credit("g", "credit", 105)
    ])

    [cancelled] =
      post_batch(build_conn(), [
        cancel_rooms("g", "partial-credit", ["room-1"], "2026-11-26", "hotel_credit")
      ])

    # One bonus is calculated on the selected room's combined five cash cents: 5 + round(0.5).
    assert cancelled["credit_issued_cents"] == 6
    assert cancelled["refunded_cents"] == 0
    assert credit_balance("guest", "2026-11-26") == 61
    assert Enum.at(group("g")["rooms"], 1)["credit_paid_cents"] == 55
  end

  defp open(group_id, guest_id, deposits) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" =>
        deposits
        |> Enum.with_index(1)
        |> Enum.map(fn {deposit, index} ->
          %{"room_id" => "room-#{index}", "nightly_rate_cents" => deposit * 5}
        end)
    }
  end

  defp cash(group_id, operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp credit(group_id, operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-11-26",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel_group(group_id, operation_id, on, method \\ "cash") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => on,
      "group_id" => group_id,
      "refund_method" => method
    }
  end

  defp cancel_rooms(group_id, operation_id, room_ids, on, method \\ "cash") do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => on,
      "group_id" => group_id,
      "room_ids" => room_ids,
      "refund_method" => method
    }
  end

  defp reduce(template, operation_id, amount, revision) do
    template
    |> Map.put("operation_id", operation_id)
    |> Map.put("amount_cents", amount)
    |> then(fn operation ->
      if revision,
        do: Map.put(operation, "expected_revision", revision),
        else: Map.delete(operation, "expected_revision")
    end)
  end

  defp room_view(id, due, status, cash, credit),
    do: %{
      "room_id" => id,
      "nightly_rate_cents" => due * 5,
      "status" => status,
      "lodging_total_cents" => due * 5,
      "deposit_due_cents" => due,
      "cash_paid_cents" => cash,
      "credit_paid_cents" => credit
    }

  defp post_batch(conn, operations),
    do:
      conn
      |> post("/api/v1/partner-batches", %{"operations" => operations})
      |> json_response(200)
      |> Map.fetch!("results")

  defp group(id),
    do: build_conn() |> get("/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp payment(id),
    do: build_conn() |> get("/api/v1/payments/#{id}") |> json_response(200) |> Map.fetch!("data")

  defp ledger,
    do:
      build_conn()
      |> get("/api/v1/ledger?on=2026-12-02")
      |> json_response(200)
      |> Map.fetch!("data")

  defp credit_balance(guest, on),
    do:
      build_conn()
      |> get("/api/v1/guests/#{guest}/credit?on=#{on}")
      |> json_response(200)
      |> get_in(["data", "available_cents"])
end
