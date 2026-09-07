defmodule GroupStay.ReservationsPersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.OperationFixtures

  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.CashEntry

  @moduletag :tmp_dir
  @moduletag capture_log: true

  setup_all do
    directory =
      Path.expand("../../tmp/persistence-template-#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    template = Path.join(directory, "group_stay.db")

    {:ok, repo} =
      Repo.start_link(
        name: nil,
        database: template,
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    previous = Repo.put_dynamic_repo(repo)

    try do
      Ecto.Migrator.run(Repo, :up, all: true, log: false)
      Repo.query!("PRAGMA wal_checkpoint(TRUNCATE)")
    after
      Supervisor.stop(repo)
      Repo.put_dynamic_repo(previous)
    end

    %{template: template}
  end

  # These tests use real commits and independent connections, outside the SQL
  # sandbox, to exercise SQLite locking and persistence across repository restarts.
  setup %{tmp_dir: directory, template: template} do
    database = Path.join(directory, "group_stay.db")
    # The migrated template was checkpointed before its connection was closed.
    File.cp!(template, database)

    options = [
      name: nil,
      database: database,
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 100
    ]

    repo = start_supervised!({Repo, options})
    previous = Repo.put_dynamic_repo(repo)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)

    %{repo: repo, options: options}
  end

  test "competing expected revisions apply only once", %{repo: repo} do
    Reservations.submit_batch([open_group()])

    results =
      race(repo, fn index ->
        [result] =
          Reservations.submit_batch([
            payment(%{"operation_id" => "race-#{index}", "expected_revision" => 1})
          ])

        result
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(&1[:code] == "stale_revision" and &1.actual_revision == 2)) == 3
    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.ledger().cash_held_cents == 5_000
    assert Repo.aggregate(CashEntry, :count) == 1
  end

  test "unconditional concurrent payments cannot overfund a deposit", %{repo: repo} do
    Reservations.submit_batch([open_group()])

    results =
      race(repo, fn index ->
        [result] =
          Reservations.submit_batch([
            payment(%{"operation_id" => "race-#{index}", "amount_cents" => 10_000})
          ])

        result
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(&1[:code] == "payment_exceeds_outstanding")) == 3
    assert Reservations.get_group("group-81").deposit_paid_cents == 10_000
    assert Reservations.get_group("group-81").revision == 2
    assert Reservations.ledger().cash_held_cents == 10_000
  end

  test "concurrent duplicate openings create exactly one complete booking", %{repo: repo} do
    results =
      race(repo, fn index ->
        [result] = Reservations.submit_batch([open_group(%{"operation_id" => "open-#{index}"})])
        result
      end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(&1[:code] == "group_already_exists")) == 3
    assert length(Reservations.get_group("group-81").rooms) == 2
    assert Reservations.get_group("group-81").revision == 1
  end

  test "group changes roll back if recording the cash entry fails" do
    Reservations.submit_batch([open_group()])
    before = Reservations.get_group("group-81")

    Repo.query!("""
    CREATE TRIGGER reject_cash_entry BEFORE INSERT ON cash_entries
    BEGIN
      SELECT RAISE(ABORT, 'simulated cash storage failure');
    END
    """)

    assert_raise Exqlite.Error, ~r/simulated cash storage failure/, fn ->
      Reservations.submit_batch([payment()])
    end

    assert Reservations.get_group("group-81") == before
    assert Reservations.ledger().cash_held_cents == 0
    assert Repo.all(CashEntry) == []

    Repo.query!("DROP TRIGGER reject_cash_entry")
    assert [%{status: "applied", revision: 2}] = Reservations.submit_batch([payment()])
  end

  test "retries a busy BEGIN without running the callback more than once", %{repo: repo} do
    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:group_stay, :repo, :query],
      &__MODULE__.report_busy_begin/4,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    holder =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.transact(
          fn ->
            send(parent, :locked)

            receive do
              :release -> {:ok, :released}
            end
          end,
          mode: :immediate
        )
      end)

    assert_receive :locked, 5_000

    writer =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.transact_immediate(fn ->
          send(parent, :callback_ran)
          {:ok, :applied}
        end)
      end)

    assert_receive :busy_begin, 5_000
    refute_receive :callback_ran, 0
    send(holder.pid, :release)
    assert Task.await(holder) == {:ok, :released}
    assert Task.await(writer) == {:ok, :applied}
    assert_receive :callback_ran
    refute_receive :callback_ran, 0
  end

  @doc false
  def report_busy_begin(_event, _measurements, metadata, parent) do
    case metadata do
      %{query: "begin", result: {:error, %Exqlite.Error{message: "database is locked"}}} ->
        send(parent, :busy_begin)

      _ ->
        :ok
    end
  end

  test "bookings, revisions, room order and settlements survive restart and migration reruns", %{
    options: options
  } do
    Reservations.submit_batch([
      open_group(),
      payment(),
      reschedule(),
      cancellation(),
      open_group(%{"group_id" => "still-active"}),
      payment(%{"group_id" => "still-active"})
    ])

    before = Reservations.get_group("group-81")
    ledger = Reservations.ledger()
    assert before.revision == 4
    assert ledger == %{cash_held_cents: 5_000, cash_refunded_cents: 5_000, cash_retained_cents: 0}

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)

    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
    assert Reservations.get_group("group-81") == before
    assert Reservations.ledger() == ledger
    assert Reservations.get_group("still-active").revision == 2

    assert [%{code: "stale_revision", actual_revision: 2}, %{revision: 3}] =
             Reservations.submit_batch([
               payment(%{"group_id" => "still-active", "expected_revision" => 1}),
               payment(%{"group_id" => "still-active", "expected_revision" => 2})
             ])
  end

  defp race(repo, fun) do
    parent = self()

    tasks =
      for index <- 1..4 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          send(parent, {:ready, self()})

          receive do
            :go -> fun.(index)
          end
        end)
      end

    for %{pid: pid} <- tasks do
      assert_receive {:ready, ^pid}, 5_000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 10_000)
  end
end
