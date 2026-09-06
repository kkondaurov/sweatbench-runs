defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.PartnerFixtures

  alias GroupStay.{Repo, Reservations}

  @moduletag capture_log: true

  setup_all do
    unless Code.ensure_loaded?(GroupStay.Repo.Migrations.CreateGroups) do
      Code.require_file("../../priv/repo/migrations/20260905000000_create_groups.exs", __DIR__)
    end

    :ok
  end

  setup do
    directory =
      Path.expand("../../tmp/reservations-#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(directory)

    options = [
      name: nil,
      database: Path.join(directory, "persistent.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 5000
    ]

    # Initialize a new SQLite file with one connection before opening a larger pool.
    repo = start_supervised!({Repo, Keyword.put(options, :pool_size, 1)})
    Repo.put_dynamic_repo(repo)
    on_exit(fn -> remove_database_directory(directory) end)

    # Represent a database created before this release and ensure migrations preserve it.
    Repo.query!("CREATE TABLE existing_data (value TEXT NOT NULL)")
    Repo.query!("INSERT INTO existing_data VALUES ('preserve me')")
    assert migrate(:up) == [20_260_905_000_000]

    %{repo: repo, options: options}
  end

  test "migrations preserve existing data and deposits survive repository restarts", %{
    options: options
  } do
    Reservations.submit_batch([
      open_operation(),
      operation("record_cash_payment", %{"amount_cents" => 1234}),
      operation("reschedule_group", %{"new_arrival_on" => "2027-01-01"}),
      open_operation(%{"group_id" => "settled"}),
      operation("record_cash_payment", %{"group_id" => "settled", "amount_cents" => 567}),
      operation("cancel_group", %{"group_id" => "settled"})
    ])

    active = Reservations.get_group("group-81")
    settled = Reservations.get_group("settled")
    ledger = Reservations.ledger()

    :ok = stop_supervised(Repo)
    repo = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(repo)

    assert migrate(:up) == []
    assert Repo.query!("SELECT value FROM existing_data").rows == [["preserve me"]]
    assert Reservations.get_group("group-81") == active
    assert Reservations.get_group("settled") == settled
    assert Reservations.ledger() == ledger

    assert [%{status: "rejected", code: "stale_revision", actual_revision: 3}] =
             Reservations.submit_batch([
               operation("cancel_group", %{"expected_revision" => 1})
             ])

    assert [%{status: "applied", revision: 4, refunded_cents: 1234}] =
             Reservations.submit_batch([
               operation("cancel_group", %{"expected_revision" => 3})
             ])

    assert migrate(:down) == [20_260_905_000_000]
    assert Repo.query!("SELECT value FROM existing_data").rows == [["preserve me"]]
    assert migrate(:up) == [20_260_905_000_000]
    assert Reservations.get_group("group-81") == nil
  end

  test "independent connections serialize revision checks, balances, and cancellation", %{
    repo: repo,
    options: options
  } do
    second_repo = start_supervised!(Supervisor.child_spec({Repo, options}, id: :second_repo))
    repos = [repo, second_repo]

    openings = concurrent_operations(repos, List.duplicate(open_operation(), 8))
    assert Enum.count(openings, &(&1.status == "applied")) == 1
    assert Enum.count(openings, &(Map.get(&1, :code) == "group_already_exists")) == 7

    guarded_payment =
      operation("record_cash_payment", %{"amount_cents" => 500, "expected_revision" => 1})

    payments = concurrent_operations(repos, List.duplicate(guarded_payment, 8))
    assert Enum.count(payments, &(&1.status == "applied" and &1.revision == 2)) == 1
    assert Enum.count(payments, &(Map.get(&1, :code) == "stale_revision")) == 7
    assert Reservations.get_group("group-81").deposit_paid_cents == 500

    remaining_payment = operation("record_cash_payment", %{"amount_cents" => 19000})
    payments = concurrent_operations(repos, List.duplicate(remaining_payment, 8))
    assert Enum.count(payments, &(&1.status == "applied" and &1.revision == 3)) == 1
    assert Enum.count(payments, &(Map.get(&1, :code) == "payment_exceeds_outstanding")) == 7
    assert Reservations.ledger().cash_held_cents == 19500

    cancellations = concurrent_operations(repos, List.duplicate(operation("cancel_group"), 8))
    assert Enum.count(cancellations, &(&1.status == "applied" and &1.revision == 4)) == 1
    assert Enum.count(cancellations, &(Map.get(&1, :code) == "group_not_active")) == 7

    assert Reservations.ledger() == %{
             cash_held_cents: 0,
             cash_refunded_cents: 19500,
             cash_retained_cents: 0
           }
  end

  defp migrate(direction) do
    Ecto.Migrator.run(
      Repo,
      [{20_260_905_000_000, GroupStay.Repo.Migrations.CreateGroups}],
      direction,
      all: true,
      log: false
    )
  end

  defp remove_database_directory(directory, attempts \\ 5) do
    case File.rm_rf(directory) do
      {:ok, _files} ->
        :ok

      {:error, reason, _path} when reason in [:eexist, :enotempty, :enoent] and attempts > 0 ->
        # Native SQLite handles can finish releasing WAL files after their owning
        # supervised processes exit. Let that cleanup finish before retrying.
        Process.sleep(20)
        remove_database_directory(directory, attempts - 1)

      {:error, reason, path} ->
        raise File.Error, reason: reason, action: "remove test database", path: path
    end
  end

  defp concurrent_operations(repos, operations) do
    parent = self()

    tasks =
      operations
      |> Enum.with_index()
      |> Enum.map(fn {operation, index} ->
        Task.async(fn ->
          Repo.put_dynamic_repo(Enum.at(repos, rem(index, length(repos))))
          send(parent, {:ready, self()})

          receive do
            :go -> hd(Reservations.submit_batch([operation]))
          end
        end)
      end)

    Enum.each(tasks, fn task -> assert_receive {:ready, pid} when pid == task.pid end)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 15000))
  end
end
