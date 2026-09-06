defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  test "funding fills rooms in order and selected cancellation settles only those rooms", %{
    conn: conn
  } do
    operations = [
      open_operation("group", 2),
      payment_operation("pay", "group", 150, 1),
      cancel_rooms_operation("cancel-room-b", "group", ["b"], 2)
    ]

    %{"results" => [_, payment, cancellation]} = post_batch(conn, operations)
    assert payment["outstanding_deposit_cents"] == 50

    assert cancellation == %{
             "operation_id" => "cancel-room-b",
             "status" => "applied",
             "group_id" => "group",
             "cancelled_room_ids" => ["b"],
             "refunded_cents" => 50,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    group = get_group("group")

    assert group
           |> Map.take([
             "status",
             "lodging_total_cents",
             "deposit_due_cents",
             "deposit_paid_cents",
             "outstanding_deposit_cents"
           ]) == %{
             "status" => "active",
             "lodging_total_cents" => 500,
             "deposit_due_cents" => 100,
             "deposit_paid_cents" => 100,
             "outstanding_deposit_cents" => 0
           }

    assert group["rooms"] == [
             %{
               "room_id" => "a",
               "nightly_rate_cents" => 500,
               "status" => "active",
               "deposit_due_cents" => 100,
               "cash_paid_cents" => 100,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "b",
               "nightly_rate_cents" => 500,
               "status" => "cancelled",
               "deposit_due_cents" => 100,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }
           ]

    assert get_payment("pay") ==
             payment_statement("pay", "group", 150, held_cents: 100, refunded_cents: 50)

    assert get_ledger("2026-10-06") |> Map.take(["cash_held_cents", "cash_refunded_cents"]) == %{
             "cash_held_cents" => 100,
             "cash_refunded_cents" => 50
           }
  end

  test "room cancellation validates the complete selection and returns original room order", %{
    conn: conn
  } do
    operations = [
      open_operation("group", 3),
      cancel_rooms_operation("bad-duplicate", "group", ["a", "a"], 1),
      cancel_rooms_operation("bad-missing", "group", ["a", "missing"], 1),
      cancel_rooms_operation("ordered", "group", ["c", "a"], 1)
    ]

    %{"results" => [_, duplicate, missing, ordered]} = post_batch(conn, operations)
    assert duplicate["code"] == "invalid_rooms"
    assert missing["code"] == "invalid_rooms"
    assert ordered["cancelled_room_ids"] == ["a", "c"]
    assert ordered["revision"] == 2
    assert get_group("group")["status"] == "active"
  end

  test "cash reductions target one payment, remove its reverse fill, and are durably idempotent",
       %{conn: conn} do
    reduction = reduce_operation("reduce-pay-1", "pay-1", 30, 3)

    operations = [
      open_operation("group", 2),
      payment_operation("pay-1", "group", 150, 1),
      payment_operation("pay-2", "group", 50, 2),
      reduction,
      reduction
    ]

    %{"results" => [_, _, _, original, replay]} = post_batch(conn, operations)
    assert replay == original

    assert original == %{
             "operation_id" => "reduce-pay-1",
             "status" => "applied",
             "payment_operation_id" => "pay-1",
             "group_id" => "group",
             "amount_cents" => 30,
             "outstanding_deposit_cents" => 30,
             "revision" => 4
           }

    assert Enum.map(get_group("group")["rooms"], & &1["cash_paid_cents"]) == [100, 70]

    assert get_payment("pay-1") ==
             payment_statement("pay-1", "group", 150, held_cents: 120, reduced_cents: 30)

    assert get_payment("pay-2") == payment_statement("pay-2", "group", 50, held_cents: 50)

    %{"results" => [too_much, complete, no_more]} =
      post_batch(build_conn(), [
        reduce_operation("too-much", "pay-1", 121, 4),
        reduce_operation("complete", "pay-1", 120, 4),
        reduce_operation("no-more", "pay-1", 1, 5)
      ])

    assert too_much["code"] == "reduction_exceeds_held_cash"
    assert complete["status"] == "applied"
    assert no_more["code"] == "payment_not_reducible"
  end

  test "chargeback reclassifies converted cash and tracks and absorbs applied-credit shortfall",
       %{conn: conn} do
    operations = [
      open_operation("source", 1),
      payment_operation("source-pay", "source", 100, 1),
      cancel_group_operation("convert", "source", 2, %{"refund_method" => "hotel_credit"}),
      open_operation("target", 2),
      credit_operation("target-credit", "target", 110, 1),
      chargeback_operation("chargeback", "source-pay", 3)
    ]

    %{"results" => results} = post_batch(conn, operations)

    assert List.last(results) == %{
             "operation_id" => "chargeback",
             "status" => "applied",
             "payment_operation_id" => "source-pay",
             "group_id" => "source",
             "charged_back_cents" => 100,
             "outstanding_deposit_cents" => 0,
             "revision" => 4
           }

    ledger = get_ledger("2026-10-06")
    assert ledger["cash_converted_to_credit_cents"] == 0
    assert ledger["cash_charged_back_cents"] == 100
    assert ledger["credit_liability_cents"] == 110
    assert ledger["credit_shortfall_cents"] == 110
    assert get_credit("guest", "2026-10-06")["available_cents"] == 0
    assert get_group("target")["revision"] == 2

    %{"results" => [settled]} =
      post_batch(build_conn(), [cancel_group_operation("cancel-target", "target", 2)])

    assert settled["status"] == "applied"
    assert get_ledger("2026-10-06")["credit_shortfall_cents"] == 0
    assert get_ledger("2026-10-06")["credit_liability_cents"] == 0
    assert get_credit("guest", "2026-10-06")["available_cents"] == 0
  end

  test "chargeback entitlement telescopes across payments and payment errors are distinct", %{
    conn: conn
  } do
    operations = [
      open_operation("source", 1),
      payment_operation("first", "source", 5, 1),
      payment_operation("second", "source", 5, 2),
      cancel_group_operation("convert", "source", 3, %{"refund_method" => "hotel_credit"}),
      chargeback_operation("charge-first", "first", 4),
      chargeback_operation("charge-first-again", "first", 5),
      chargeback_operation("missing", "unknown", 5)
    ]

    %{"results" => results} = post_batch(conn, operations)
    assert Enum.at(results, 4)["charged_back_cents"] == 5
    assert Enum.at(results, 5)["code"] == "payment_not_chargeable"
    assert Enum.at(results, 6)["code"] == "operation_not_found"
    assert get_credit("guest", "2026-10-06")["available_cents"] == 5
    assert get_payment("first") == payment_statement("first", "source", 5, charged_back_cents: 5)

    assert get_payment("second") ==
             payment_statement("second", "source", 5, converted_to_credit_cents: 5)

    assert build_conn() |> get("/api/v1/payments/unknown") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }

    assert build_conn() |> get("/api/v1/payments/convert") |> json_response(422) == %{
             "error" => %{"code" => "payment_not_reconcilable"}
           }
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp get_group(group_id) do
    build_conn() |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_payment(operation_id) do
    build_conn()
    |> get("/api/v1/payments/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_credit(guest_id, on) do
    build_conn()
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_ledger(on) do
    build_conn() |> get("/api/v1/ledger?on=#{on}") |> json_response(200) |> Map.fetch!("data")
  end

  defp open_operation(group_id, room_count) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "arrival_on" => "2026-12-20",
      "departure_on" => "2026-12-21",
      "rate_plan" => "flexible",
      "rooms" =>
        Enum.map(Enum.take(~w(a b c), room_count), fn room_id ->
          %{"room_id" => room_id, "nightly_rate_cents" => 500}
        end)
    }
  end

  defp payment_operation(operation_id, group_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp credit_operation(operation_id, group_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp cancel_rooms_operation(operation_id, group_id, room_ids, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => "2026-10-06",
      "group_id" => group_id,
      "room_ids" => room_ids,
      "expected_revision" => revision
    }
  end

  defp cancel_group_operation(operation_id, group_id, revision, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => "2026-10-06",
        "group_id" => group_id,
        "expected_revision" => revision
      },
      overrides
    )
  end

  defp reduce_operation(operation_id, payment_operation_id, amount, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-05",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount,
      "expected_revision" => revision
    }
  end

  defp chargeback_operation(operation_id, payment_operation_id, revision) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-06",
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => revision
    }
  end

  defp payment_statement(operation_id, group_id, recorded, overrides) do
    Map.merge(
      %{
        "payment_operation_id" => operation_id,
        "original_group_id" => group_id,
        "recorded_cents" => recorded,
        "held_cents" => 0,
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "converted_to_credit_cents" => 0,
        "reduced_cents" => 0,
        "charged_back_cents" => 0
      },
      Map.new(overrides, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end
end
