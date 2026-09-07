defmodule GroupStay.DepositTransferMigrationTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.{CashAllocation, CreditAllocation}
  @moduletag :capture_log

  test "upgrade preserves mixed creation order after legacy funding, reductions and room settlement" do
    token = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    database = Path.expand("_build/transfer-migration-#{token}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix) end)

    repo =
      start_supervised!(
        {Repo, name: nil, database: database, pool_size: 1, pool: DBConnection.ConnectionPool}
      )

    previous = Repo.put_dynamic_repo(repo)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)

    for legacy <- [false, true], settled <- [false, true] do
      suffix = "#{legacy}-#{settled}"
      source = "source-" <> suffix
      group = "g-" <> suffix
      apply!("open_group", "open-" <> source, opening(source))
      apply!("record_cash_payment", "seed-" <> suffix, %{group_id: source, amount_cents: 500})

      apply!("cancel_group", "issue-" <> suffix, %{
        group_id: source,
        refund_method: "hotel_credit"
      })

      apply!("open_group", "open-" <> group, opening(group))
      apply!("record_cash_payment", "senior-" <> suffix, %{group_id: group, amount_cents: 40})

      apply!("apply_hotel_credit", "senior-credit-" <> suffix, %{
        group_id: group,
        amount_cents: 90
      })

      if legacy do
        Repo.query!(
          "UPDATE cash_allocations SET payment_operation_id = NULL WHERE payment_operation_id = ?",
          ["senior-" <> suffix]
        )

        Repo.query!("DELETE FROM operations WHERE operation_id IN (?, ?, ?)", [
          "open-" <> group,
          "senior-" <> suffix,
          "senior-credit-" <> suffix
        ])
      end

      apply!("record_cash_payment", "p-" <> suffix, %{group_id: group, amount_cents: 100})
      apply!("apply_hotel_credit", "credit-" <> suffix, %{group_id: group, amount_cents: 70})

      apply!("reduce_cash_payment", "reduce-" <> suffix, %{
        payment_operation_id: "p-" <> suffix,
        amount_cents: 80
      })

      apply!("apply_hotel_credit", "refill-" <> suffix, %{group_id: group, amount_cents: 50})
      apply!("record_cash_payment", "last-" <> suffix, %{group_id: group, amount_cents: 30})

      if settled,
        do: apply!("cancel_rooms", "cancel-" <> suffix, %{group_id: group, room_ids: ["a"]})
    end

    order = allocation_order()
    ledger = Reservations.ledger(~D[2027-01-01])
    audit = Repo.query!("SELECT * FROM operations ORDER BY id").rows
    groups = Repo.query!("SELECT * FROM groups ORDER BY group_id").rows
    Ecto.Migrator.run(Repo, migrations, :down, to: 20_260_907_000_004, log: false)
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    assert allocation_order() == order
    assert Reservations.ledger(~D[2027-01-01]) == ledger
    assert Repo.query!("SELECT * FROM operations ORDER BY id").rows == audit
    assert Repo.query!("SELECT * FROM groups ORDER BY group_id").rows == groups

    apply!("open_group", "open-destination", opening("destination"))

    apply!("transfer_deposit", "transfer-legacy", %{
      source_group_id: "g-true-false",
      destination_group_id: "destination",
      amount_cents: 300
    })

    assert Repo.one(
             from a in CashAllocation,
               where: a.group_id == "destination" and is_nil(a.payment_operation_id),
               select: sum(a.amount_cents)
           ) == 40

    assert Reservations.ledger(~D[2027-01-01]) == ledger
  end

  defp allocation_order do
    cash = Repo.all(from a in CashAllocation, where: a.disposition == "held")
    credit = Repo.all(CreditAllocation)

    (cash ++ credit)
    |> Enum.group_by(& &1.group_id)
    |> Map.new(fn {group, allocations} ->
      {group,
       allocations
       |> Enum.sort_by(& &1.allocation_order)
       |> Enum.map(&{&1.__struct__, &1.id, &1.amount_cents})}
    end)
  end

  defp opening(group) do
    %{
      group_id: group,
      guest_id: group,
      property_id: "hotel",
      arrival_on: "2027-06-01",
      departure_on: "2027-06-02",
      rate_plan: "flexible",
      rooms: for(id <- ~w(a b c d e), do: %{room_id: id, nightly_rate_cents: 500})
    }
    |> Map.put(:guest_id, "guest")
  end

  defp apply!(type, id, fields) do
    operation =
      Map.merge(fields, %{type: type, operation_id: id, occurred_on: "2027-01-01"})
      |> Jason.encode!()
      |> Jason.decode!()

    assert [%{"status" => "applied"}] = Reservations.submit_batch([operation])
  end
end
