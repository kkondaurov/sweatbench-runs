defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => "guest-credit",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  test "fixes the policy at booking and recomputes the cutoff on reschedule", %{conn: conn} do
    assert get_in(
             json_response(
               submit(conn, [
                 open_operation("legacy", %{
                   "occurred_on" => "2026-12-31",
                   "arrival_on" => "2027-01-20",
                   "departure_on" => "2027-01-22"
                 })
               ]),
               200
             ),
             ["results", Access.at(0), "revision"]
           ) == 1

    assert json_response(get(conn, "/api/v1/groups/legacy"), 200)
           |> get_in(["data", "policy_version"]) == "flex-14"

    result =
      submit(conn, [
        %{
          "operation_id" => "move-legacy",
          "type" => "reschedule_group",
          "occurred_on" => "2026-12-31",
          "group_id" => "legacy",
          "new_arrival_on" => "2027-02-01"
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(0)])

    assert result["policy_version"] == "flex-14"
    assert result["refundable_until"] == "2027-01-18"

    assert get(conn, "/api/v1/groups/legacy")
           |> json_response(200)
           |> get_in(["data", "refundable_until"]) == "2027-01-18"

    assert get_in(
             json_response(
               submit(conn, [
                 open_operation("new", %{"operation_id" => "open-new"})
               ]),
               200
             ),
             ["results", Access.at(0), "revision"]
           ) == 1

    assert get(conn, "/api/v1/groups/new")
           |> json_response(200)
           |> get_in(["data", "policy_version"]) == "flex-30"
  end

  test "issues, applies, restores, and expires hotel credit", %{conn: conn} do
    assert Enum.map(
             json_response(
               submit(conn, [
                 open_operation("source"),
                 %{
                   "operation_id" => "cash-source",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2027-01-01",
                   "group_id" => "source",
                   "amount_cents" => 1_000
                 },
                 %{
                   "operation_id" => "cancel-source",
                   "type" => "cancel_group",
                   "occurred_on" => "2027-01-01",
                   "group_id" => "source",
                   "refund_method" => "hotel_credit"
                 }
               ]),
               200
             )["results"],
             & &1["status"]
           ) == ["applied", "applied", "applied"]

    cancellation =
      submit(conn, [
        open_operation("target", %{"operation_id" => "open-target"}),
        %{
          "operation_id" => "apply-target",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-02",
          "group_id" => "target",
          "amount_cents" => 300
        },
        %{
          "operation_id" => "apply-target-again",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2027-01-02",
          "group_id" => "target",
          "amount_cents" => 300
        },
        %{
          "operation_id" => "cancel-target",
          "type" => "cancel_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "target"
        }
      ])
      |> json_response(200)
      |> get_in(["results", Access.at(3)])

    assert cancellation["refunded_cents"] == 0
    assert cancellation["retained_cents"] == 0
    assert cancellation["credit_issued_cents"] == 0

    assert json_response(get(conn, "/api/v1/guests/guest-credit/credit?on=2027-01-01"), 200)
           |> get_in(["data"]) == %{
             "guest_id" => "guest-credit",
             "available_cents" => 1_100,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-source",
                 "remaining_cents" => 1_100,
                 "expires_on" => "2028-01-02"
               }
             ]
           }

    assert json_response(get(conn, "/api/v1/ledger?on=2027-01-02"), 200)
           |> get_in(["data"]) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 1_000,
             "credit_liability_cents" => 1_100
           }

    assert json_response(get(conn, "/api/v1/guests/guest-credit/credit?on=2028-01-02"), 200)
           |> get_in(["data", "available_cents"]) == 0

    assert json_response(get(conn, "/api/v1/ledger?on=2028-01-02"), 200)
           |> get_in(["data", "credit_liability_cents"]) == 0
  end

  test "consumes credit FIFO and rejects unavailable refund methods without revision changes", %{
    conn: conn
  } do
    operations =
      Enum.flat_map(["z", "a"], fn suffix ->
        [
          open_operation("source-#{suffix}", %{"operation_id" => "open-#{suffix}"}),
          %{
            "operation_id" => "pay-#{suffix}",
            "type" => "record_cash_payment",
            "occurred_on" => "2027-01-01",
            "group_id" => "source-#{suffix}",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "cancel-#{suffix}",
            "type" => "cancel_group",
            "occurred_on" => "2027-01-01",
            "group_id" => "source-#{suffix}",
            "refund_method" => "hotel_credit"
          }
        ]
      end)

    assert Enum.all?(
             json_response(submit(conn, operations), 200)["results"],
             &(&1["status"] == "applied")
           )

    assert get_in(
             json_response(
               submit(conn, [
                 open_operation("target", %{
                   "operation_id" => "open-target",
                   "rate_plan" => "advance_purchase",
                   "rooms" => [%{"room_id" => "target-room", "nightly_rate_cents" => 1_000}]
                 }),
                 %{
                   "operation_id" => "apply-target",
                   "type" => "apply_hotel_credit",
                   "occurred_on" => "2027-01-02",
                   "group_id" => "target",
                   "amount_cents" => 150
                 },
                 %{
                   "operation_id" => "bad-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2027-01-02",
                   "group_id" => "target",
                   "refund_method" => "hotel_credit",
                   "expected_revision" => 2
                 }
               ]),
               200
             ),
             ["results", Access.at(2)]
           ) == %{
             "operation_id" => "bad-cancel",
             "status" => "rejected",
             "code" => "refund_method_not_available"
           }

    assert get(conn, "/api/v1/groups/target")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2

    assert json_response(get(conn, "/api/v1/guests/guest-credit/credit?on=2027-01-02"), 200)
           |> get_in(["data", "lots"]) == [
             %{
               "source_operation_id" => "cancel-z",
               "remaining_cents" => 70,
               "expires_on" => "2028-01-02"
             }
           ]
  end
end
