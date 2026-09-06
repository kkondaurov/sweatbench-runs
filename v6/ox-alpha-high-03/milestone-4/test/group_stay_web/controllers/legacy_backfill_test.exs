defmodule GroupStayWeb.LegacyBackfillTest do
  @moduledoc """
  Verifies that funding recorded before durable operation records existed is
  brought forward as one unattributed senior block per active group, ahead of
  durably represented funding, without changing any aggregate balance.
  """

  use GroupStayWeb.ConnCase, async: true

  @moduletag :capture_log

  alias GroupStay.Finance.Backfill
  alias GroupStay.Finance.CashMovement
  alias GroupStay.Finance.CreditLot
  alias GroupStay.Finance.RoomAllocation
  alias GroupStay.Operations.OperationRecord
  alias GroupStay.Repo

  import Ecto.Query

  describe "legacy cash funding" do
    test "is brought forward as an unattributed senior block" do
      open_default_group("group-legacy")

      run_and_get_results([
        pay_operation("group-legacy", 9_500, %{"operation_id" => "op-pay-legacy"})
      ])

      make_payment_legacy("op-pay-legacy")
      ledger_before = fetch_ledger()

      Backfill.backfill()

      assert fetch_ledger() == ledger_before

      [a, b] = fetch_group("group-legacy")["rooms"]
      assert a["cash_paid_cents"] == 9_000
      assert b["cash_paid_cents"] == 500

      # Legacy funding has no durable identity, so it cannot be targeted.
      results =
        run_and_get_results([
          reduce_cash_operation("op-pay-legacy", 1, %{"operation_id" => "op-reduce-legacy"})
        ])

      assert hd(results)["code"] == "operation_not_found"
    end

    test "new durable funding allocates after the senior block" do
      open_default_group("group-legacy-new")

      run_and_get_results([
        pay_operation("group-legacy-new", 9_500, %{"operation_id" => "op-old"})
      ])

      make_payment_legacy("op-old")
      Backfill.backfill()

      run_and_get_results([
        pay_operation("group-legacy-new", 10_000, %{"operation_id" => "op-new"})
      ])

      [_a, b] = fetch_group("group-legacy-new")["rooms"]
      assert b["cash_paid_cents"] == 10_500

      assert fetch_payment("op-new")["held_cents"] == 10_000
      assert fetch_payment("op-new")["original_group_id"] == "group-legacy-new"
    end

    test "mixed legacy and durable payments keep their distinct identities" do
      open_default_group("group-mixed")

      run_and_get_results([
        pay_operation("group-mixed", 4_000, %{"operation_id" => "op-p1"}),
        pay_operation("group-mixed", 5_500, %{"operation_id" => "op-p2"})
      ])

      make_payment_legacy("op-p1")
      Backfill.backfill()

      # Legacy 4_000 plus the first 5_000 of op-p2 fill room-a; the rest of
      # op-p2 sits on room-b.
      [a, b] = fetch_group("group-mixed")["rooms"]
      assert a["cash_paid_cents"] == 9_000
      assert b["cash_paid_cents"] == 500

      assert fetch_payment("op-p2")["held_cents"] == 5_500

      # A reduction removes op-p2's allocations in reverse fill order: first
      # room-b's slice, leaving room-a's funding untouched.
      run_and_get_results([reduce_cash_operation("op-p2", 500, %{"operation_id" => "op-red"})])

      [a, b] = fetch_group("group-mixed")["rooms"]
      assert a["cash_paid_cents"] == 9_000
      assert b["cash_paid_cents"] == 0

      assert fetch_payment("op-p2")["reduced_cents"] == 500
    end
  end

  describe "legacy hotel credit" do
    test "allocates as part of the senior block before durable funding" do
      fund_guest_credit()
      open_default_group("group-legacy-credit")

      run_and_get_results([
        credit_operation("group-legacy-credit", 8_000, %{
          "occurred_on" => "2026-12-01",
          "operation_id" => "op-credit-legacy"
        })
      ])

      ledger_before = fetch_ledger()

      make_credit_legacy("op-credit-legacy", "group-legacy-credit", 8_000)

      Backfill.backfill()

      assert fetch_ledger() == ledger_before

      # The legacy credit fills room-a first, ahead of later durable funding.
      run_and_get_results([
        pay_operation("group-legacy-credit", 4_000, %{"operation_id" => "op-after-credit"})
      ])

      [a, b] = fetch_group("group-legacy-credit")["rooms"]
      assert a["credit_paid_cents"] == 8_000
      assert a["cash_paid_cents"] == 1_000
      assert b["cash_paid_cents"] == 3_000
    end
  end

  # Reverts one recorded payment to its pre-durable-records shape: no operation
  # record, an unidentified cash movement, and no room allocations.
  defp make_payment_legacy(operation_id) do
    group_id = group_pk_by_payment(operation_id)

    Repo.update_all(
      from(m in CashMovement, where: m.operation_id == ^operation_id),
      set: [operation_id: nil]
    )

    Repo.delete_all(from(r in OperationRecord, where: r.operation_id == ^operation_id))
    Repo.delete_all(from(a in RoomAllocation, where: a.group_id == ^group_id))

    :ok
  end

  # Reverts one credit application to its pre-durable-records shape by moving
  # the applied amount into the historical credit_applications table.
  defp make_credit_legacy(operation_id, group_string_id, amount_cents) do
    group = Repo.one!(from(g in "groups", where: g.group_id == ^group_string_id, select: g.id))
    lot = Repo.one!(from(l in CreditLot, order_by: [asc: l.inserted_at], limit: 1))

    Repo.query!(
      "CREATE TABLE IF NOT EXISTS credit_applications (id TEXT PRIMARY KEY, group_id TEXT, credit_lot_id TEXT, amount_cents INTEGER)",
      []
    )

    Repo.delete_all(from(a in RoomAllocation, where: a.group_id == ^group))
    Repo.delete_all(from(r in OperationRecord, where: r.operation_id == ^operation_id))

    {:ok, _} =
      Repo.query(
        "INSERT INTO credit_applications (id, group_id, credit_lot_id, amount_cents) VALUES (?, ?, ?, ?)",
        [Ecto.UUID.generate(), group, lot.id, amount_cents]
      )

    :ok
  end

  defp group_pk_by_payment(operation_id) do
    movement =
      Repo.one!(from(m in CashMovement, where: m.operation_id == ^operation_id, limit: 1))

    movement.group_id
  end

  defp fund_guest_credit do
    post_operations([
      open_operation(%{
        "operation_id" => "op-open-source",
        "group_id" => "group-credit-source",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-04",
        "rooms" => [%{"room_id" => "room-source", "nightly_rate_cents" => 20_000}]
      }),
      pay_operation("group-credit-source", 12_000, %{"operation_id" => "op-pay-source"}),
      cancel_operation("group-credit-source", %{
        "occurred_on" => "2026-11-01",
        "refund_method" => "hotel_credit",
        "operation_id" => "cancel-source"
      })
    ])

    :ok
  end

  defp run_and_get_results(operations) do
    post_operations(operations) |> json_response(200) |> Map.fetch!("results")
  end
end
