defmodule GroupStay.Reservations.PersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.OperationFixtures
  alias GroupStay.{Repo, Reservations}

  @moduletag :tmp_dir

  setup_all do
    migrations =
      Repo.config()[:priv]
      |> then(fn priv -> Path.join(priv || "priv/repo", "migrations/*.exs") end)
      |> Path.wildcard()
      |> Enum.map(fn path ->
        {version, _name} = path |> Path.basename() |> Integer.parse()
        [{module, _binary}] = Code.require_file(path)
        {version, module}
      end)

    %{migrations: migrations}
  end

  setup %{tmp_dir: directory, migrations: migrations} = tags do
    # A real pool and an isolated file exercise SQLite locking and durability outside
    # the SQL sandbox. ExUnit's temporary directory stays within this repository.
    options = [
      name: nil,
      database: Path.join(directory, "reservations.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: Map.get(tags, :busy_timeout, 5000)
    ]

    # Initialize WAL and migrate with one connection before starting concurrent writers.
    # Multiple connections racing to initialize an empty SQLite file can report SQLITE_BUSY.
    initializer = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    Repo.put_dynamic_repo(initializer)
    initial_migrations = if tags[:legacy_database], do: Enum.take(migrations, 1), else: migrations
    Ecto.Migrator.run(Repo, initial_migrations, :up, all: true, log: false)
    stop_supervised!(Repo)

    repository = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repository)
    %{repository: repository, options: options}
  end

  test "concurrent expected revisions allow exactly one writer", %{repository: repository} do
    Reservations.submit_batch([open_group()])

    results =
      concurrently(repository, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 100,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    rejected = Enum.filter(results, &(&1.status == "rejected"))
    assert length(rejected) == 7
    assert Enum.all?(rejected, &(&1.code == "stale_revision" and &1.actual_revision == 2))
    assert {:ok, group} = Reservations.get_group("group-81")
    assert group.revision == 2
    assert group.deposit_paid_cents == 100
    assert Reservations.ledger().cash_held_cents == 100
  end

  test "unconditional concurrent payments do not lose cash or revisions", %{
    repository: repository
  } do
    Reservations.submit_batch([open_group()])

    results =
      concurrently(repository, fn index ->
        operation("record_cash_payment", %{
          "operation_id" => "payment-#{index}",
          "amount_cents" => 100
        })
      end)

    assert Enum.all?(results, &(&1.status == "applied"))
    assert Enum.sort(Enum.map(results, & &1.revision)) == Enum.to_list(2..9)
    assert {:ok, group} = Reservations.get_group("group-81")
    assert group.revision == 9
    assert group.deposit_paid_cents == 800
    assert Reservations.ledger().cash_held_cents == 800
  end

  test "concurrent opens reserve a group identifier only once", %{repository: repository} do
    results = concurrently(repository, &open_group(%{"operation_id" => "open-#{&1}"}))
    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "group_already_exists")) == 7
    assert Repo.aggregate(GroupStay.Reservations.Room, :count) == 2
  end

  test "migrations are repeatable and balances survive repository restart", %{
    options: options,
    migrations: migrations
  } do
    Reservations.submit_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group")
    ])

    before = Reservations.get_group("group-81")
    ledger = Reservations.ledger()
    stop_supervised!(Repo)
    repository = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repository)

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []
    assert Reservations.get_group("group-81") == before
    assert Reservations.ledger() == ledger

    assert ledger == %{
             cash_held_cents: 0,
             cash_refunded_cents: 100,
             cash_retained_cents: 0,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }
  end

  @tag :legacy_database
  test "upgrades original databases using booked dates without changing existing accounting", %{
    migrations: migrations
  } do
    for {id, booked_on, plan, status, paid, refunded, retained} <- [
          {"old", "2026-12-31", "flexible", "active", 100, 0, 0},
          {"new", "2027-01-01", "flexible", "active", 200, 0, 0},
          {"advance", "2027-01-01", "advance_purchase", "active", 300, 0, 0},
          {"cancelled", "2027-01-01", "flexible", "cancelled", 0, 400, 0},
          {"retained", "2026-12-31", "advance_purchase", "cancelled", 0, 0, 500}
        ] do
      Repo.query!(
        """
        INSERT INTO groups
          (group_id, guest_id, property_id, booked_on, arrival_on, departure_on, rate_plan,
           status, revision, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
           cash_refunded_cents, cash_retained_cents)
        VALUES (?, 'legacy-guest', 'legacy-property', ?, '2028-03-01', '2028-03-04', ?, ?, 7,
                15000, ?, ?, ?, ?)
        """,
        [
          id,
          booked_on,
          plan,
          status,
          if(status == "active", do: 3000, else: 0),
          paid,
          refunded,
          retained
        ]
      )

      Repo.query!(
        """
        INSERT INTO rooms (group_id, room_id, position, nightly_rate_cents)
        VALUES (?, 'legacy-room', 0, 5000)
        """,
        [id]
      )
    end

    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == [20_260_907_000_001]

    for {id, policy} <- [
          {"old", "flex-14"},
          {"new", "flex-30"},
          {"advance", "advance-nonrefundable"},
          {"cancelled", "flex-30"},
          {"retained", "advance-nonrefundable"}
        ] do
      assert {:ok, group} = Reservations.get_group(id)
      assert group.policy_version == policy
      assert group.revision == 7
      assert group.credit_paid_cents == 0
      assert group.cash_converted_to_credit_cents == 0
      assert [%{room_id: "legacy-room", nightly_rate_cents: 5000}] = group.rooms
      assert GroupStayWeb.GroupJSON.data(group).cash_paid_cents == group.deposit_paid_cents
    end

    assert Reservations.ledger(~D[2028-01-01]) == %{
             cash_held_cents: 600,
             cash_refunded_cents: 400,
             cash_retained_cents: 500,
             cash_converted_to_credit_cents: 0,
             credit_liability_cents: 0
           }

    [moved, cancelled] =
      Reservations.submit_batch([
        operation("reschedule_group", %{
          "group_id" => "old",
          "new_arrival_on" => "2028-04-01",
          "occurred_on" => "2027-02-01",
          "expected_revision" => 7
        }),
        operation("cancel_group", %{
          "group_id" => "old",
          "occurred_on" => "2028-03-18",
          "expected_revision" => 8
        })
      ])

    assert moved.policy_version == "flex-14"
    assert moved.refundable_until == ~D[2028-03-18]
    assert cancelled.refunded_cents == 100
    assert cancelled.revision == 9
    assert Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false) == []
  end

  test "concurrent groups cannot spend the same guest credit twice", %{repository: repository} do
    issue_credit()

    Reservations.submit_batch(
      for index <- 1..8, do: open_group(%{"group_id" => "target-#{index}"})
    )

    results =
      concurrently(repository, fn index ->
        operation("apply_hotel_credit", %{
          "group_id" => "target-#{index}",
          "amount_cents" => 110,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "insufficient_credit")) == 7
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 0
    assert Reservations.ledger(~D[2028-01-01]).credit_liability_cents == 110
    assert Repo.aggregate(GroupStay.Reservations.CreditAllocation, :sum, :amount_cents) == 110

    for result <- results do
      if result.status == "applied", do: assert(result.revision == 2)
    end
  end

  test "concurrent credit applications check revision before consuming lots", %{
    repository: repository
  } do
    issue_credit()
    Reservations.submit_batch([open_group(%{"group_id" => "target"})])

    results =
      concurrently(repository, fn _index ->
        operation("apply_hotel_credit", %{
          "group_id" => "target",
          "amount_cents" => 10,
          "expected_revision" => 1
        })
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 100
    assert Reservations.ledger(~D[2026-11-01]).credit_liability_cents == 110
  end

  test "credit provenance, policy and settlements survive restart", %{options: options} do
    issue_credit()

    Reservations.submit_batch([
      open_group(%{
        "group_id" => "target",
        "arrival_on" => "2028-06-01",
        "departure_on" => "2028-06-04"
      }),
      operation("apply_hotel_credit", %{"group_id" => "target", "amount_cents" => 80})
    ])

    before = Reservations.get_group("target")
    stop_supervised!(Repo)
    repository = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repository)
    assert Reservations.get_group("target") == before
    assert Reservations.ledger(~D[2027-11-02]).credit_liability_cents == 80
    assert Reservations.ledger(~D[2027-11-02]).cash_converted_to_credit_cents == 100
    assert Reservations.guest_credit("guest-22", ~D[2026-11-01]).available_cents == 30

    [result] =
      Reservations.submit_batch([
        operation("cancel_group", %{
          "group_id" => "target",
          "occurred_on" => "2027-01-01",
          "expected_revision" => 2
        })
      ])

    assert result.status == "applied"
    assert result.credit_issued_cents == 0

    assert [
             %{
               source_operation_id: "cancel_group-1",
               remaining_cents: 110,
               expires_on: ~D[2027-11-01]
             }
           ] =
             Reservations.guest_credit("guest-22", ~D[2027-01-01]).lots
  end

  @tag busy_timeout: 25
  test "retries initial write-lock contention without replaying a payment", %{
    repository: repository
  } do
    Reservations.submit_batch([open_group()])
    parent = self()

    lock_holder =
      Task.async(fn ->
        Repo.put_dynamic_repo(repository)

        Repo.transaction(
          fn ->
            send(parent, :locked)
            receive do: (:release -> :ok)
          end,
          mode: :immediate
        )
      end)

    assert_receive :locked

    # Hold the lock beyond the first SQLite busy timeout, then let the retry acquire it.
    ExUnit.CaptureLog.capture_log(fn ->
      Process.send_after(lock_holder.pid, :release, 60)

      assert [%{status: "applied", revision: 2}] =
               Reservations.submit_batch([
                 operation("record_cash_payment", %{
                   "amount_cents" => 100,
                   "expected_revision" => 1
                 })
               ])

      assert {:ok, :ok} = Task.await(lock_holder)
    end)

    assert {:ok, group} = Reservations.get_group("group-81")
    assert group.deposit_paid_cents == 100
    assert group.revision == 2
  end

  test "database failures after BEGIN roll back writes and are not retried" do
    parent = self()

    assert_raise Exqlite.Error, fn ->
      Repo.with_write_lock(fn ->
        send(parent, :executed)

        Repo.insert!(%GroupStay.Reservations.CreditLot{
          guest_id: "guest-22",
          source_operation_id: "failed",
          expires_on: ~D[2027-01-01],
          remaining_cents: 10
        })

        Repo.query!("UPDATE credit_lots SET nonexistent_column = 1")
      end)
    end

    assert_receive :executed
    refute_receive :executed
    assert Repo.all(GroupStay.Reservations.CreditLot) == []
  end

  defp issue_credit do
    results =
      Reservations.submit_batch([
        open_group(),
        operation("record_cash_payment", %{"amount_cents" => 100}),
        operation("cancel_group", %{"refund_method" => "hotel_credit"})
      ])

    assert Enum.all?(results, &(&1.status == "applied"))
  end

  defp concurrently(repository, build_operation) do
    parent = self()

    tasks =
      for index <- 1..8 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repository)
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)
          [result] = Reservations.submit_batch([build_operation.(index)])
          result
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, _pid}, 1000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 15_000)
  end
end
