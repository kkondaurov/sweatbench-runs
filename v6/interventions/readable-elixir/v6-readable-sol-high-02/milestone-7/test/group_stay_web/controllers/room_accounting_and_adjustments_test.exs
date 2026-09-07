defmodule GroupStayWeb.RoomAccountingAndAdjustmentsTest do
  use GroupStayWeb.ConnCase, async: false

  describe "room accounting and selected cancellation" do
    test "funds in room order and settles selected rooms in original order", %{conn: conn} do
      results =
        post_batch(conn, [
          open_operation(),
          cash_operation("cash-1", 120),
          cash_operation("cash-2", 80),
          cancel_rooms_operation(%{"room_ids" => ["room-b", "room-a"]})
        ])

      assert Enum.at(results, 3) == %{
               "operation_id" => "cancel-rooms",
               "status" => "applied",
               "group_id" => "group-1",
               "cancelled_room_ids" => ["room-a", "room-b"],
               "refunded_cents" => 200,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 4
             }

      group = get_group("group-1")
      assert group["status"] == "cancelled"
      assert group["lodging_total_cents"] == 0
      assert group["deposit_due_cents"] == 0
      assert group["deposit_paid_cents"] == 0
      assert Enum.map(group["rooms"], & &1["status"]) == ["cancelled", "cancelled"]
      assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [0, 0]
    end

    test "rejects duplicate, missing, and already cancelled rooms atomically", %{conn: conn} do
      results =
        post_batch(conn, [
          open_operation(),
          cancel_rooms_operation(%{
            "operation_id" => "duplicate",
            "room_ids" => ["room-a", "room-a"]
          }),
          cancel_rooms_operation(%{"operation_id" => "missing", "room_ids" => ["absent"]}),
          cancel_rooms_operation(%{"operation_id" => "first", "room_ids" => ["room-a"]}),
          cancel_rooms_operation(%{"operation_id" => "again", "room_ids" => ["room-a"]})
        ])

      assert Enum.map(
               [Enum.at(results, 1), Enum.at(results, 2), Enum.at(results, 4)],
               & &1["code"]
             ) ==
               ["invalid_rooms", "invalid_rooms", "invalid_rooms"]

      group = get_group("group-1")
      assert group["revision"] == 2
      assert group["deposit_due_cents"] == 150
      assert Enum.map(group["rooms"], & &1["status"]) == ["cancelled", "active"]
    end
  end

  describe "cash reductions and reconciliation" do
    test "reduces only the target payment in reverse fill order and composes", %{conn: conn} do
      results =
        post_batch(conn, [
          open_operation(),
          cash_operation("cash-1", 200),
          reduce_operation("reduce-1", "cash-1", 70),
          reduce_operation("reduce-2", "cash-1", 130)
        ])

      assert Enum.at(results, 2)
             |> Map.take(["amount_cents", "outstanding_deposit_cents", "revision"]) == %{
               "amount_cents" => 70,
               "outstanding_deposit_cents" => 170,
               "revision" => 3
             }

      assert Enum.at(results, 3)["revision"] == 4

      statement = get_payment("cash-1")
      assert statement["recorded_cents"] == 200
      assert statement["held_cents"] == 0
      assert statement["reduced_cents"] == 200

      group = get_group("group-1")
      assert Enum.map(group["rooms"], & &1["cash_paid_cents"]) == [0, 0]

      ledger = get_ledger()
      assert ledger["cash_reduced_cents"] == 200
      assert ledger["cash_held_cents"] == 0
    end

    test "uses stable reduction errors and durably replays adjustments", %{conn: conn} do
      reduction = reduce_operation("reduce", "cash-1", 40)

      [_, _, too_much, invalid, applied] =
        post_batch(conn, [
          open_operation(),
          cash_operation("cash-1", 100),
          reduce_operation("too-much", "cash-1", 101),
          reduce_operation("invalid", "cash-1", 0),
          reduction
        ])

      assert too_much["code"] == "reduction_exceeds_held_cash"
      assert invalid["code"] == "invalid_amount"
      assert applied["revision"] == 3

      [replay, exhausted, missing, wrong_type] =
        post_batch(build_conn(), [
          reduction,
          reduce_operation("exhausted", "cash-1", 60),
          reduce_operation("missing", "unknown", 1),
          reduce_operation("wrong", "open-1", 1)
        ])

      assert replay == applied
      assert exhausted["status"] == "applied"
      assert missing["code"] == "operation_not_found"
      assert wrong_type["code"] == "payment_not_reducible"
      assert get_payment("cash-1")["reduced_cents"] == 100
    end

    test "distinguishes payment read errors", %{conn: conn} do
      post_batch(conn, [open_operation(), cash_operation("cash-rejected", 999)])

      assert get(build_conn(), "/api/v1/payments/absent") |> json_response(404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      assert get(build_conn(), "/api/v1/payments/open-1") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }

      assert get(build_conn(), "/api/v1/payments/cash-rejected") |> json_response(422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end
  end

  describe "chargebacks" do
    test "charges back held and refunded dispositions without changing the stored payment result",
         %{
           conn: conn
         } do
      payment = cash_operation("cash-1", 200)
      [_, original] = post_batch(conn, [open_operation(), payment])

      [_, charged_back] =
        post_batch(build_conn(), [
          cancel_rooms_operation(%{"operation_id" => "cancel-a", "room_ids" => ["room-a"]}),
          chargeback_operation("charge", "cash-1")
        ])

      assert charged_back["charged_back_cents"] == 200
      assert charged_back["group_id"] == "group-1"

      assert get_payment("cash-1")
             |> Map.take(["charged_back_cents", "refunded_cents", "held_cents"]) == %{
               "charged_back_cents" => 200,
               "refunded_cents" => 0,
               "held_cents" => 0
             }

      [replay] = post_batch(build_conn(), [payment])
      assert replay == original

      ledger = get_ledger()
      assert ledger["cash_charged_back_cents"] == 200
      assert ledger["cash_refunded_cents"] == 0
    end

    test "claws back rounded credit entitlement and absorbs a spent shortfall on restoration", %{
      conn: conn
    } do
      post_batch(conn, [
        open_operation(),
        cash_operation("cash-1", 100),
        cash_operation("cash-2", 100),
        cancel_rooms_operation(%{
          "operation_id" => "convert-a",
          "room_ids" => ["room-a"],
          "refund_method" => "hotel_credit"
        }),
        open_operation(%{"operation_id" => "open-2", "group_id" => "group-2"}),
        credit_operation("use-credit", "group-2", 130)
      ])

      group_two_revision = get_group("group-2")["revision"]
      [chargeback] = post_batch(build_conn(), [chargeback_operation("charge", "cash-1")])
      assert chargeback["charged_back_cents"] == 100
      assert get_group("group-2")["revision"] == group_two_revision

      ledger = get_ledger("2027-01-03")
      assert ledger["credit_shortfall_cents"] == 75
      assert ledger["credit_liability_cents"] == 130

      post_batch(build_conn(), [
        cancel_rooms_operation(%{
          "operation_id" => "cancel-group-2",
          "group_id" => "group-2",
          "room_ids" => ["room-a"],
          "occurred_on" => "2027-01-04"
        })
      ])

      ledger = get_ledger("2027-01-04")
      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 55
    end
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "hotel-1",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 750},
          %{"room_id" => "room-b", "nightly_rate_cents" => 750}
        ]
      },
      overrides
    )
  end

  defp cash_operation(operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-01",
      "group_id" => "group-1",
      "amount_cents" => amount
    }
  end

  defp credit_operation(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-03",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancel_rooms_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2027-01-02",
        "group_id" => "group-1",
        "room_ids" => ["room-a"]
      },
      overrides
    )
  end

  defp reduce_operation(operation_id, payment_operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2027-01-02",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount
    }
  end

  defp chargeback_operation(operation_id, payment_operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-03",
      "payment_operation_id" => payment_operation_id
    }
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_group(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_payment(operation_id) do
    build_conn()
    |> get("/api/v1/payments/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_ledger(on \\ nil) do
    path = if on, do: "/api/v1/ledger?on=#{on}", else: "/api/v1/ledger"

    build_conn()
    |> get(path)
    |> json_response(200)
    |> Map.fetch!("data")
  end
end
