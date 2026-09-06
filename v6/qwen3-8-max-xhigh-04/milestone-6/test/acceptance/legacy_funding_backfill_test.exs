defmodule GroupStayWeb.Acceptance.LegacyFundingBackfillTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Credit.Lot
  alias GroupStay.Funding
  alias GroupStay.Funding.Allocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  import Ecto.Query

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  # Inserts a group funded before durable operation records existed: it has
  # paid deposit but no operation records and no room allocations.
  defp insert_legacy_group(attrs) do
    Repo.insert!(
      struct!(Group, %{
        guest_id: "guest-22",
        property_id: "ams-canal",
        status: "active",
        revision: 1,
        policy_version: "flex-14",
        credit_paid_cents: 0,
        rooms: [%Room{room_id: "room-a", nightly_rate_cents: 10000}]
      })
      |> Map.merge(attrs)
    )
  end

  defp group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn
    |> get("/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp allocations_for(group_id) do
    group = Repo.get_by!(Group, group_id: group_id)

    Repo.all(
      from a in Allocation,
        where: a.group_id == ^group.id,
        order_by: [asc: a.fill_sequence]
    )
  end

  describe "carrying legacy funding forward" do
    test "legacy cash becomes one unattributed senior block" do
      insert_legacy_group(%{
        group_id: "legacy-1",
        rate_plan: "flexible",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-12],
        lodging_total_cents: 20000,
        deposit_due_cents: 4000,
        deposit_paid_cents: 3000
      })

      Funding.backfill_room_accounting()

      [allocation] = allocations_for("legacy-1")
      assert allocation.kind == "cash"
      assert allocation.payment_operation_id == nil
      assert allocation.amount_cents == 3000
      assert allocation.disposition == "held"
    end

    test "does not change aggregate cash, credit, or liability balances" do
      insert_legacy_group(%{
        group_id: "legacy-1",
        rate_plan: "flexible",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-12],
        lodging_total_cents: 20000,
        deposit_due_cents: 4000,
        deposit_paid_cents: 3000
      })

      Funding.backfill_room_accounting()

      # The created allocations exactly match the group's recorded funding, so
      # the allocation-based ledger reports the same balances the group columns
      # always described: nothing is created or destroyed.
      assert Enum.reduce(allocations_for("legacy-1"), 0, &(&1.amount_cents + &2)) == 3000
      assert Enum.all?(allocations_for("legacy-1"), &(&1.disposition == "held"))

      assert ledger(build_conn())["cash_held_cents"] == 3000

      group = group(build_conn(), "legacy-1")
      assert group["deposit_paid_cents"] == 3000
      assert group["outstanding_deposit_cents"] == 1000
    end

    test "legacy rooms receive their accounting fields" do
      insert_legacy_group(%{
        group_id: "legacy-1",
        rate_plan: "flexible",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-12],
        lodging_total_cents: 20000,
        deposit_due_cents: 4000,
        deposit_paid_cents: 3000
      })

      Funding.backfill_room_accounting()

      [room] = group(build_conn(), "legacy-1")["rooms"]
      assert room["status"] == "active"
      assert room["deposit_due_cents"] == 4000
      assert room["cash_paid_cents"] == 3000
      assert room["credit_paid_cents"] == 0
    end

    test "legacy funding cannot be targeted by a reduction" do
      insert_legacy_group(%{
        group_id: "legacy-1",
        rate_plan: "flexible",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-12],
        lodging_total_cents: 20000,
        deposit_due_cents: 4000,
        deposit_paid_cents: 3000
      })

      Funding.backfill_room_accounting()

      # Legacy funding has no durable operation identity.
      assert [
               %{
                 "status" => "rejected",
                 "code" => "operation_not_found"
               }
             ] =
               submit(build_conn(), [
                 %{
                   "operation_id" => "reduce-1",
                   "type" => "reduce_cash_payment",
                   "occurred_on" => "2026-10-05",
                   "payment_operation_id" => "legacy-payment",
                   "amount_cents" => 1000
                 }
               ])

      assert ledger(build_conn())["cash_held_cents"] == 3000
    end

    test "the senior block is allocated before later durable funding" do
      insert_legacy_group(%{
        group_id: "legacy-1",
        rate_plan: "flexible",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-12],
        lodging_total_cents: 20000,
        deposit_due_cents: 4000,
        deposit_paid_cents: 2000
      })

      Funding.backfill_room_accounting()

      # A durable payment continues filling the same room after the legacy
      # block.
      submit(build_conn(), [
        %{
          "operation_id" => "pay-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "legacy-1",
          "amount_cents" => 1500
        }
      ])

      [legacy, durable] = allocations_for("legacy-1")
      assert legacy.payment_operation_id == nil
      assert legacy.fill_sequence < durable.fill_sequence
      assert durable.payment_operation_id == "pay-1"

      # Reducing the durable payment removes its own held cash in reverse fill
      # order and leaves the senior block untouched.
      assert [%{"status" => "applied"}] =
               submit(build_conn(), [
                 %{
                   "operation_id" => "reduce-1",
                   "type" => "reduce_cash_payment",
                   "occurred_on" => "2026-10-05",
                   "payment_operation_id" => "pay-1",
                   "amount_cents" => 1000
                 }
               ])

      assert ledger(build_conn())["cash_held_cents"] == 2500
      assert ledger(build_conn())["cash_reduced_cents"] == 1000

      legacy_after =
        Enum.find(allocations_for("legacy-1"), &(&1.payment_operation_id == nil))

      assert legacy_after.amount_cents == 2000
      assert legacy_after.disposition == "held"
    end

    test "is idempotent for groups that already have allocations" do
      insert_legacy_group(%{
        group_id: "legacy-1",
        rate_plan: "flexible",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-12],
        lodging_total_cents: 20000,
        deposit_due_cents: 4000,
        deposit_paid_cents: 3000
      })

      Funding.backfill_room_accounting()
      Funding.backfill_room_accounting()

      assert length(allocations_for("legacy-1")) == 1
      assert ledger(build_conn())["cash_held_cents"] == 3000
    end

    test "separates the senior block from durable funding recorded in commit order" do
      # The group was funded partly before durable records (1000) and partly by
      # two durable cash payments (1200 and 800) committed in this order.
      insert_legacy_group(%{
        group_id: "legacy-mixed",
        rate_plan: "flexible",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-12],
        lodging_total_cents: 20000,
        deposit_due_cents: 4000,
        deposit_paid_cents: 3000
      })

      for {op_id, amount} <- [{"old-pay-1", 1200}, {"old-pay-2", 800}] do
        Repo.insert!(%Record{
          operation_id: op_id,
          type: "record_cash_payment",
          payload: Jason.encode!(%{"group_id" => "legacy-mixed", "amount_cents" => amount}),
          result:
            Jason.encode!(%{
              "status" => "applied",
              "operation_id" => op_id,
              "group_id" => "legacy-mixed",
              "amount_cents" => amount
            })
        })
      end

      Funding.backfill_room_accounting()

      allocations = allocations_for("legacy-mixed")
      assert Enum.reduce(allocations, 0, &(&1.amount_cents + &2)) == 3000

      # The unattributed senior block (1000) is allocated first, then the two
      # durable payments in commit order.
      assert Enum.map(allocations, & &1.payment_operation_id) ==
               [nil, "old-pay-1", "old-pay-2"]

      assert Enum.map(allocations, & &1.amount_cents) == [1000, 1200, 800]

      # The durable payments remain reducible through their recorded identity.
      assert [%{"status" => "applied", "amount_cents" => 500}] =
               submit(build_conn(), [
                 %{
                   "operation_id" => "reduce-old",
                   "type" => "reduce_cash_payment",
                   "occurred_on" => "2026-10-05",
                   "payment_operation_id" => "old-pay-2",
                   "amount_cents" => 500
                 }
               ])

      assert ledger(build_conn())["cash_held_cents"] == 2500
      assert ledger(build_conn())["cash_reduced_cents"] == 500
    end
  end

  describe "global sequences" do
    test "backfilled allocations receive increasing global sequences in fill order" do
      insert_legacy_group(%{
        group_id: "legacy-1",
        rate_plan: "flexible",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-12],
        lodging_total_cents: 20000,
        deposit_due_cents: 4000,
        deposit_paid_cents: 3000
      })

      Funding.backfill_room_accounting()

      allocations = allocations_for("legacy-1")
      assert Enum.all?(allocations, &(&1.global_sequence > 0))

      assert allocations == Enum.sort_by(allocations, & &1.global_sequence)
    end

    test "pre-release allocations are sequenced in fill order by the migration backfill" do
      legacy =
        insert_legacy_group(%{
          group_id: "legacy-1",
          rate_plan: "flexible",
          booked_on: ~D[2026-10-03],
          arrival_on: ~D[2026-12-10],
          departure_on: ~D[2026-12-12],
          lodging_total_cents: 20000,
          deposit_due_cents: 4000,
          deposit_paid_cents: 3000
        })

      # Rows created before deposit transfers existed have no global sequence.
      for {room_id, amount, fill_sequence} <- [{"room-a", 2000, 1}, {"room-a", 1000, 2}] do
        Repo.insert!(%Allocation{
          group_id: legacy.id,
          room_id: room_id,
          kind: "cash",
          amount_cents: amount,
          disposition: "held",
          fill_sequence: fill_sequence
        })
      end

      Funding.backfill_global_sequences()

      allocations = allocations_for("legacy-1")
      assert Enum.all?(allocations, &(&1.global_sequence > 0))
      assert allocations == Enum.sort_by(allocations, & &1.global_sequence)

      # Sequencing again changes nothing.
      before = Enum.map(allocations, &{&1.id, &1.global_sequence})
      Funding.backfill_global_sequences()
      after_ = Enum.map(allocations_for("legacy-1"), &{&1.id, &1.global_sequence})
      assert after_ == before
    end
  end

  describe "legacy credit" do
    test "legacy credit is carried forward with its lot and preserves liability" do
      lot =
        Repo.insert!(%Lot{
          guest_id: "guest-22",
          source_operation_id: "cancel-old",
          initial_cents: 2000,
          remaining_cents: 1000,
          expires_on: ~D[2027-06-01]
        })

      legacy =
        insert_legacy_group(%{
          group_id: "legacy-credit",
          rate_plan: "flexible",
          booked_on: ~D[2026-10-03],
          arrival_on: ~D[2026-12-10],
          departure_on: ~D[2026-12-12],
          lodging_total_cents: 20000,
          deposit_due_cents: 4000,
          deposit_paid_cents: 3000,
          credit_paid_cents: 1000
        })

      Repo.insert!(%GroupStay.Credit.Application{
        group_id: legacy.id,
        credit_lot_id: lot.id,
        amount_cents: 1000
      })

      ledger_before = ledger(build_conn())

      Funding.backfill_room_accounting()

      # The allocation-based ledger reports the same balances the group columns
      # described before the release: held cash plus the applied credit lot.
      assert ledger(build_conn())["cash_held_cents"] == 2000
      assert ledger(build_conn())["credit_liability_cents"] == 2000
      assert ledger(build_conn())["credit_shortfall_cents"] == 0
      # No cash dispositions are lost or invented.
      assert ledger(build_conn())["cash_refunded_cents"] == ledger_before["cash_refunded_cents"]

      allocations = allocations_for("legacy-credit")
      cash = Enum.filter(allocations, &(&1.kind == "cash"))
      credit = Enum.filter(allocations, &(&1.kind == "credit"))

      assert Enum.reduce(cash, 0, &(&1.amount_cents + &2)) == 2000
      assert Enum.all?(cash, &(&1.payment_operation_id == nil))

      assert [%Allocation{credit_lot_id: lot_id, amount_cents: 1000}] = credit
      assert lot_id == lot.id
    end
  end
end
