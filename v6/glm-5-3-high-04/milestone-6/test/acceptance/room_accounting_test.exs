defmodule GroupStayWeb.RoomAccountingTest do
  @moduledoc """
  Acceptance tests for the room-accounting release: room-level lodging and
  deposit amounts, room allocations filled in the rooms' original order,
  bringing pre-durable funding forward as an unattributed senior block, and
  settling selected rooms with `cancel_rooms`.
  """

  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Credit.Application, as: CreditApplication
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  @batch_url "/api/v1/partner-batches"

  defp post_batch(conn, operations) do
    post(conn, @batch_url, %{"operations" => operations})
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp open_group_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-open"),
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-pay"),
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 9_500
      },
      overrides
    )
  end

  defp cancel_rooms_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-cancel-rooms"),
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      },
      overrides
    )
  end

  defp cancel_group_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-cancel"),
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp apply_credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-credit"),
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp apply_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "applied", "expected applied, got: #{inspect(result)}"
    result
  end

  defp reject_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "rejected", "expected rejected, got: #{inspect(result)}"
    result
  end

  defp open_group!(conn, overrides \\ %{}) do
    apply_operation!(conn, open_group_operation(overrides))
  end

  defp fetch_group(conn, group_id) do
    conn = get(conn, "/api/v1/groups/#{group_id}")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp room_view(group, room_id) do
    Enum.find(group["rooms"], &(&1["room_id"] == room_id))
  end

  defp ledger(conn) do
    conn = get(conn, "/api/v1/ledger")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp guest_credit(conn, guest_id) do
    conn = get(conn, "/api/v1/guests/#{guest_id}/credit")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  # Simulates a group funded before durable operation records existed: the
  # group, its rooms, and its funding are inserted directly, with no
  # operation records. Room deposits: 9000 (room-a) and 10500 (room-b).
  defp insert_legacy_group do
    group =
      Repo.insert!(%Group{
        group_id: "group-legacy",
        guest_id: "guest-22",
        property_id: "ams-canal",
        booked_on: ~D[2026-10-01],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-13],
        rate_plan: "flexible",
        policy_version: "flex-14",
        status: "active",
        revision: 1,
        lodging_total_cents: 97_500,
        deposit_due_cents: 19_500
      })

    Enum.zip_with(
      ["room-a", "room-b"],
      [15_000, 17_500],
      fn room_id, nightly_rate_cents ->
        Repo.insert!(%Room{
          room_id: room_id,
          nightly_rate_cents: nightly_rate_cents,
          position: if(room_id == "room-a", do: 0, else: 1),
          group_id: group.id
        })
      end
    )

    group
  end

  defp insert_legacy_lot_and_application!(group, amount_cents) do
    lot =
      Repo.insert!(%Lot{
        guest_id: group.guest_id,
        source_operation_id: "op-cancel-old",
        remaining_cents: 1_500,
        expires_on: ~D[2027-11-27]
      })

    Repo.insert!(%CreditApplication{
      group_id: group.id,
      credit_lot_id: lot.id,
      amount_cents: amount_cents
    })

    lot
  end

  defp fund_legacy_group!(group, cash_cents, credit_cents) do
    unless credit_cents == 0 do
      insert_legacy_lot_and_application!(group, credit_cents)
    end

    Repo.update!(
      Ecto.Changeset.change(group,
        deposit_paid_cents: group.deposit_paid_cents + cash_cents + credit_cents,
        credit_paid_cents: group.credit_paid_cents + credit_cents
      )
    )
  end

  # Simulates a durable payment committed by an earlier release: an operation
  # record with no payment record or room allocations.
  defp insert_durable_payment!(group_id, operation_id, amount_cents, occurred_on) do
    Repo.insert!(%Operation{
      operation_id: operation_id,
      type: "record_cash_payment",
      payload:
        Jason.encode!(%{
          "operation_id" => operation_id,
          "type" => "record_cash_payment",
          "occurred_on" => occurred_on,
          "group_id" => group_id,
          "amount_cents" => amount_cents
        }),
      result:
        Jason.encode!(%{
          "operation_id" => operation_id,
          "status" => "applied",
          "group_id" => group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => 0,
          "revision" => 1
        })
    })
  end

  defp payment_statement(conn, operation_id) do
    conn = get(conn, "/api/v1/payments/#{operation_id}")
    {conn.status, json_response(conn, conn.status)}
  end

  describe "room-level accounting" do
    test "cash fills rooms in their original order, one room at a time", %{conn: conn} do
      open_group!(conn)

      apply_operation!(conn, payment_operation(%{"amount_cents" => 9_500}))

      group = fetch_group(conn, "group-81")

      assert room_view(group, "room-a") == %{
               "room_id" => "room-a",
               "nightly_rate_cents" => 15_000,
               "lodging_total_cents" => 45_000,
               "status" => "active",
               "deposit_due_cents" => 9_000,
               "cash_paid_cents" => 9_000,
               "credit_paid_cents" => 0
             }

      assert room_view(group, "room-b") == %{
               "room_id" => "room-b",
               "nightly_rate_cents" => 17_500,
               "lodging_total_cents" => 52_500,
               "status" => "active",
               "deposit_due_cents" => 10_500,
               "cash_paid_cents" => 500,
               "credit_paid_cents" => 0
             }

      assert group["deposit_paid_cents"] == 9_500
      assert group["outstanding_deposit_cents"] == 10_000
    end

    test "new funding operations allocate in operation-processing order", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-first", "amount_cents" => 4_000})
      )

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-second", "amount_cents" => 4_000})
      )

      group = fetch_group(conn, "group-81")

      assert room_view(group, "room-a")["cash_paid_cents"] == 8_000
      assert room_view(group, "room-b")["cash_paid_cents"] == 0
    end

    test "credit funds room deposits in operation order after cash", %{conn: conn} do
      open_group!(conn)

      # Issue credit to the guest from another refundable group.
      open_group!(conn, %{"group_id" => "group-src"})

      apply_operation!(
        conn,
        payment_operation(%{"group_id" => "group-src", "amount_cents" => 5_000})
      )

      apply_operation!(
        conn,
        cancel_group_operation(%{
          "group_id" => "group-src",
          "operation_id" => "op-cancel-src",
          "refund_method" => "hotel_credit"
        })
      )

      apply_operation!(conn, payment_operation(%{"amount_cents" => 6_000}))

      apply_operation!(
        conn,
        apply_credit_operation(%{"amount_cents" => 4_000, "occurred_on" => "2026-10-05"})
      )

      group = fetch_group(conn, "group-81")

      # The credit fills room-a's remaining deposit before room-b's.
      assert room_view(group, "room-a")["cash_paid_cents"] == 6_000
      assert room_view(group, "room-a")["credit_paid_cents"] == 3_000
      assert room_view(group, "room-b")["credit_paid_cents"] == 1_000

      assert group["cash_paid_cents"] == 6_000
      assert group["credit_paid_cents"] == 4_000
      assert group["deposit_paid_cents"] == 10_000
    end
  end

  describe "bringing pre-durable funding forward" do
    test "room reads expose the unattributed senior block without changing balances", %{
      conn: conn
    } do
      group = insert_legacy_group()
      fund_legacy_group!(group, 3_000, 4_000)

      before_ledger = ledger(conn)

      group = fetch_group(conn, "group-legacy")

      # Aggregate cash funds room-a first, then the legacy credit lots in
      # original consumption order.
      assert room_view(group, "room-a")["cash_paid_cents"] == 3_000
      assert room_view(group, "room-a")["credit_paid_cents"] == 4_000
      assert room_view(group, "room-b")["cash_paid_cents"] == 0
      assert room_view(group, "room-b")["credit_paid_cents"] == 0

      assert group["deposit_paid_cents"] == 7_000
      assert ledger(conn) == before_ledger
    end

    test "new funding allocates after the unattributed senior block", %{conn: conn} do
      group = insert_legacy_group()
      fund_legacy_group!(group, 3_000, 4_000)

      result =
        apply_operation!(
          conn,
          payment_operation(%{"group_id" => "group-legacy", "amount_cents" => 4_000})
        )

      assert result["revision"] == 2
      assert result["outstanding_deposit_cents"] == 19_500 - 7_000 - 4_000

      group = fetch_group(conn, "group-legacy")

      # The new payment tops up room-a's remaining deposit before room-b's.
      assert room_view(group, "room-a")["cash_paid_cents"] == 5_000
      assert room_view(group, "room-a")["credit_paid_cents"] == 4_000
      assert room_view(group, "room-b")["cash_paid_cents"] == 2_000

      # The legacy balances are untouched; the ledger moved by the payment.
      # Held cash is the aggregate cash: 3000 legacy plus the 4000 payment.
      assert ledger(conn)["cash_held_cents"] == 7_000
      assert ledger(conn)["credit_liability_cents"] == 5_500
    end

    test "legacy funding cannot be targeted by payment operations", %{conn: conn} do
      group = insert_legacy_group()
      fund_legacy_group!(group, 3_000, 0)

      reduce = %{
        "operation_id" => "op-reduce-legacy",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-10",
        "payment_operation_id" => "op-pay-legacy",
        "amount_cents" => 1_000
      }

      assert reject_operation!(conn, reduce)["code"] == "operation_not_found"

      charge_back = %{
        "operation_id" => "op-charge-legacy",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-10",
        "payment_operation_id" => "op-pay-legacy"
      }

      assert reject_operation!(conn, charge_back)["code"] == "operation_not_found"

      {status, body} = payment_statement(conn, "op-pay-legacy")
      assert status == 404
      assert body == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "a cancelling legacy-funded group settles its aggregate cash and credit", %{conn: conn} do
      group = insert_legacy_group()
      fund_legacy_group!(group, 3_000, 4_000)

      result =
        apply_operation!(
          conn,
          cancel_group_operation(%{"group_id" => "group-legacy"})
        )

      assert result["refunded_cents"] == 3_000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0
      assert result["revision"] == 2

      # The applied legacy credit returned to its original lot.
      assert guest_credit(conn, "guest-22")["available_cents"] == 5_500

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_refunded_cents"] == 3_000
    end
  end

  describe "funding represented by durable operation records" do
    setup do
      group = insert_legacy_group()
      fund_legacy_group!(group, 3_000, 0)

      # Committed in this order regardless of occurred_on. The group's
      # aggregate reflects both the legacy cash and these payments.
      insert_durable_payment!("group-legacy", "op-pay-commit-1", 7_000, "2026-10-20")
      insert_durable_payment!("group-legacy", "op-pay-commit-2", 5_000, "2026-10-05")

      Repo.update!(Ecto.Changeset.change(group, deposit_paid_cents: 15_000))

      :ok
    end

    test "allocates in durable-record commit order, regardless of occurred_on", %{conn: conn} do
      reduce = %{
        "operation_id" => "op-reduce-commit-2",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-21",
        "payment_operation_id" => "op-pay-commit-2",
        "amount_cents" => 3_000
      }

      result = apply_operation!(conn, reduce)
      assert result["status"] == "applied"

      # Commit order funds room-a with the legacy cash, then op-pay-commit-1
      # (committed first), then op-pay-commit-2; so op-pay-commit-2's cash
      # sits on room-b. Reducing it reopens room-b's deposit.
      group = fetch_group(conn, "group-legacy")

      assert room_view(group, "room-a")["cash_paid_cents"] == 9_000
      assert room_view(group, "room-b")["cash_paid_cents"] == 3_000

      assert group["deposit_paid_cents"] == 12_000
      assert group["outstanding_deposit_cents"] == 7_500
    end

    test "reads a payment statement before any room accounting exists", %{conn: conn} do
      # Reading the statement neither brings funding forward nor changes any
      # balance.
      before_ledger = ledger(conn)

      {status, %{"data" => statement}} = payment_statement(conn, "op-pay-commit-1")

      assert status == 200
      assert statement["recorded_cents"] == 7_000
      assert statement["held_cents"] == 7_000

      assert ledger(conn) == before_ledger

      group = fetch_group(conn, "group-legacy")

      assert room_view(group, "room-a")["cash_paid_cents"] == 9_000
      assert room_view(group, "room-b")["cash_paid_cents"] == 6_000

      assert group["deposit_paid_cents"] == 15_000
      assert group["outstanding_deposit_cents"] == 4_500
    end

    test "the unattributed senior block allocates before durable-record funding", %{
      conn: conn
    } do
      # Cancelling room-b settles only the cash allocated to it: under the
      # senior-block-first order that is 1000 from op-pay-commit-1 and all
      # 5000 from op-pay-commit-2.
      apply_operation!(
        conn,
        cancel_rooms_operation(%{
          "group_id" => "group-legacy",
          "room_ids" => ["room-b"]
        })
      )

      {status, %{"data" => first}} = payment_statement(conn, "op-pay-commit-1")
      {_, %{"data" => second}} = payment_statement(conn, "op-pay-commit-2")

      assert status == 200
      assert first["held_cents"] == 6_000
      assert first["refunded_cents"] == 1_000
      assert second["held_cents"] == 0
      assert second["refunded_cents"] == 5_000
    end
  end

  describe "settling selected rooms" do
    test "settles selected rooms refundably and leaves other rooms unchanged", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation(%{"amount_cents" => 9_500}))

      op = cancel_rooms_operation(%{"room_ids" => ["room-a"]})
      result = apply_operation!(conn, op)

      assert result == %{
               "operation_id" => op["operation_id"],
               "status" => "applied",
               "group_id" => "group-81",
               "cancelled_room_ids" => ["room-a"],
               "refunded_cents" => 9_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      group = fetch_group(conn, "group-81")

      # Unpaid deposit for the cancelled room is no longer due; the group's
      # totals describe active rooms only.
      assert group["status"] == "active"
      assert group["lodging_total_cents"] == 52_500
      assert group["deposit_due_cents"] == 10_500
      assert group["deposit_paid_cents"] == 500
      assert group["outstanding_deposit_cents"] == 10_000

      assert room_view(group, "room-a")["status"] == "cancelled"
      assert room_view(group, "room-a")["cash_paid_cents"] == 0
      assert room_view(group, "room-b")["status"] == "active"
      assert room_view(group, "room-b")["cash_paid_cents"] == 500

      assert ledger(conn)["cash_held_cents"] == 500
      assert ledger(conn)["cash_refunded_cents"] == 9_000
    end

    test "returns cancelled_room_ids in the group's original room order", %{conn: conn} do
      open_group!(conn)

      result =
        apply_operation!(
          conn,
          cancel_rooms_operation(%{"room_ids" => ["room-b", "room-a"]})
        )

      assert result["cancelled_room_ids"] == ["room-a", "room-b"]
    end

    test "the group becomes cancelled when no active rooms remain", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation(%{"amount_cents" => 9_500}))

      apply_operation!(conn, cancel_rooms_operation(%{"room_ids" => ["room-a"]}))

      result =
        apply_operation!(
          conn,
          cancel_rooms_operation(%{"room_ids" => ["room-b"], "occurred_on" => "2026-11-27"})
        )

      # Non-refundable now: room-b's 500 cash is retained.
      assert result["retained_cents"] == 500
      assert result["revision"] == 4

      group = fetch_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 0

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_refunded_cents"] == 9_000
      assert ledger(conn)["cash_retained_cents"] == 500
    end

    test "retains cash on a non-refundable settlement", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation(%{"amount_cents" => 9_500}))

      result =
        apply_operation!(
          conn,
          cancel_rooms_operation(%{"occurred_on" => "2026-11-27"})
        )

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 9_000

      assert ledger(conn)["cash_retained_cents"] == 9_000
      assert fetch_group(conn, "group-81")["status"] == "active"
    end

    test "computes the hotel-credit bonus once on the combined cash", %{conn: conn} do
      open_group!(conn, %{
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      })

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-a", "amount_cents" => 9_000})
      )

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-b", "amount_cents" => 5_000})
      )

      result =
        apply_operation!(
          conn,
          cancel_rooms_operation(%{
            "room_ids" => ["room-a", "room-b"],
            "refund_method" => "hotel_credit"
          })
        )

      # 14000 * 1.1 = 15400, computed once across both rooms.
      assert result["credit_issued_cents"] == 15_400
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      assert guest_credit(conn, "guest-22")["available_cents"] == 15_400

      assert ledger(conn)["cash_converted_to_credit_cents"] == 14_000
      assert ledger(conn)["credit_liability_cents"] == 15_400
    end

    test "restores the selected rooms' applied credit on a refundable settlement", %{
      conn: conn
    } do
      open_group!(conn, %{"group_id" => "group-src"})

      apply_operation!(
        conn,
        payment_operation(%{"group_id" => "group-src", "amount_cents" => 5_000})
      )

      apply_operation!(
        conn,
        cancel_group_operation(%{
          "group_id" => "group-src",
          "operation_id" => "op-cancel-src",
          "refund_method" => "hotel_credit"
        })
      )

      open_group!(conn)
      apply_operation!(conn, payment_operation(%{"amount_cents" => 2_000}))

      apply_operation!(
        conn,
        apply_credit_operation(%{"amount_cents" => 3_000, "occurred_on" => "2026-12-01"})
      )

      # room-a holds 9000 of deposit: 2000 cash and 3000 credit... the credit
      # fills room-a's remaining deposit after the cash.
      result = apply_operation!(conn, cancel_rooms_operation(%{"room_ids" => ["room-a"]}))

      assert result["refunded_cents"] == 2_000

      # The room's applied credit returned to its original lot.
      assert guest_credit(conn, "guest-22")["available_cents"] == 5_500

      group = fetch_group(conn, "group-81")
      assert room_view(group, "room-b")["credit_paid_cents"] == 0

      assert ledger(conn)["credit_liability_cents"] == 5_500
    end

    test "consumes the selected rooms' applied credit on a non-refundable settlement",
         %{conn: conn} do
      open_group!(conn, %{"group_id" => "group-src"})

      apply_operation!(
        conn,
        payment_operation(%{"group_id" => "group-src", "amount_cents" => 5_000})
      )

      apply_operation!(
        conn,
        cancel_group_operation(%{
          "group_id" => "group-src",
          "operation_id" => "op-cancel-src",
          "refund_method" => "hotel_credit"
        })
      )

      open_group!(conn)
      apply_operation!(conn, payment_operation(%{"amount_cents" => 2_000}))
      apply_operation!(conn, apply_credit_operation(%{"amount_cents" => 3_000}))

      result =
        apply_operation!(
          conn,
          cancel_rooms_operation(%{"occurred_on" => "2026-11-27", "room_ids" => ["room-a"]})
        )

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 2_000

      # Non-refundable settlement consumed the room's credit.
      assert guest_credit(conn, "guest-22")["available_cents"] == 2_500
      assert ledger(conn)["credit_liability_cents"] == 2_500
    end

    test "rejects hotel credit for a non-refundable settlement", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation(%{"amount_cents" => 9_500}))

      result =
        reject_operation!(
          conn,
          cancel_rooms_operation(%{
            "occurred_on" => "2026-11-27",
            "refund_method" => "hotel_credit"
          })
        )

      assert result["code"] == "refund_method_not_available"

      group = fetch_group(conn, "group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2
      assert ledger(conn)["cash_held_cents"] == 9_500
    end

    test "rejects room selections that are not distinct active rooms", %{conn: conn} do
      open_group!(conn)

      open_group!(conn, %{
        "group_id" => "group-82",
        "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 15_000}]
      })

      apply_operation!(conn, cancel_rooms_operation(%{"room_ids" => ["room-a"]}))

      for room_ids <-
            [
              ["room-missing"],
              ["room-a"],
              ["room-a", "room-a"],
              ["room-a", "room-b", "room-missing"],
              ["room-c"],
              [],
              nil,
              "room-a",
              [1],
              ["room-a", 2]
            ] do
        result =
          reject_operation!(
            conn,
            cancel_rooms_operation(%{"room_ids" => room_ids})
          )

        assert result["code"] == "invalid_rooms", "for #{inspect(room_ids)}"
      end

      group = fetch_group(conn, "group-81")
      assert group["revision"] == 2
      assert group["status"] == "active"
      assert room_view(group, "room-b")["status"] == "active"
    end

    test "cancel_group settles only the remaining active rooms", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation(%{"amount_cents" => 9_500}))

      apply_operation!(conn, cancel_rooms_operation(%{"room_ids" => ["room-a"]}))

      result =
        apply_operation!(
          conn,
          cancel_group_operation(%{"occurred_on" => "2026-11-27"})
        )

      # Room-b's 500 is settled non-refundably; room-a is settled history.
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 500
      assert result["credit_issued_cents"] == 0
      assert result["revision"] == 4

      group = fetch_group(conn, "group-81")
      assert group["status"] == "cancelled"
      assert group["deposit_paid_cents"] == 0

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_refunded_cents"] == 9_000
      assert ledger(conn)["cash_retained_cents"] == 500
    end

    test "rejects a missing group and a stale revision", %{conn: conn} do
      open_group!(conn)

      result =
        reject_operation!(
          conn,
          cancel_rooms_operation(%{"group_id" => "group-missing"})
        )

      assert result["code"] == "group_not_found"

      apply_operation!(conn, payment_operation(%{"amount_cents" => 1_000}))

      result =
        reject_operation!(
          conn,
          cancel_rooms_operation(%{"expected_revision" => 1})
        )

      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 2

      assert fetch_group(conn, "group-81")["revision"] == 2
    end

    test "is durably idempotent", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation(%{"amount_cents" => 9_500}))

      op = cancel_rooms_operation(%{"operation_id" => "op-cancel-rooms-1"})
      original = apply_operation!(conn, op)

      conn
      |> post_batch([op])
      |> json_response(200)
      |> then(fn %{"results" => [retried]} -> assert retried == original end)

      group = fetch_group(conn, "group-81")
      assert group["revision"] == 3
      assert group["deposit_paid_cents"] == 500
    end
  end
end
