defmodule GroupStay.ReservationsConcurrencyTest do
  use ExUnit.Case, async: false

  alias GroupStay.{Repo, Reservations}

  setup_all do
    directory =
      Path.expand("../../tmp/concurrency-#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(directory)
    on_exit(fn -> GroupStay.TestFiles.remove_directory!(directory) end)

    # Real, independent connection pools exercise SQLite locking outside the SQL sandbox.
    options = [
      name: nil,
      database: Path.join(directory, "groups.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 1
    ]

    first = start_supervised!({Repo, options}, id: :first_repo)
    Repo.put_dynamic_repo(first)

    Ecto.Migrator.run(Repo, Application.app_dir(:group_stay, "priv/repo/migrations"), :up,
      all: true,
      log: false
    )

    second = start_supervised!({Repo, options}, id: :second_repo)

    opening = %{
      "operation_id" => "open",
      "type" => "open_group",
      "occurred_on" => "2026-10-01",
      "group_id" => "concurrent",
      "guest_id" => "guest",
      "property_id" => "property",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 1000}]
    }

    %{repos: [first, second], opening: opening}
  end

  setup %{repos: [first | _]} do
    Repo.put_dynamic_repo(first)
    Repo.delete_all(GroupStay.CreditClawback)
    Repo.delete_all(GroupStay.CreditEntitlement)
    Repo.delete_all(GroupStay.RoomAllocation)
    Repo.delete_all(GroupStay.PaymentTransfer)
    Repo.delete_all(GroupStay.Operation)
    Repo.delete_all(GroupStay.CreditAllocation)
    Repo.delete_all(GroupStay.CreditLot)
    Repo.delete_all(GroupStay.Group)
    :ok
  end

  defp race(repos, operation) do
    parent = self()

    operations =
      if is_list(operation), do: operation, else: List.duplicate(operation, length(repos))

    tasks =
      for {repo, operation} <- Enum.zip(repos, operations) do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go -> Reservations.submit([operation]) |> hd()
          end
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, _}, 1000
    end

    for task <- tasks, do: send(task.pid, :go)
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  test "simultaneous opens preserve group uniqueness", %{repos: repos, opening: opening} do
    results = race(repos, [opening, Map.put(opening, "operation_id", "other-open")])
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 1
    assert Reservations.get_group("concurrent").revision == 1
  end

  test "only one concurrent writer can use a revision", %{repos: repos, opening: opening} do
    Reservations.submit([opening])

    payment = %{
      "operation_id" => "pay",
      "type" => "record_cash_payment",
      "group_id" => "concurrent",
      "occurred_on" => "2026-10-02",
      "amount_cents" => 50,
      "expected_revision" => 1
    }

    results = race(repos, [payment, Map.put(payment, "operation_id", "other-pay")])
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 1
    assert Reservations.get_group("concurrent").revision == 2
    assert Reservations.ledger().cash_held_cents == 50
  end

  test "unconditional concurrent payments cannot overfund a deposit", %{
    repos: repos,
    opening: opening
  } do
    Reservations.submit([opening])

    results =
      race(
        repos,
        for(
          id <- ["pay", "other-pay"],
          do: %{
            "operation_id" => id,
            "type" => "record_cash_payment",
            "group_id" => "concurrent",
            "occurred_on" => "2026-10-02",
            "amount_cents" => 150
          }
        )
      )

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 1
    assert Reservations.get_group("concurrent").outstanding_deposit_cents == 50
    assert Reservations.ledger().cash_held_cents == 150
  end

  test "migrations can be rerun on a populated database without losing records", %{
    opening: opening
  } do
    Reservations.submit([opening])
    before = Reservations.get_group("concurrent")

    assert Ecto.Migrator.run(Repo, Application.app_dir(:group_stay, "priv/repo/migrations"), :up,
             all: true,
             log: false
           ) == []

    assert Reservations.get_group("concurrent") == before
  end

  test "concurrent exact retries return one committed result with at-most-once cash effects", %{
    repos: repos,
    opening: opening
  } do
    [first, second] = race(repos, opening)
    assert first == second
    assert first.status == "applied"

    payment = %{
      "operation_id" => "pay",
      "type" => "record_cash_payment",
      "group_id" => "concurrent",
      "occurred_on" => "2026-10-02",
      "amount_cents" => 50,
      "expected_revision" => 1
    }

    [first, second] = race(repos, payment)
    assert first == second
    assert first.revision == 2
    assert Reservations.get_group("concurrent").revision == 2
    assert Reservations.ledger().cash_held_cents == 50
    assert Repo.aggregate(GroupStay.Operation, :count) == 2
  end

  test "concurrent conflicting submissions keep the winning payload and result", %{
    repos: repos,
    opening: opening
  } do
    [first, second] = race(repos, [opening, Map.put(opening, "group_id", "other")])
    results = [first, second]
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "operation_id_conflict")) == 1
    assert Repo.aggregate(GroupStay.Group, :count) == 1
    assert Repo.aggregate(GroupStay.Operation, :count) == 1
    winner = Enum.find(results, &(&1.status == "applied"))
    assert Reservations.get_operation("open")["group_id"] == winner.group_id
  end

  test "concurrent rejected retries are also committed only once", %{repos: repos} do
    operation = %{"operation_id" => "invalid", "type" => "unknown", "extra" => [1, 2]}
    [first, second] = race(repos, operation)
    assert first == second
    assert first.code == "invalid_operation"
    assert Repo.aggregate(GroupStay.Operation, :count) == 1
  end

  test "concurrent groups belonging to one guest cannot spend the same credit", %{
    repos: repos,
    opening: opening
  } do
    Reservations.submit([
      opening,
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "group_id" => "concurrent",
        "occurred_on" => "2026-10-01",
        "amount_cents" => 200
      },
      %{
        "operation_id" => "credit",
        "type" => "cancel_group",
        "group_id" => "concurrent",
        "occurred_on" => "2026-10-01",
        "refund_method" => "hotel_credit"
      },
      Map.merge(opening, %{"group_id" => "first", "operation_id" => "open-first"}),
      Map.merge(opening, %{"group_id" => "second", "operation_id" => "open-second"})
    ])

    operations =
      for id <- ["first", "second"],
          do: %{
            "operation_id" => "apply-#{id}",
            "type" => "apply_hotel_credit",
            "group_id" => id,
            "occurred_on" => "2026-10-01",
            "amount_cents" => 150,
            "expected_revision" => 1
          }

    results = race(repos, operations)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 1

    assert Enum.sort(for id <- ["first", "second"], do: Reservations.get_group(id).revision) == [
             1,
             2
           ]

    assert Reservations.guest_credit("guest", ~D[2026-10-01]).available_cents == 70
    assert Reservations.ledger(~D[2026-10-01]).credit_liability_cents == 220
    assert Reservations.ledger(~D[2026-10-01]).cash_held_cents == 0
  end

  test "concurrent reductions compose and chargeback retries have at-most-once effects", %{
    repos: repos,
    opening: opening
  } do
    Reservations.submit([
      opening,
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "group_id" => "concurrent",
        "occurred_on" => "2026-10-01",
        "amount_cents" => 150
      }
    ])

    reductions =
      for id <- ["reduce1", "reduce2"],
          do: %{
            "operation_id" => id,
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "pay",
            "occurred_on" => "2026-10-01",
            "amount_cents" => 100
          }

    results = race(repos, reductions)
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "reduction_exceeds_held_cash")) == 1
    assert {:ok, %{held_cents: 50, reduced_cents: 100}} = Reservations.get_payment("pay")

    chargeback = %{
      "operation_id" => "chargeback",
      "type" => "charge_back_payment",
      "payment_operation_id" => "pay",
      "occurred_on" => "2026-10-01",
      "expected_revision" => 3
    }

    [first, second] = race(repos, chargeback)
    assert first == second
    assert first.charged_back_cents == 50
    assert first.revision == 4

    assert {:ok, %{held_cents: 0, reduced_cents: 100, charged_back_cents: 50}} =
             Reservations.get_payment("pay")

    assert Reservations.ledger().cash_charged_back_cents == 50
  end

  test "concurrent partial cancellation retries issue one credit lot", %{
    repos: repos,
    opening: opening
  } do
    Reservations.submit([
      opening,
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "group_id" => "concurrent",
        "occurred_on" => "2026-10-01",
        "amount_cents" => 100
      }
    ])

    cancel = %{
      "operation_id" => "cancel-rooms",
      "type" => "cancel_rooms",
      "group_id" => "concurrent",
      "room_ids" => ["room"],
      "refund_method" => "hotel_credit",
      "occurred_on" => "2026-10-01"
    }

    [first, second] = race(repos, cancel)
    assert first == second
    assert first.credit_issued_cents == 110
    assert first.revision == 3
    assert Repo.aggregate(GroupStay.CreditLot, :count) == 1
    assert {:ok, %{converted_to_credit_cents: 100}} = Reservations.get_payment("pay")
  end

  test "concurrent transfer retries move once and corrections follow the committed destination",
       %{
         repos: repos,
         opening: opening
       } do
    Reservations.submit([
      opening,
      Map.merge(opening, %{"operation_id" => "dest-open", "group_id" => "dest"}),
      %{
        "operation_id" => "pay",
        "type" => "record_cash_payment",
        "group_id" => "concurrent",
        "occurred_on" => "2026-10-01",
        "amount_cents" => 150
      }
    ])

    transfer = %{
      "operation_id" => "transfer",
      "type" => "transfer_deposit",
      "source_group_id" => "concurrent",
      "destination_group_id" => "dest",
      "amount_cents" => 100,
      "occurred_on" => "2026-10-01",
      "expected_revision" => 2,
      "destination_expected_revision" => 1
    }

    [first, second] = race(repos, transfer)
    assert first == second
    assert first.source_revision == 3
    assert first.destination_revision == 2
    assert Reservations.ledger().cash_held_cents == 150

    assert {:ok,
            %{
              held_by_group: [
                %{group_id: "concurrent", amount_cents: 50},
                %{group_id: "dest", amount_cents: 100}
              ]
            }} = Reservations.get_payment("pay")

    reduction = %{
      "operation_id" => "reduce",
      "type" => "reduce_cash_payment",
      "payment_operation_id" => "pay",
      "amount_cents" => 75,
      "expected_revision" => 3,
      "occurred_on" => "2026-10-01"
    }

    [first, second] = race(repos, reduction)
    assert first == second
    assert first.revision == 4
    assert Reservations.get_group("dest").revision == 3
    assert Reservations.get_group("dest").cash_paid_cents == 25
  end

  test "competing transfers cannot reuse a destination revision", %{
    repos: repos,
    opening: opening
  } do
    Reservations.submit([
      opening,
      Map.merge(opening, %{"operation_id" => "other-open", "group_id" => "other"}),
      Map.merge(opening, %{"operation_id" => "dest-open", "group_id" => "dest"})
    ])

    for id <- ["concurrent", "other"] do
      Reservations.submit([
        %{
          "operation_id" => "pay-#{id}",
          "type" => "record_cash_payment",
          "group_id" => id,
          "occurred_on" => "2026-10-01",
          "amount_cents" => 150
        }
      ])
    end

    operations =
      for id <- ["concurrent", "other"],
          do: %{
            "operation_id" => "transfer-#{id}",
            "type" => "transfer_deposit",
            "source_group_id" => id,
            "destination_group_id" => "dest",
            "amount_cents" => 150,
            "occurred_on" => "2026-10-01",
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          }

    results = race(repos, operations)
    assert Enum.count(results, &(&1.status == "applied")) == 1

    assert Enum.count(
             results,
             &(Map.get(&1, :code) == "stale_revision" and &1.group_id == "dest")
           ) == 1

    assert Reservations.get_group("dest").cash_paid_cents == 150
    assert Reservations.get_group("dest").revision == 2

    assert Enum.sort(for id <- ["concurrent", "other"], do: Reservations.get_group(id).revision) ==
             [2, 3]

    assert Reservations.ledger().cash_held_cents == 300
  end
end
