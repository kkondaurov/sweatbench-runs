defmodule GroupStayWeb.GroupsLedgerTest do
  use GroupStayWeb.ConnCase, async: false

  defp json_header(conn) do
    put_req_header(conn, "content-type", "application/json")
  end

  defp submit_batch(conn, operations) do
    conn
    |> json_header()
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
  end

  defp open(group_id \\ "g-1", overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-" <> group_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "prop-1",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp pay(group_id, amount_cents, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel(group_id, occurred_on, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp ledger(conn) do
    conn
    |> get("/api/v1/ledger")
    |> json_response(200)
  end

  test "returns a 404 error for a missing group", %{conn: conn} do
    conn_response = get(conn, "/api/v1/groups/nope")

    assert conn_response.status == 404
    assert json_response(conn_response, 404) == %{"error" => %{"code" => "group_not_found"}}
  end

  test "reads a group with its rooms in the original order", %{conn: conn} do
    open_op =
      open("g-2", %{
        "rooms" => [
          %{"room_id" => "z-1", "nightly_rate_cents" => 100},
          %{"room_id" => "a-2", "nightly_rate_cents" => 200}
        ]
      })

    submit_batch(conn, [open_op])

    assert %{"data" => group} = json_response(get(conn, "/api/v1/groups/g-2"), 200)

    assert group["rooms"] == [
             %{"room_id" => "z-1", "nightly_rate_cents" => 100},
             %{"room_id" => "a-2", "nightly_rate_cents" => 200}
           ]
  end

  test "starts with an empty ledger", %{conn: conn} do
    assert ledger(conn) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "does not count unpaid deposit requirements as cash held", %{conn: conn} do
    submit_batch(conn, [open()])

    assert ledger(conn) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "counts cash applied to active reservations as held", %{conn: conn} do
    submit_batch(conn, [open("a"), open("b"), pay("a", 8_000, "p-1"), pay("b", 1_500, "p-2")])

    assert ledger(conn) == %{
             "data" => %{
               "cash_held_cents" => 9_500,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "moves held cash to refunded when a flexible group is cancelled early", %{conn: conn} do
    submit_batch(conn, [open("a"), pay("a", 8_000, "p-1"), cancel("a", "2026-11-26", "c-1")])

    assert ledger(conn) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 8_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "moves held cash to retained when a flexible group is cancelled late", %{conn: conn} do
    submit_batch(conn, [open("a"), pay("a", 8_000, "p-1"), cancel("a", "2026-11-27", "c-1")])

    assert ledger(conn) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 8_000,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end

  test "splits held cash across refunds and retentions", %{conn: conn} do
    submit_batch(conn, [
      open("a"),
      open("b"),
      pay("a", 8_000, "p-1"),
      pay("b", 1_500, "p-2"),
      cancel("a", "2026-11-26", "c-1"),
      cancel("b", "2026-11-27", "c-2")
    ])

    assert ledger(conn) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 8_000,
               "cash_retained_cents" => 1_500,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
           }
  end
end
