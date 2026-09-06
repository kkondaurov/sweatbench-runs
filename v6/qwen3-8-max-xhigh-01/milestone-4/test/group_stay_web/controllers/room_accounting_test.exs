defmodule GroupStayWeb.RoomAccountingTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Groups.{CashPayment, Group}
  alias GroupStay.Repo

  @batch_path "/api/v1/partner-batches"
  @group_path "/api/v1/groups"
  @ledger_path "/api/v1/ledger"

  defp open_group_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp payment_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      overrides
    )
  end

  defp cancel_rooms_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-rooms",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      },
      overrides
    )
  end

  defp reduce_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1000
      },
      overrides
    )
  end

  defp chargeback_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-05",
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn = post(conn, @batch_path, %{operations: operations})
    {conn, json_response(conn, 200)["results"]}
  end

  defp open_group(conn, overrides \\ %{}) do
    {conn, [result]} = post_batch(conn, [open_group_op(overrides)])
    assert %{"status" => "applied"} = result
    {conn, result}
  end

  defp get_group(conn, group_id) do
    conn = get(conn, "#{@group_path}/#{group_id}")
    {conn, json_response(conn, 200)["data"]}
  end

  defp get_ledger(conn) do
    conn = get(conn, @ledger_path)
    {conn, json_response(conn, 200)["data"]}
  end

  defp pay(conn, op_id, group_id, amount_cents, overrides \\ %{}) do
    {conn, [result]} =
      post_batch(conn, [
        payment_op(
          Map.merge(
            %{"operation_id" => op_id, "group_id" => group_id, "amount_cents" => amount_cents},
            overrides
          )
        )
      ])

    assert result["status"] == "applied"
    conn
  end

  defp room(group, room_id) do
    Enum.find(group["rooms"], &(&1["room_id"] == room_id))
  end

  describe "room-level accounting" do
    test "exposes per-room deposit and funding, filling rooms in order", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = pay(conn, "pay-2", "group-81", 6000)

      {_conn, group} = get_group(conn, "group-81")

      a = room(group, "room-a")
      b = room(group, "room-b")

      assert a["status"] == "active"
      assert a["deposit_due_cents"] == 9000
      assert a["cash_paid_cents"] == 9000
      assert a["credit_paid_cents"] == 0

      assert b["status"] == "active"
      assert b["deposit_due_cents"] == 10500
      assert b["cash_paid_cents"] == 2000
      assert b["credit_paid_cents"] == 0

      assert group["cash_paid_cents"] == 11000
      assert group["outstanding_deposit_cents"] == 8500
    end

    test "credit funds rooms after cash in room order", %{conn: conn} do
      {conn, _} = open_group(conn, %{"group_id" => "group-src"})
      conn = pay(conn, "pay-src", "group-src", 8000)

      {conn, [_]} =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-src",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-src",
            "refund_method" => "hotel_credit"
          }
        ])

      {conn, _} = open_group(conn, %{"operation_id" => "open-81", "group_id" => "group-81"})

      {conn, [_]} =
        post_batch(conn, [
          %{
            "operation_id" => "apply-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => 4000
          }
        ])

      {_conn, group} = get_group(conn, "group-81")

      assert room(group, "room-a")["credit_paid_cents"] == 4000
      assert room(group, "room-b")["credit_paid_cents"] == 0
      assert group["credit_paid_cents"] == 4000
    end

    test "group totals describe active rooms only", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 9000)

      {conn, [_]} = post_batch(conn, [cancel_rooms_op(%{"room_ids" => ["room-a"]})])

      {_conn, group} = get_group(conn, "group-81")

      assert group["deposit_due_cents"] == 10500
      assert group["lodging_total_cents"] == 52500
      assert group["cash_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 10500
    end
  end

  describe "cancel_rooms" do
    test "settles a selected refundable room and keeps the rest", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 11000)

      {conn, [result]} =
        post_batch(conn, [
          cancel_rooms_op(%{"room_ids" => ["room-a"], "occurred_on" => "2026-10-04"})
        ])

      assert result == %{
               "operation_id" => "op-cancel-rooms",
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-a"],
               "refunded_cents" => 9000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      {_conn, group} = get_group(conn, "group-81")
      assert group["status"] == "active"
      assert room(group, "room-a")["status"] == "cancelled"
      assert room(group, "room-b")["status"] == "active"
      assert room(group, "room-b")["cash_paid_cents"] == 2000
    end

    test "returns cancelled_room_ids in original room order", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 11000)

      {_conn, [result]} =
        post_batch(conn, [cancel_rooms_op(%{"room_ids" => ["room-b", "room-a"]})])

      assert result["cancelled_room_ids"] == ["room-a", "room-b"]
    end

    test "computes the hotel-credit bonus once on combined cash", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 11000)

      {conn, [result]} =
        post_batch(conn, [
          cancel_rooms_op(%{
            "room_ids" => ["room-a", "room-b"],
            "refund_method" => "hotel_credit",
            "occurred_on" => "2026-10-04"
          })
        ])

      # combined cash 11000 -> bonus 1100 -> 12100
      assert result["credit_issued_cents"] == 12100
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      {_conn, group} = get_group(conn, "group-81")
      assert group["status"] == "cancelled"
    end

    test "rejects room lists that are not distinct active rooms", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {_conn, results} =
        post_batch(conn, [
          cancel_rooms_op(%{"operation_id" => "c-1", "room_ids" => ["nope"]}),
          cancel_rooms_op(%{"operation_id" => "c-2", "room_ids" => ["room-a", "room-a"]}),
          cancel_rooms_op(%{"operation_id" => "c-3", "room_ids" => []}),
          cancel_rooms_op(%{"operation_id" => "c-4", "room_ids" => "room-a"})
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_rooms"} = result
      end

      {_conn, group} = get_group(conn, "group-81")
      assert group["revision"] == 2
    end

    test "rejects an already cancelled room", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 11000)
      {conn, [_]} = post_batch(conn, [cancel_rooms_op(%{"room_ids" => ["room-a"]})])

      {_conn, [result]} =
        post_batch(conn, [cancel_rooms_op(%{"operation_id" => "c-2", "room_ids" => ["room-a"]})])

      assert %{"status" => "rejected", "code" => "invalid_rooms"} = result
    end

    test "the group becomes cancelled when no active rooms remain", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 11000)

      {conn, [_]} = post_batch(conn, [cancel_rooms_op(%{"room_ids" => ["room-a"]})])

      {conn, [result]} =
        post_batch(conn, [cancel_rooms_op(%{"operation_id" => "c-2", "room_ids" => ["room-b"]})])

      assert result["status"] == "applied"

      {_conn, group} = get_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["outstanding_deposit_cents"] == 0
    end

    test "cancel_group settles only the remaining active rooms", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 11000)
      {conn, [_]} = post_batch(conn, [cancel_rooms_op(%{"room_ids" => ["room-a"]})])

      {conn, [result]} =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-all",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81"
          }
        ])

      # only room-b's 2000 remains to refund
      assert result["refunded_cents"] == 2000
      assert result["status"] == "applied"

      {_conn, group} = get_group(conn, "group-81")
      assert group["status"] == "cancelled"
    end

    test "hotel credit is rejected for a non-refundable room cancellation", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {_conn, [result]} =
        post_batch(conn, [
          cancel_rooms_op(%{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"})
        ])

      assert %{"status" => "rejected", "code" => "refund_method_not_available"} = result
    end

    test "restores applied credit on a refundable room cancellation", %{conn: conn} do
      {conn, _} = open_group(conn, %{"group_id" => "group-src"})
      conn = pay(conn, "pay-src", "group-src", 8000)

      {conn, [_]} =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-src",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-src",
            "refund_method" => "hotel_credit"
          }
        ])

      {conn, _} = open_group(conn, %{"operation_id" => "open-81", "group_id" => "group-81"})

      {conn, [_]} =
        post_batch(conn, [
          %{
            "operation_id" => "apply-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "amount_cents" => 4000
          }
        ])

      {conn, [_]} = post_batch(conn, [cancel_rooms_op(%{"group_id" => "group-81"})])

      conn = get(conn, "/api/v1/guests/guest-22/credit", %{"on" => "2026-10-05"})
      credit = json_response(conn, 200)["data"]
      assert credit["available_cents"] == 8800
    end
  end

  describe "reduce_cash_payment" do
    test "reduces held cash and reopens the outstanding deposit", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {conn, [result]} =
        post_batch(conn, [reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 2000})])

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "pay-1",
               "group_id" => "group-81",
               "amount_cents" => 2000,
               "outstanding_deposit_cents" => 16500,
               "revision" => 3
             }

      {conn, group} = get_group(conn, "group-81")
      assert group["cash_paid_cents"] == 3000
      assert group["outstanding_deposit_cents"] == 16500

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_held_cents"] == 3000
      assert ledger["cash_reduced_cents"] == 2000
    end

    test "removes held allocations in reverse fill order", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 11000)

      {conn, [_]} =
        post_batch(conn, [reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 2000})])

      {_conn, group} = get_group(conn, "group-81")
      # reverse fill removes from room-b first (it held 2000)
      assert room(group, "room-a")["cash_paid_cents"] == 9000
      assert room(group, "room-b")["cash_paid_cents"] == 0
    end

    test "successive reductions compose against remaining held cash", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {conn, [r1]} =
        post_batch(conn, [
          reduce_op(%{
            "operation_id" => "r-1",
            "payment_operation_id" => "pay-1",
            "amount_cents" => 2000
          })
        ])

      assert r1["status"] == "applied"

      {conn, [r2]} =
        post_batch(conn, [
          reduce_op(%{
            "operation_id" => "r-2",
            "payment_operation_id" => "pay-1",
            "amount_cents" => 3000
          })
        ])

      assert r2["status"] == "applied"
      assert r2["outstanding_deposit_cents"] == 19500

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_reduced_cents"] == 5000
      assert ledger["cash_held_cents"] == 0
    end

    test "rejects reduction of a missing or non-payment record", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {_conn, results} =
        post_batch(conn, [
          reduce_op(%{"operation_id" => "r-1", "payment_operation_id" => "nope"}),
          reduce_op(%{"operation_id" => "r-2", "payment_operation_id" => "op-open"}),
          reduce_op(%{
            "operation_id" => "r-3",
            "payment_operation_id" => "pay-1",
            "amount_cents" => 0
          }),
          reduce_op(%{
            "operation_id" => "r-4",
            "payment_operation_id" => "pay-1",
            "amount_cents" => -5
          }),
          reduce_op(%{
            "operation_id" => "r-5",
            "payment_operation_id" => "pay-1",
            "amount_cents" => 5001
          })
        ])

      assert Enum.at(results, 0)["code"] == "operation_not_found"
      assert Enum.at(results, 1)["code"] == "payment_not_reducible"
      assert Enum.at(results, 2)["code"] == "invalid_amount"
      assert Enum.at(results, 3)["code"] == "invalid_amount"
      assert Enum.at(results, 4)["code"] == "reduction_exceeds_held_cash"
    end

    test "rejects reduction once there is no held cash left", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      {conn, [_]} = post_batch(conn, [cancel_op_for("group-81")])

      {_conn, [result]} =
        post_batch(conn, [reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 1000})])

      assert %{"status" => "rejected", "code" => "payment_not_reducible"} = result
    end

    test "is durably idempotent", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {conn, [first]} =
        post_batch(conn, [reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 2000})])

      {conn, [retry]} =
        post_batch(conn, [reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 2000})])

      assert retry == first

      {_conn, group} = get_group(conn, "group-81")
      assert group["cash_paid_cents"] == 3000
      assert group["revision"] == 3
    end
  end

  describe "charge_back_payment" do
    test "reverses held cash on an active group", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {conn, [result]} =
        post_batch(conn, [chargeback_op(%{"payment_operation_id" => "pay-1"})])

      assert result == %{
               "operation_id" => "op-chargeback",
               "status" => "applied",
               "payment_operation_id" => "pay-1",
               "group_id" => "group-81",
               "charged_back_cents" => 5000,
               "outstanding_deposit_cents" => 19500,
               "revision" => 3
             }

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
    end

    test "reverses refunded cash on a cancelled group", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      {conn, [_]} = post_batch(conn, [cancel_op_for("group-81")])

      {conn, [result]} =
        post_batch(conn, [chargeback_op(%{"payment_operation_id" => "pay-1"})])

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 5000

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
    end

    test "does not reverse already-reduced cash", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {conn, [_]} =
        post_batch(conn, [reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 2000})])

      {conn, [result]} =
        post_batch(conn, [chargeback_op(%{"payment_operation_id" => "pay-1"})])

      assert result["charged_back_cents"] == 3000

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_reduced_cents"] == 2000
      assert ledger["cash_charged_back_cents"] == 3000
    end

    test "rejects a missing, non-payment, fully reduced, or repeated chargeback", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {conn, [missing]} =
        post_batch(conn, [
          chargeback_op(%{"operation_id" => "c-1", "payment_operation_id" => "nope"})
        ])

      assert missing["code"] == "operation_not_found"

      {conn, [not_payment]} =
        post_batch(conn, [
          chargeback_op(%{"operation_id" => "c-2", "payment_operation_id" => "op-open"})
        ])

      assert not_payment["code"] == "payment_not_chargeable"

      {conn, [_]} =
        post_batch(conn, [reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 5000})])

      {conn, [fully_reduced]} =
        post_batch(conn, [
          chargeback_op(%{"operation_id" => "c-3", "payment_operation_id" => "pay-1"})
        ])

      assert fully_reduced["code"] == "payment_not_chargeable"

      {conn, _} = open_group(conn, %{"operation_id" => "open-2", "group_id" => "group-2"})
      conn = pay(conn, "pay-2", "group-2", 3000)

      {conn, [_]} =
        post_batch(conn, [
          chargeback_op(%{"operation_id" => "c-4", "payment_operation_id" => "pay-2"})
        ])

      {_conn, [repeated]} =
        post_batch(conn, [
          chargeback_op(%{"operation_id" => "c-5", "payment_operation_id" => "pay-2"})
        ])

      assert repeated["code"] == "payment_not_chargeable"
    end

    test "revokes credit entitlement and records shortfall", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 8000)

      {conn, [_]} =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-credit",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      # lot worth 8800, guest spends 5000 on a new group leaving 3800
      {conn, _} = open_group(conn, %{"operation_id" => "open-2", "group_id" => "group-2"})

      {conn, [_]} =
        post_batch(conn, [
          %{
            "operation_id" => "apply-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-2",
            "amount_cents" => 5000
          }
        ])

      {conn, [result]} =
        post_batch(conn, [chargeback_op(%{"payment_operation_id" => "pay-1"})])

      # entitlement is the full 8800; only 3800 remains in the lot
      assert result["charged_back_cents"] == 8000

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_converted_to_credit_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 8000
      # shortfall = min(unrecovered 5000, applied credit 5000) = 5000
      assert ledger["credit_shortfall_cents"] == 5000
      assert ledger["credit_liability_cents"] == 5000
    end

    test "is durably idempotent", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {conn, [first]} = post_batch(conn, [chargeback_op(%{"payment_operation_id" => "pay-1"})])
      {conn, [retry]} = post_batch(conn, [chargeback_op(%{"payment_operation_id" => "pay-1"})])

      assert retry == first

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_charged_back_cents"] == 5000
    end
  end

  describe "legacy bring-forward" do
    test "allocates pre-durable funding as a senior block without changing totals", %{conn: conn} do
      {conn, _} = open_group(conn)

      group = Repo.get_by!(Group, group_id: "group-81")

      %CashPayment{}
      |> CashPayment.create_changeset(%{
        group_id: group.id,
        amount_cents: 5000,
        occurred_on: ~D[2026-10-04],
        operation_id: nil
      })
      |> Repo.insert!()

      group
      |> Ecto.Changeset.change(
        cash_paid_cents: 5000,
        deposit_paid_cents: 5000,
        outstanding_deposit_cents: 14500
      )
      |> Repo.update!()

      {conn, group_view} = get_group(conn, "group-81")

      assert room(group_view, "room-a")["cash_paid_cents"] == 5000
      assert group_view["cash_paid_cents"] == 5000
      assert group_view["outstanding_deposit_cents"] == 14500

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_held_cents"] == 5000
    end

    test "legacy funding cannot be reduced", %{conn: conn} do
      {conn, _} = open_group(conn)

      group = Repo.get_by!(Group, group_id: "group-81")

      %CashPayment{}
      |> CashPayment.create_changeset(%{
        group_id: group.id,
        amount_cents: 5000,
        occurred_on: ~D[2026-10-04],
        operation_id: nil
      })
      |> Repo.insert!()

      group
      |> Ecto.Changeset.change(
        cash_paid_cents: 5000,
        deposit_paid_cents: 5000,
        outstanding_deposit_cents: 14500
      )
      |> Repo.update!()

      {_conn, [result]} =
        post_batch(conn, [
          reduce_op(%{"payment_operation_id" => "legacy-pay", "amount_cents" => 1000})
        ])

      assert %{"status" => "rejected", "code" => "operation_not_found"} = result
    end
  end

  describe "chargeback entitlements across payments" do
    test "entitlements telescope when several payments fund one lot", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-a", "group-81", 3000)
      conn = pay(conn, "pay-b", "group-81", 2000)

      {conn, [cancel]} =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-credit",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      # lot = 5000 + 500 bonus = 5500
      assert cancel["credit_issued_cents"] == 5500

      # pay-a entitlement: V(3000) = 3300; pay-b: V(5000) - V(3000) = 5500 - 3300 = 2200
      {conn, [_]} =
        post_batch(conn, [
          chargeback_op(%{"operation_id" => "cb-a", "payment_operation_id" => "pay-a"})
        ])

      conn = get(conn, "/api/v1/guests/guest-22/credit", %{"on" => "2026-10-04"})
      assert json_response(conn, 200)["data"]["available_cents"] == 2200

      {conn, [_]} =
        post_batch(conn, [
          chargeback_op(%{"operation_id" => "cb-b", "payment_operation_id" => "pay-b"})
        ])

      conn = get(conn, "/api/v1/guests/guest-22/credit", %{"on" => "2026-10-04"})
      assert json_response(conn, 200)["data"]["available_cents"] == 0
    end

    test "a payment contributing to several lots is clawed back per lot", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 19500)

      {conn, [first]} =
        post_batch(conn, [
          cancel_rooms_op(%{"room_ids" => ["room-a"], "refund_method" => "hotel_credit"})
        ])

      assert first["credit_issued_cents"] == 9900

      {conn, [second]} =
        post_batch(conn, [
          cancel_rooms_op(%{
            "operation_id" => "c-2",
            "room_ids" => ["room-b"],
            "refund_method" => "hotel_credit"
          })
        ])

      assert second["credit_issued_cents"] == 11550

      {conn, [result]} = post_batch(conn, [chargeback_op(%{"payment_operation_id" => "pay-1"})])
      assert result["charged_back_cents"] == 19500

      conn = get(conn, "/api/v1/guests/guest-22/credit", %{"on" => "2026-10-04"})
      assert json_response(conn, 200)["data"]["available_cents"] == 0

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_converted_to_credit_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 19500
    end

    test "restoration to a shortfalled lot extinguishes clawback before becoming available", %{
      conn: conn
    } do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 8000)

      {conn, [_]} =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-credit",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "refund_method" => "hotel_credit"
          }
        ])

      {conn, _} = open_group(conn, %{"operation_id" => "open-2", "group_id" => "group-2"})

      {conn, [_]} =
        post_batch(conn, [
          %{
            "operation_id" => "apply-credit",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-2",
            "amount_cents" => 5000
          }
        ])

      # chargeback leaves 5000 unrecovered (entitlement 8800, only 3800 in lot)
      {conn, [_]} = post_batch(conn, [chargeback_op(%{"payment_operation_id" => "pay-1"})])

      {conn, ledger} = get_ledger(conn)
      assert ledger["credit_shortfall_cents"] == 5000
      assert ledger["credit_liability_cents"] == 5000

      # refundably cancelling group-2 restores the 5000, absorbed by the clawback
      {conn, [_]} =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-2",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-2"
          }
        ])

      {_conn, ledger_after} = get_ledger(conn)
      assert ledger_after["credit_shortfall_cents"] == 0
      assert ledger_after["credit_liability_cents"] == 0
    end
  end

  describe "cancel_rooms settlement variants" do
    test "retains cash for a non-refundable room cancellation", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 11000)

      {conn, [result]} =
        post_batch(conn, [
          cancel_rooms_op(%{"room_ids" => ["room-a"], "occurred_on" => "2026-11-27"})
        ])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 9000
      assert result["credit_issued_cents"] == 0

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_retained_cents"] == 9000
      assert ledger["cash_held_cents"] == 2000
    end

    test "unpaid deposit on a cancelled room ceases to be due", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 3000)

      {conn, [_]} = post_batch(conn, [cancel_rooms_op(%{"room_ids" => ["room-a"]})])

      {_conn, group} = get_group(conn, "group-81")
      # room-a held 3000 of its 9000 deposit; the unpaid 6000 is no longer due
      assert group["deposit_due_cents"] == 10500
      assert group["cash_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 10500
    end
  end

  describe "expected_revision on payment reductions and chargebacks" do
    test "reduce applies when the expected revision matches", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {_conn, [result]} =
        post_batch(conn, [
          reduce_op(%{
            "payment_operation_id" => "pay-1",
            "amount_cents" => 1000,
            "expected_revision" => 2
          })
        ])

      assert result["status"] == "applied"
      assert result["revision"] == 3
    end

    test "reduce rejects a stale revision before the reduction", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {_conn, [result]} =
        post_batch(conn, [
          reduce_op(%{
            "payment_operation_id" => "pay-1",
            "amount_cents" => 1000,
            "expected_revision" => 1
          })
        ])

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }
    end

    test "chargeback rejects a stale revision", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {_conn, [result]} =
        post_batch(conn, [
          chargeback_op(%{"payment_operation_id" => "pay-1", "expected_revision" => 1})
        ])

      assert %{"status" => "rejected", "code" => "stale_revision"} = result
    end
  end

  defp cancel_op_for(group_id) do
    %{
      "operation_id" => "cancel-#{group_id}",
      "type" => "cancel_group",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id
    }
  end
end
