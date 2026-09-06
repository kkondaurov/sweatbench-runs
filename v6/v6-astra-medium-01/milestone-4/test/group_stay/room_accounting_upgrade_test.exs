defmodule GroupStay.RoomAccountingUpgradeTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias GroupStay.{
    CashAllocation,
    CreditAllocation,
    CreditEntitlement,
    Group,
    Operation,
    Repo,
    Reservations
  }

  test "upgrade preserves balances, allocates senior funding before typed durable funding, and retains settled payment history" do
    database = Path.expand("tmp/room-upgrade-#{System.unique_integer([:positive])}.db")

    {:ok, pid} =
      Repo.start_link(
        name: nil,
        database: database,
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    previous = Repo.put_dynamic_repo(pid)

    try do
      migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
      Ecto.Migrator.run(Repo, migrations, :up, to: 20_260_905_000_002, log: false)

      for {id, status, cash, credit, converted, refund, retained} <- [
            {"active", "active", 250, 150, 0, 0, 0},
            {"converted", "cancelled", 5, 0, 5, 0, 0},
            {"refunded", "cancelled", 10, 0, 0, 10, 0},
            {"retained", "cancelled", 20, 0, 0, 0, 20}
          ] do
        Repo.insert_all("groups", [
          %{
            group_id: id,
            guest_id: "guest",
            property_id: "hotel",
            booked_on: "2027-01-01",
            arrival_on: "2027-06-01",
            departure_on: "2027-06-02",
            rate_plan: "flexible",
            policy_version: "flex-30",
            status: status,
            revision: 9,
            rooms:
              Jason.encode!(
                for room <- ~w(a b c d), do: %{room_id: room, nightly_rate_cents: 500}
              ),
            lodging_total_cents: 2000,
            deposit_due_cents: 400,
            deposit_paid_cents: cash + credit,
            cash_paid_cents: cash,
            credit_paid_cents: credit,
            cash_converted_to_credit_cents: converted,
            refunded_cents: refund,
            retained_cents: retained
          }
        ])
      end

      # Credit allocation ids represent consumption order, deliberately unlike expiry order.
      for {id, source, remaining, expiry} <- [
            {1, "older-credit", 7, "2028-05-02"},
            {2, "later-credit", 8, "2028-05-01"},
            {3, "converted-cancel", 6, "2028-05-01"}
          ] do
        Repo.insert_all("credit_lots", [
          %{
            id: id,
            guest_id: "guest",
            source_operation_id: source,
            remaining_cents: remaining,
            expires_on: expiry
          }
        ])
      end

      for {lot, amount} <- [{1, 50}, {2, 100}] do
        Repo.insert_all("credit_allocations", [
          %{group_id: "active", credit_lot_id: lot, amount_cents: amount}
        ])
      end

      # Payment ids and occurred_on dates both run opposite the durable commit order.
      remember("z-cash", "record_cash_payment", "active", 70, "2027-05-02")
      remember("credit", "apply_hotel_credit", "active", 100, "2027-05-01")
      remember("a-cash", "record_cash_payment", "active", 150, "2027-04-01")
      remember("rejected", "record_cash_payment", "active", 500, "2027-05-01", "rejected")
      remember("converted-pay", "record_cash_payment", "converted", 1, "2027-05-01")
      remember("converted-cancel", "cancel_group", "converted", nil, "2027-05-02")
      remember("refunded-pay", "record_cash_payment", "refunded", 10, "2027-05-01")
      remember("retained-pay", "record_cash_payment", "retained", 20, "2027-05-01")
      records = Repo.all(from o in Operation, order_by: o.id)

      assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [
               20_260_905_000_003
             ]

      assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []
      assert Repo.all(from o in Operation, order_by: o.id) == records
      assert Repo.get!(Group, "active").revision == 9

      assert Reservations.ledger(~D[2027-05-02]) == %{
               cash_held_cents: 250,
               cash_refunded_cents: 10,
               cash_retained_cents: 20,
               cash_converted_to_credit_cents: 5,
               cash_reduced_cents: 0,
               cash_charged_back_cents: 0,
               credit_liability_cents: 171,
               credit_shortfall_cents: 0
             }

      assert Enum.map(
               Reservations.get_group("active").rooms,
               &{&1["cash_paid_cents"], &1["credit_paid_cents"]}
             ) == [{50, 50}, {50, 50}, {50, 50}, {100, 0}]

      cash = Repo.all(from a in CashAllocation, where: a.group_id == "active", order_by: a.id)

      assert Enum.map(cash, &{&1.payment_operation_id, &1.room_id, &1.amount_cents}) == [
               {nil, "a", 30},
               {"z-cash", "a", 20},
               {"z-cash", "b", 50},
               {"a-cash", "c", 50},
               {"a-cash", "d", 100}
             ]

      credit = Repo.all(from a in CreditAllocation, order_by: a.id)

      assert Enum.map(credit, &{&1.operation_id, &1.credit_lot_id, &1.room_id, &1.amount_cents}) ==
               [
                 {nil, 1, "a", 50},
                 {"credit", 2, "b", 50},
                 {"credit", 2, "c", 50}
               ]

      assert [%{amount_cents: 2, payment_operation_id: "converted-pay"}] =
               Repo.all(CreditEntitlement)

      assert {:ok, %{converted_to_credit_cents: 1}} = Reservations.get_payment("converted-pay")
      assert {:ok, %{refunded_cents: 10}} = Reservations.get_payment("refunded-pay")
      assert {:ok, %{retained_cents: 20}} = Reservations.get_payment("retained-pay")

      assert [%{code: "operation_not_found"}] =
               Reservations.batch([
                 op("legacy", "reduce_cash_payment", %{
                   "payment_operation_id" => "legacy-cash",
                   "amount_cents" => 1
                 })
               ])

      assert [%{revision: 10}] =
               Reservations.batch([
                 op("reduce", "reduce_cash_payment", %{
                   "payment_operation_id" => "a-cash",
                   "amount_cents" => 120
                 })
               ])

      assert [%{credit_issued_cents: 55}] =
               Reservations.batch([
                 op("cancel-a", "cancel_rooms", %{
                   "group_id" => "active",
                   "room_ids" => ["a"],
                   "refund_method" => "hotel_credit"
                 })
               ])

      # Legacy cash owns the first 33 cents of the new lot; z-cash owns the next 22.
      assert Repo.get_by!(CreditEntitlement, payment_operation_id: "z-cash").amount_cents == 22

      assert [%{charged_back_cents: 1}] =
               Reservations.batch([
                 op("charge", "charge_back_payment", %{"payment_operation_id" => "converted-pay"})
               ])

      assert Reservations.guest_credit("guest", ~D[2027-05-02]).available_cents == 124
    after
      Repo.put_dynamic_repo(previous)
      Supervisor.stop(pid)
      for path <- [database, database <> "-wal", database <> "-shm"], do: File.rm(path)
    end
  end

  defp op(id, type, attrs),
    do: Map.merge(%{"operation_id" => id, "type" => type, "occurred_on" => "2027-05-02"}, attrs)

  defp remember(id, type, group, amount, occurred, status \\ "applied") do
    result = %{"operation_id" => id, "status" => status, "group_id" => group, "revision" => 9}
    result = if amount, do: Map.put(result, "amount_cents", amount), else: result

    submission = %{
      "operation_id" => id,
      "type" => type,
      "group_id" => group,
      "amount_cents" => amount,
      "occurred_on" => occurred
    }

    Repo.insert!(%Operation{operation_id: id, type: type, submission: submission, result: result})
  end
end
