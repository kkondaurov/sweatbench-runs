defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations
  alias GroupStay.Reservations.PartnerOperation

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-durable",
        "type" => "open_group",
        "occurred_on" => "2026-01-01",
        "group_id" => "durable-group",
        "guest_id" => "durable-guest",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-03-01",
        "departure_on" => "2026-03-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "durable-room", "nightly_rate_cents" => 1_000}]
      },
      overrides
    )
  end

  defp payment_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "durable-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => "durable-group",
        "amount_cents" => 100
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  test "replays an equivalent payload verbatim after later state changes", %{conn: conn} do
    assert submit(conn, [open_operation()]) |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "open-durable",
                 "status" => "applied",
                 "group_id" => "durable-group",
                 "deposit_due_cents" => 200,
                 "revision" => 1
               }
             ]
           }

    original_payment = payment_operation()

    original_result =
      submit(build_conn(), [original_payment])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert submit(build_conn(), [
             payment_operation(%{"operation_id" => "later-payment", "amount_cents" => 50})
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0), "revision"]) == 3

    equivalent_payment =
      original_payment
      |> Map.to_list()
      |> Enum.reverse()
      |> Map.new()

    assert submit(build_conn(), [equivalent_payment]) |> json_response(200) == %{
             "results" => [original_result]
           }

    assert get(build_conn(), "/api/v1/operations/durable-payment") |> json_response(200) == %{
             "data" => original_result
           }

    assert get(build_conn(), "/api/v1/groups/durable-group")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 3
  end

  test "remembers rejections and retains their submitted audit payload", %{conn: conn} do
    rejected_payment = %{
      "operation_id" => "missing-payment",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-01-02",
      "group_id" => "durable-group",
      "amount_cents" => 100
    }

    rejection = %{
      "operation_id" => "missing-payment",
      "status" => "rejected",
      "code" => "group_not_found",
      "group_id" => "durable-group"
    }

    assert submit(conn, [rejected_payment]) |> json_response(200) == %{"results" => [rejection]}

    assert submit(build_conn(), [open_operation()])
           |> json_response(200)
           |> get_in(["results", Access.at(0), "status"]) ==
             "applied"

    assert submit(build_conn(), [rejected_payment]) |> json_response(200) == %{
             "results" => [rejection]
           }

    assert get(build_conn(), "/api/v1/operations/missing-payment") |> json_response(200) == %{
             "data" => rejection
           }

    remembered = Repo.get_by(PartnerOperation, operation_id: "missing-payment")
    assert remembered.operation_type == "record_cash_payment"
    assert remembered.payload == rejected_payment
    assert remembered.result == rejection
  end

  test "rejects payload conflicts without replacing records and continues the batch", %{
    conn: conn
  } do
    assert submit(conn, [open_operation(), payment_operation()])
           |> json_response(200)
           |> get_in(["results", Access.at(1), "revision"]) ==
             2

    assert submit(build_conn(), [
             payment_operation(%{"amount_cents" => 50}),
             payment_operation(%{"operation_id" => "later-payment", "amount_cents" => 50})
           ])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "durable-payment",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               },
               %{
                 "operation_id" => "later-payment",
                 "status" => "applied",
                 "group_id" => "durable-group",
                 "amount_cents" => 50,
                 "outstanding_deposit_cents" => 50,
                 "revision" => 3
               }
             ]
           }

    assert get(build_conn(), "/api/v1/operations/durable-payment") |> json_response(200) == %{
             "data" => %{
               "operation_id" => "durable-payment",
               "status" => "applied",
               "group_id" => "durable-group",
               "amount_cents" => 100,
               "outstanding_deposit_cents" => 100,
               "revision" => 2
             }
           }

    assert Repo.all(from operation in PartnerOperation, order_by: operation.id)
           |> Enum.map(& &1.operation_id) == ["open-durable", "durable-payment", "later-payment"]
  end

  test "replays stale revisions exactly and rejects corrected retries as conflicts", %{conn: conn} do
    assert submit(conn, [open_operation(), payment_operation()])
           |> json_response(200)
           |> get_in(["results", Access.at(1), "revision"]) == 2

    stale_payment =
      payment_operation(%{
        "operation_id" => "stale-payment",
        "amount_cents" => 10,
        "expected_revision" => 1
      })

    stale_result = %{
      "operation_id" => "stale-payment",
      "status" => "rejected",
      "code" => "stale_revision",
      "group_id" => "durable-group",
      "expected_revision" => 1,
      "actual_revision" => 2
    }

    assert submit(build_conn(), [
             stale_payment,
             payment_operation(%{
               "operation_id" => "later-payment",
               "amount_cents" => 10,
               "expected_revision" => 2
             })
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == stale_result

    assert submit(build_conn(), [stale_payment]) |> json_response(200) == %{
             "results" => [stale_result]
           }

    assert submit(build_conn(), [Map.put(stale_payment, "expected_revision", 3)])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "stale-payment",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }
  end

  test "concurrent retries have one applied effect", %{conn: conn} do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    operation = open_operation()

    results =
      1..2
      |> Task.async_stream(
        fn _ -> Reservations.apply_batch([operation]) end,
        max_concurrency: 2,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, [result]} -> result end)

    assert Enum.uniq(results) == [
             %{
               "operation_id" => "open-durable",
               "status" => "applied",
               "group_id" => "durable-group",
               "deposit_due_cents" => 200,
               "revision" => 1
             }
           ]

    assert get(conn, "/api/v1/groups/durable-group")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 1
  end

  test "returns operation_not_found for an unknown operation", %{conn: conn} do
    assert get(conn, "/api/v1/operations/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end
end
