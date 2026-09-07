defmodule GroupStay.ReservationsPersistenceTest do
  # These tests use an isolated on-disk database and real transactions, because
  # sandbox ownership would serialize or wrap the transactions being exercised.
  use ExUnit.Case, async: false
  import GroupStay.OperationFixtures
  alias GroupStay.{Repo, Reservations}

  @migrations [
    {20_260_907_000_000, GroupStay.Repo.Migrations.CreateGroups},
    {20_260_907_000_001, GroupStay.Repo.Migrations.AddCancellationEconomics}
  ]

  setup_all do
    for {version, module} <- @migrations, not Code.ensure_loaded?(module) do
      [path] = Path.wildcard(Path.join(Ecto.Migrator.migrations_path(Repo), "#{version}_*.exs"))
      Code.require_file(path)
    end

    :ok
  end

  setup context do
    directory =
      Path.expand("../../tmp/reservations-#{Ecto.UUID.generate()}", __DIR__)

    File.mkdir_p!(directory)
    database = Path.join(directory, "reservations.db")
    on_exit(fn -> remove_database(directory) end)

    start_repo(database, 1)

    migrations = if context[:legacy], do: Enum.take(@migrations, 1), else: @migrations

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) ==
             Enum.map(migrations, &elem(&1, 0))

    stop_supervised!(Repo)
    repo = start_repo(database, 4)

    {:ok, database: database, repo: repo}
  end

  test "migrated records and finance settlements survive repository restart", %{
    database: database
  } do
    Reservations.process_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 500}),
      operation("cancel_group"),
      open_operation(%{"group_id" => "active"}),
      operation("record_cash_payment", %{"group_id" => "active", "amount_cents" => 123})
    ])

    cancelled = Reservations.get_group("group-81")
    active = Reservations.get_group("active")
    totals = Reservations.ledger()
    stop_supervised!(Repo)
    start_repo(database, 1)

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == []
    assert Reservations.get_group("group-81") == cancelled
    assert Reservations.get_group("active") == active
    assert Reservations.ledger() == totals

    assert totals == %{
             cash_held_cents: 123,
             cash_refunded_cents: 500,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }
  end

  test "competing conditional payments apply exactly once", %{repo: repo} do
    Reservations.process_batch([open_operation()])

    results =
      concurrently(repo, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "pay-#{index}",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 7
    assert Enum.all?(rejected, &(&1.code == "stale_revision" and &1.actual_revision == 2))
    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "competing unconditional payments do not lose cash or revision increments", %{repo: repo} do
    Reservations.process_batch([open_operation()])

    results =
      concurrently(repo, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "pay-#{index}",
          "amount_cents" => 100
        })
      end)

    assert Enum.all?(results, &(&1.status == "applied"))
    assert Enum.sort(Enum.map(results, & &1.revision)) == Enum.to_list(2..9)
    assert Reservations.get_group("group-81").revision == 9
    assert Reservations.ledger().cash_held_cents == 800
  end

  test "competing openings preserve group uniqueness", %{repo: repo} do
    results = concurrently(repo, &open_operation(%{"operation_id" => "open-#{&1}"}))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 7
    assert Reservations.get_group("group-81").revision == 1
  end

  @tag :capture_log
  test "a writer outlasting the busy timeout does not lose or duplicate a payment", %{repo: repo} do
    Reservations.process_batch([open_operation()])
    parent = self()

    writer =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.transaction(
          fn ->
            send(parent, :write_lock_acquired)
            Process.sleep(2_200)
          end,
          mode: :immediate
        )
      end)

    assert_receive :write_lock_acquired, 1_000

    assert [%{status: "applied", revision: 2}] =
             Reservations.process_batch([
               operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1})
             ])

    assert {:ok, :ok} = Task.await(writer)
    assert Reservations.get_group("group-81").deposit_paid_cents == 100
    assert Reservations.ledger().cash_held_cents == 100
  end

  @tag :legacy
  test "upgrading the original schema backfills policies and preserves cash and settlements" do
    for {id, booked, plan, status, paid, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 500, 0, 0},
          {"new", "2027-01-01", "flexible", "active", 600, 0, 0},
          {"advance", "2026-10-01", "advance_purchase", "active", 700, 0, 0},
          {"cancelled", "2026-10-01", "flexible", "cancelled", 0, 200, 0},
          {"retained", "2026-10-01", "advance_purchase", "cancelled", 0, 0, 300}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on,
          departure_on, rate_plan, status, revision, rooms, lodging_total_cents,
          deposit_due_cents, deposit_paid_cents, cash_refunded_cents, cash_retained_cents)
        VALUES (?, 'guest-22', 'ams-canal', ?, '2027-03-01', '2027-03-04', ?, ?, 3,
          '[{"room_id":"room-a","nightly_rate_cents":15000}]', 45000, ?, ?, ?, ?)
        """,
        [
          id,
          booked,
          plan,
          status,
          if(status == "active", do: 9000, else: 0),
          paid,
          refunded,
          retained
        ]
      )
    end

    assert Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false) == [
             20_260_907_000_001
           ]

    for {id, policy, cash} <- [
          {"old", "flex-14", 500},
          {"new", "flex-30", 600},
          {"advance", "advance-nonrefundable", 700},
          {"cancelled", "flex-14", 0}
        ] do
      group = Reservations.get_group(id)
      assert group.policy_version == policy
      assert group.cash_paid_cents == cash
      assert group.deposit_paid_cents == cash
      assert group.credit_paid_cents == 0
      assert group.revision == 3
      assert Enum.map(group.rooms, & &1.room_id) == ["room-a"]
    end

    assert Reservations.ledger() == %{
             cash_held_cents: 1800,
             cash_refunded_cents: 200,
             cash_retained_cents: 300,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }

    assert [%{revision: 4, credit_issued_cents: 550}, %{refunded_cents: 0, retained_cents: 600}] =
             Reservations.process_batch([
               operation("cancel_group", %{
                 "group_id" => "old",
                 "occurred_on" => "2027-02-01",
                 "refund_method" => "hotel_credit"
               }),
               operation("cancel_group", %{"group_id" => "new", "occurred_on" => "2027-02-01"})
             ])
  end

  test "credit lots and paused allocations survive repository restart", %{database: database} do
    Reservations.process_batch([
      open_operation(%{"group_id" => "source"}),
      operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 500}),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"}),
      open_operation(),
      operation("apply_hotel_credit", %{"amount_cents" => 400})
    ])

    totals = Reservations.ledger(~D[2028-01-01])
    assert totals.credit_liability_cents == 400
    stop_supervised!(Repo)
    start_repo(database, 1)
    assert Reservations.ledger(~D[2028-01-01]) == totals
    assert GroupStay.Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 150

    assert [%{credit_issued_cents: 0, revision: 3}] =
             Reservations.process_batch([operation("cancel_group")])

    assert GroupStay.Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 550
  end

  test "competing groups cannot spend the same guest credit twice", %{repo: repo} do
    Reservations.process_batch([
      open_operation(%{"group_id" => "source"}),
      operation("record_cash_payment", %{"group_id" => "source", "amount_cents" => 500}),
      operation("cancel_group", %{"group_id" => "source", "refund_method" => "hotel_credit"})
    ])

    Reservations.process_batch(
      for index <- 1..8, do: open_operation(%{"group_id" => "target-#{index}"})
    )

    results =
      concurrently(repo, fn index ->
        operation("apply_hotel_credit", %{
          "group_id" => "target-#{index}",
          "operation_id" => "credit-#{index}",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 5
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 3
    assert GroupStay.Credits.for_guest("guest-22", ~D[2026-10-04]).available_cents == 50
    assert Reservations.ledger(~D[2026-10-04]).credit_liability_cents == 550
    assert Reservations.ledger(~D[2028-01-01]).credit_liability_cents == 500

    for {result, index} <- Enum.with_index(results, 1) do
      group = Reservations.get_group("target-#{index}")
      assert group.revision == if(result.status == "applied", do: 2, else: 1)
      assert group.credit_paid_cents == if(result.status == "applied", do: 100, else: 0)
    end
  end

  defp start_repo(database, pool_size) do
    repo =
      start_supervised!(
        {Repo,
         name: nil, database: database, pool: DBConnection.ConnectionPool, pool_size: pool_size}
      )

    Repo.put_dynamic_repo(repo)
    repo
  end

  defp remove_database(directory) do
    case File.rm_rf(directory) do
      {:ok, _} ->
        :ok

      {:error, reason, _} when reason in [:eexist, :enotempty] ->
        # Native SQLite cleanup can briefly change WAL files during teardown.
        File.rm_rf!(directory)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove test database", path: path
    end
  end

  defp concurrently(repo, build_operation) do
    parent = self()

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go ->
              [result] = Reservations.process_batch([build_operation.(index)])
              result
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 1_000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 10_000)
  end
end
