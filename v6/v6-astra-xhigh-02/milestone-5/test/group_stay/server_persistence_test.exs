defmodule GroupStay.ServerPersistenceTest do
  use ExUnit.Case, async: false

  import GroupStay.ReservationFixtures
  alias GroupStay.Repo

  @moduletag capture_log: true

  test "the test HTTP server honors PORT and database path and replays results across full VM restarts" do
    directory = Path.expand("tmp/server-persistence-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    database = Path.join(directory, "server.db")

    repo =
      start_supervised!(
        {Repo, name: nil, database: database, pool: DBConnection.ConnectionPool, pool_size: 1}
      )

    Repo.put_dynamic_repo(repo)
    Ecto.Migrator.run(Repo, :up, all: true, log: false)
    stop_supervised!(Repo)

    operations = [
      operation("record_cash_payment", %{"operation_id" => "missing", "amount_cents" => 100}),
      open_operation(%{"operation_id" => "open"}),
      operation("record_cash_payment", %{"operation_id" => "pay", "amount_cents" => 105}),
      operation("cancel_group", %{"operation_id" => "stale", "expected_revision" => 1}),
      operation("reschedule_group", %{"operation_id" => "move", "new_arrival_on" => "2027-04-01"}),
      operation("cancel_group", %{"operation_id" => "cancel", "refund_method" => "hotel_credit"})
    ]

    original =
      with_server(database, fn port ->
        assert {200, %{"results" => results}} =
                 request(port, :post, "/partner-batches", %{operations: operations})

        assert Enum.map(results, & &1["status"]) ==
                 ~w(rejected applied applied rejected applied applied)

        %{results: results, domain: read_domain(port)}
      end)

    with_server(database, fn port ->
      for {operation, result} <- Enum.zip(operations, original.results) do
        assert request(port, :get, "/operations/#{operation["operation_id"]}") ==
                 {200, %{"data" => result}}
      end

      assert request(port, :post, "/partner-batches", %{operations: operations}) ==
               {200, %{"results" => original.results}}

      assert read_domain(port) == original.domain

      assert {200, %{"data" => %{"revision" => 4, "status" => "cancelled"}}} =
               original.domain.group

      assert {200, %{"data" => %{"available_cents" => 116}}} = original.domain.credit

      assert {200, %{"data" => %{"cash_converted_to_credit_cents" => 105}}} =
               original.domain.ledger

      corrected =
        operation("cancel_group", %{"operation_id" => "stale", "expected_revision" => 4})

      assert {200, %{"results" => [%{"code" => "operation_id_conflict"}]}} =
               request(port, :post, "/partner-batches", %{operations: [corrected]})

      assert request(port, :get, "/operations/missing-record") ==
               {404, %{"error" => %{"code" => "operation_not_found"}}}
    end)
  end

  test "transfers and corrections replay across full VM restarts with payment provenance intact" do
    directory = Path.expand("tmp/transfer-server-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    database = Path.join(directory, "server.db")

    repo =
      start_supervised!(
        {Repo, name: nil, database: database, pool: DBConnection.ConnectionPool, pool_size: 1}
      )

    Repo.put_dynamic_repo(repo)
    Ecto.Migrator.run(Repo, :up, all: true, log: false)
    stop_supervised!(Repo)

    operations = [
      open_operation(),
      open_operation(%{"group_id" => "destination"}),
      operation("record_cash_payment", %{"operation_id" => "p", "amount_cents" => 100}),
      operation("transfer_deposit", %{
        "source_group_id" => "group-81",
        "destination_group_id" => "destination",
        "amount_cents" => 70
      }),
      operation("reduce_cash_payment", %{"payment_operation_id" => "p", "amount_cents" => 20})
    ]

    paths = ["/groups/group-81", "/groups/destination", "/payments/p", "/ledger?on=2026-10-04"]

    {results, reads} =
      with_server(database, fn port ->
        assert {200, %{"results" => results}} =
                 request(port, :post, "/partner-batches", %{operations: operations})

        assert Enum.all?(results, &(&1["status"] == "applied"))
        {results, Enum.map(paths, &request(port, :get, &1))}
      end)

    with_server(database, fn port ->
      assert request(port, :post, "/partner-batches", %{operations: operations}) ==
               {200, %{"results" => results}}

      assert Enum.map(paths, &request(port, :get, &1)) == reads

      assert {200,
              %{
                "data" => %{
                  "held_by_group" => [
                    %{"group_id" => "destination", "amount_cents" => 50},
                    %{"group_id" => "group-81", "amount_cents" => 30}
                  ]
                }
              }} = request(port, :get, "/payments/p")

      chargeback =
        operation("charge_back_payment", %{
          "payment_operation_id" => "p",
          "expected_revision" => 4
        })

      assert {200,
              %{
                "results" => [
                  %{"status" => "applied", "revision" => 5, "charged_back_cents" => 80}
                ]
              }} =
               request(port, :post, "/partner-batches", %{operations: [chargeback]})
    end)
  end

  defp read_domain(port) do
    %{
      group: request(port, :get, "/groups/group-81"),
      credit: request(port, :get, "/guests/guest-22/credit?on=2026-10-04"),
      ledger: request(port, :get, "/ledger?on=2026-10-04")
    }
  end

  defp request(port, method, path, body \\ nil) do
    body = if body == nil, do: "", else: Jason.encode!(body)
    method = method |> Atom.to_string() |> String.upcase()

    request = [
      "#{method} /api/v1#{path} HTTP/1.1\r\n",
      "Host: 127.0.0.1:#{port}\r\nConnection: close\r\n",
      "Content-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n",
      body
    ]

    with {:ok, socket} <- :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500) do
      try do
        :ok = :gen_tcp.send(socket, request)
        receive_response(socket, "")
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp receive_response(socket, response) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        receive_response(socket, response <> data)

      {:error, :closed} ->
        [headers, body] = String.split(response, "\r\n\r\n", parts: 2)
        [_, status, _] = String.split(headers, " ", parts: 3)
        {String.to_integer(status), Jason.decode!(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp with_server(database, fun) do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, {_, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)

    server =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["phx.server"],
        cd: File.cwd!(),
        env: [
          {~c"MIX_ENV", ~c"test"},
          {~c"PORT", Integer.to_charlist(port)},
          {~c"GROUP_STAY_DATABASE_PATH", String.to_charlist(database)}
        ]
      ])

    {:os_pid, pid} = Port.info(server, :os_pid)
    on_exit(fn -> stop_server(server, pid) end)

    try do
      await_server(server, port, System.monotonic_time(:millisecond) + 15_000, "")
      fun.(port)
    after
      stop_server(server, pid)
    end
  end

  defp await_server(server, port, deadline, output) do
    receive do
      {^server, {:data, data}} -> await_server(server, port, deadline, output <> data)
      {^server, {:exit_status, status}} -> flunk("HTTP server exited #{status}: #{output}")
    after
      0 ->
        case request(port, :get, "/ledger") do
          {200, _} ->
            :ok

          other ->
            if System.monotonic_time(:millisecond) >= deadline do
              flunk("HTTP server did not start: #{inspect(other)}\n#{output}")
            end

            Process.sleep(50)
            await_server(server, port, deadline, output)
        end
    end
  end

  defp stop_server(server, pid) do
    if Port.info(server) do
      # Abrupt VM termination proves durability without relying on shutdown hooks
      # or waiting for the HTTP server to drain persistent client connections.
      System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      await_exit(server, pid)
    end
  end

  defp await_exit(server, pid) do
    receive do
      {^server, {:exit_status, _}} -> :ok
      {^server, {:data, _}} -> await_exit(server, pid)
    after
      5_000 ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        flunk("HTTP server failed to stop")
    end
  end
end
