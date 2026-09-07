defmodule GroupStayWeb.RoomAccountingAndPaymentReductionsTest do
  use GroupStayWeb.ConnCase

  describe "room-level funding and selected-room settlement" do
    test "funds in room order and returns cancelled rooms in original order", %{conn: conn} do
      submit(conn, open_group("source", [room("source", 10_000)], guest_id: "guest"))
      submit(conn, cash_payment("source-pay", "source", 2_000))

      submit(
        conn,
        cancel_group("source-cancel", "source", "2026-11-01", refund_method: "hotel_credit")
      )

      submit(conn, open_group("target", three_rooms(), guest_id: "guest"))
      submit(conn, cash_payment("pay-one", "target", 2_500))
      submit(conn, credit_payment("credit-one", "target", 2_000, "2026-11-02"))
      submit(conn, cash_payment("pay-two", "target", 1_000))

      assert [first, second, third] = group(conn, "target")["rooms"]

      assert Map.take(
               first,
               ~w(room_id status deposit_due_cents cash_paid_cents credit_paid_cents)
             ) == %{
               "room_id" => "room-1",
               "status" => "active",
               "deposit_due_cents" => 2_000,
               "cash_paid_cents" => 2_000,
               "credit_paid_cents" => 0
             }

      assert {second["cash_paid_cents"], second["credit_paid_cents"]} == {500, 1_500}
      assert {third["cash_paid_cents"], third["credit_paid_cents"]} == {1_000, 500}

      result =
        submit(
          conn,
          cancel_rooms("cancel-two-rooms", "target", ["room-3", "room-2"], "2026-12-01")
        )

      assert result == %{
               "operation_id" => "cancel-two-rooms",
               "status" => "applied",
               "group_id" => "target",
               "cancelled_room_ids" => ["room-2", "room-3"],
               "refunded_cents" => 1_500,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 5
             }

      target = group(conn, "target")
      assert target["status"] == "active"
      assert target["lodging_total_cents"] == 10_000
      assert target["deposit_due_cents"] == 2_000
      assert target["deposit_paid_cents"] == 2_000
      assert target["outstanding_deposit_cents"] == 0

      assert Enum.map(target["rooms"], & &1["status"]) == ["active", "cancelled", "cancelled"]
      assert payment(conn, "pay-one")["refunded_cents"] == 500
      assert payment(conn, "pay-one")["held_cents"] == 2_000
      assert payment(conn, "pay-two")["refunded_cents"] == 1_000
      assert credit(conn, "guest", "2026-12-01")["available_cents"] == 2_200

      duplicate =
        submit(
          conn,
          cancel_rooms("duplicate-rooms", "target", ["room-1", "room-1"], "2026-12-01")
        )

      assert duplicate["code"] == "invalid_rooms"
      assert group(conn, "target")["revision"] == 5
    end
  end

  describe "cash reductions" do
    test "removes only the target payment in reverse fill order and reconciles it", %{conn: conn} do
      submit(conn, open_group("group", [room("one", 10_000), room("two", 10_000)]))
      original = cash_payment("payment", "group", 3_000)
      submit(conn, original)
      submit(conn, cash_payment("later-payment", "group", 1_000))

      reduction = reduce_payment("reduce-1", "payment", 1_500, expected_revision: 3)

      assert submit(conn, reduction) == %{
               "operation_id" => "reduce-1",
               "status" => "applied",
               "payment_operation_id" => "payment",
               "group_id" => "group",
               "amount_cents" => 1_500,
               "outstanding_deposit_cents" => 1_500,
               "revision" => 4
             }

      assert Enum.map(group(conn, "group")["rooms"], & &1["cash_paid_cents"]) == [1_500, 1_000]

      assert payment(conn, "payment") == %{
               "payment_operation_id" => "payment",
               "original_group_id" => "group",
               "recorded_cents" => 3_000,
               "held_cents" => 1_500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_500,
               "charged_back_cents" => 0
             }

      assert submit(conn, reduction)["revision"] == 4
      assert submit(conn, original)["outstanding_deposit_cents"] == 1_000

      excessive = submit(conn, reduce_payment("reduce-too-much", "payment", 1_501))
      assert excessive["code"] == "reduction_exceeds_held_cash"

      assert ledger(conn)["cash_reduced_cents"] == 1_500
      assert ledger(conn)["cash_held_cents"] == 2_500

      chargeback = submit(conn, charge_back("charge-remainder", "payment"))
      assert chargeback["charged_back_cents"] == 1_500
      assert chargeback["outstanding_deposit_cents"] == 3_000
      assert Enum.map(group(conn, "group")["rooms"], & &1["cash_paid_cents"]) == [0, 1_000]

      statement = payment(conn, "payment")
      assert statement["reduced_cents"] == 1_500
      assert statement["charged_back_cents"] == 1_500

      dispositions =
        Map.take(
          statement,
          ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)
        )

      assert Enum.sum(Map.values(dispositions)) == statement["recorded_cents"]
    end

    test "uses stable target rejection codes and revision precedence", %{conn: conn} do
      assert submit(conn, reduce_payment("missing", "unknown", 1))["code"] ==
               "operation_not_found"

      submit(conn, open_group("group", [room("one", 10_000)]))

      assert submit(conn, reduce_payment("wrong-kind", "open-group", 1))["code"] ==
               "payment_not_reducible"

      submit(conn, cash_payment("payment", "group", 1_000))

      stale =
        submit(conn, reduce_payment("stale", "payment", -1, expected_revision: 99))

      assert stale["code"] == "stale_revision"
      assert submit(conn, reduce_payment("invalid", "payment", 0))["code"] == "invalid_amount"

      submit(conn, reduce_payment("all", "payment", 1_000))

      assert submit(conn, reduce_payment("none-left", "payment", 1))["code"] ==
               "payment_not_reducible"
    end
  end

  describe "payment chargebacks" do
    test "assigns a combined credit bonus by running funding totals", %{conn: conn} do
      submit(conn, open_group("rounding", [room("tiny", 50)], guest_id: "guest"))
      submit(conn, cash_payment("first-five", "rounding", 5))
      submit(conn, cash_payment("second-five", "rounding", 5))

      submit(
        conn,
        cancel_group("combined-credit", "rounding", "2026-11-01", refund_method: "hotel_credit")
      )

      assert credit(conn, "guest", "2026-11-01")["available_cents"] == 11

      assert submit(conn, charge_back("charge-first", "first-five"))["charged_back_cents"] == 5
      assert credit(conn, "guest", "2026-11-01")["available_cents"] == 5
      assert ledger(conn)["cash_converted_to_credit_cents"] == 5

      assert submit(conn, charge_back("charge-second", "second-five"))["charged_back_cents"] == 5
      assert credit(conn, "guest", "2026-11-01")["available_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "reclassifies settlement, claws back spent credit, and leaves funded groups unchanged",
         %{
           conn: conn
         } do
      submit(
        conn,
        open_group("original", [room("one", 10_000), room("two", 10_000)], guest_id: "guest")
      )

      submit(conn, cash_payment("payment", "original", 4_000))

      submit(
        conn,
        cancel_rooms("convert-room", "original", ["one"], "2026-11-01",
          refund_method: "hotel_credit"
        )
      )

      submit(
        conn,
        open_group("funded-refundable", [room("refundable-room", 5_500)], guest_id: "guest")
      )

      submit(
        conn,
        open_group("funded-nonref", [room("nonref-room", 1_100)],
          guest_id: "guest",
          rate_plan: "advance_purchase"
        )
      )

      submit(
        conn,
        credit_payment("spend-refundable", "funded-refundable", 1_100, "2026-11-02")
      )

      submit(conn, credit_payment("spend-nonref", "funded-nonref", 1_100, "2026-11-02"))
      submit(conn, cancel_rooms("retain-room", "original", ["two"], "2026-12-09"))

      assert group(conn, "original")["status"] == "cancelled"
      assert group(conn, "funded-refundable")["revision"] == 2
      assert group(conn, "funded-nonref")["revision"] == 2

      result = submit(conn, charge_back("chargeback", "payment", expected_revision: 4))

      assert result == %{
               "operation_id" => "chargeback",
               "status" => "applied",
               "payment_operation_id" => "payment",
               "group_id" => "original",
               "charged_back_cents" => 4_000,
               "outstanding_deposit_cents" => 0,
               "revision" => 5
             }

      assert group(conn, "funded-refundable")["revision"] == 2
      assert group(conn, "funded-nonref")["revision"] == 2
      assert group(conn, "funded-refundable")["credit_paid_cents"] == 1_100
      assert group(conn, "funded-nonref")["credit_paid_cents"] == 1_100
      assert ledger(conn)["cash_retained_cents"] == 0
      assert ledger(conn)["cash_converted_to_credit_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 4_000
      assert ledger(conn)["credit_liability_cents"] == 2_200
      assert ledger(conn)["credit_shortfall_cents"] == 2_200

      statement = payment(conn, "payment")
      assert statement["charged_back_cents"] == 4_000
      assert statement["retained_cents"] == 0
      assert statement["converted_to_credit_cents"] == 0

      assert submit(conn, charge_back("again", "payment"))["code"] == "payment_not_chargeable"

      submit(conn, cancel_group("consume-funded", "funded-nonref", "2027-01-01"))
      assert ledger(conn)["credit_liability_cents"] == 1_100
      assert ledger(conn)["credit_shortfall_cents"] == 1_100

      submit(conn, cancel_group("restore-funded", "funded-refundable", "2027-01-01"))
      assert ledger(conn)["credit_liability_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
    end
  end

  describe "payment reads" do
    test "distinguishes missing and non-payment operation records", %{conn: conn} do
      assert get(conn, "/api/v1/payments/missing") |> json_response(404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      submit(conn, open_group("group", [room("one", 10_000)]))

      assert get(conn, "/api/v1/payments/open-group") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end
  end

  defp submit(conn, operation) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => [operation]})
    |> json_response(200)
    |> get_in(["results", Access.at(0)])
  end

  defp group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp payment(conn, operation_id) do
    conn
    |> get("/api/v1/payments/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp credit(conn, guest_id, on) do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger?on=2027-01-01") |> json_response(200) |> Map.fetch!("data")
  end

  defp open_group(group_id, rooms, options \\ []) do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => group_id,
      "guest_id" => Keyword.get(options, :guest_id, "guest-#{group_id}"),
      "property_id" => "hotel",
      "arrival_on" => "2027-03-01",
      "departure_on" => "2027-03-02",
      "rate_plan" => Keyword.get(options, :rate_plan, "flexible"),
      "rooms" => rooms
    }
  end

  defp room(id, rate), do: %{"room_id" => id, "nightly_rate_cents" => rate}
  defp three_rooms, do: [room("room-1", 10_000), room("room-2", 10_000), room("room-3", 10_000)]

  defp cash_payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp credit_payment(operation_id, group_id, amount, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel_group(operation_id, group_id, occurred_on, options \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
    |> maybe_put("refund_method", options[:refund_method])
  end

  defp cancel_rooms(operation_id, group_id, room_ids, occurred_on, options \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "room_ids" => room_ids
    }
    |> maybe_put("refund_method", options[:refund_method])
  end

  defp reduce_payment(operation_id, payment_operation_id, amount, options \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-03",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount
    }
    |> maybe_put("expected_revision", options[:expected_revision])
  end

  defp charge_back(operation_id, payment_operation_id, options \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-01",
      "payment_operation_id" => payment_operation_id
    }
    |> maybe_put("expected_revision", options[:expected_revision])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
