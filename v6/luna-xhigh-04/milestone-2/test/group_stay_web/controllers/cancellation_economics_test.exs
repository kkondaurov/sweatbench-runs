defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp open_operation(operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        operation_id: operation_id,
        type: "open_group",
        occurred_on: "2026-10-03",
        group_id: "group-81",
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: "2027-03-20",
        departure_on: "2027-03-22",
        rate_plan: "flexible",
        rooms: [%{room_id: "room-a", nightly_rate_cents: 10000}]
      },
      overrides
    )
  end

  test "fixes the policy at booking and recomputes the date after a move", %{conn: conn} do
    response =
      post_batch(conn, [
        open_operation("op-old", %{group_id: "old", occurred_on: "2026-12-31"}),
        open_operation("op-new", %{group_id: "new", occurred_on: "2027-01-01"}),
        open_operation("op-advance", %{
          group_id: "advance",
          occurred_on: "2027-01-01",
          rate_plan: "advance_purchase"
        })
      ])

    assert json_response(response, 200)["results"]
           |> Enum.map(&Map.take(&1, ["status", "revision"])) ==
             [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 1}
             ]

    assert get(build_conn(), "/api/v1/groups/old")
           |> json_response(200)
           |> get_in(["data"])
           |> Map.take([
             "policy_version",
             "refundable_until"
           ]) == %{"policy_version" => "flex-14", "refundable_until" => "2027-03-06"}

    assert get(build_conn(), "/api/v1/groups/new")
           |> json_response(200)
           |> get_in(["data"])
           |> Map.take([
             "policy_version",
             "refundable_until"
           ]) == %{"policy_version" => "flex-30", "refundable_until" => "2027-02-18"}

    assert get(build_conn(), "/api/v1/groups/advance")
           |> json_response(200)
           |> get_in(["data"])
           |> Map.take(["policy_version", "refundable_until"]) ==
             %{"policy_version" => "advance-nonrefundable", "refundable_until" => nil}

    moved =
      post_batch(conn, [
        %{
          operation_id: "op-move",
          type: "reschedule_group",
          occurred_on: "2027-01-02",
          group_id: "new",
          new_arrival_on: "2027-03-25"
        }
      ])

    assert json_response(moved, 200)["results"] == [
             %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "new",
               "new_arrival_on" => "2027-03-25",
               "new_departure_on" => "2027-03-27",
               "policy_version" => "flex-30",
               "refundable_until" => "2027-02-23",
               "revision" => 2
             }
           ]
  end

  test "converts refundable cash to expiring credit and reports liability", %{conn: conn} do
    open = open_operation("op-open", %{arrival_on: "2026-12-20", departure_on: "2026-12-22"})

    response =
      post_batch(conn, [
        open,
        %{
          operation_id: "op-payment",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          amount_cents: 1001
        },
        %{
          operation_id: "op-cancel",
          type: "cancel_group",
          occurred_on: "2026-10-01",
          group_id: "group-81",
          refund_method: "hotel_credit"
        }
      ])

    assert List.last(json_response(response, 200)["results"]) == %{
             "operation_id" => "op-cancel",
             "status" => "applied",
             "group_id" => "group-81",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 1101,
             "revision" => 3
           }

    credit = get(build_conn(), "/api/v1/guests/guest-22/credit?on=2026-10-01")

    assert json_response(credit, 200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 1101,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel",
                   "remaining_cents" => 1101,
                   "expires_on" => "2027-10-02"
                 }
               ]
             }
           }

    ledger = get(build_conn(), "/api/v1/ledger?on=2026-10-01")

    assert json_response(ledger, 200)["data"] == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 1001,
             "credit_liability_cents" => 1101
           }

    assert get(build_conn(), "/api/v1/ledger?on=2027-10-02")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 0
  end

  test "applies credit in lot order and restores it on refundable cancellation", %{conn: conn} do
    issue_credit = fn operation_id, group_id, cancellation_on ->
      post_batch(conn, [
        open_operation("open-#{operation_id}", %{
          group_id: group_id,
          arrival_on: "2027-03-20",
          departure_on: "2027-03-22"
        }),
        %{
          operation_id: "pay-#{operation_id}",
          type: "record_cash_payment",
          occurred_on: "2026-10-04",
          group_id: group_id,
          amount_cents: 1000
        },
        %{
          operation_id: operation_id,
          type: "cancel_group",
          occurred_on: cancellation_on,
          group_id: group_id,
          refund_method: "hotel_credit"
        }
      ])
    end

    assert issue_credit.("cancel-early", "credit-source-1", "2026-10-01") |> json_response(200)
    assert issue_credit.("cancel-late", "credit-source-2", "2026-11-01") |> json_response(200)

    open =
      open_operation("open-use", %{
        group_id: "credit-use",
        arrival_on: "2027-04-20",
        departure_on: "2027-04-22"
      })

    applied =
      post_batch(conn, [
        open,
        %{
          operation_id: "apply-credit",
          type: "apply_hotel_credit",
          occurred_on: "2026-12-01",
          group_id: "credit-use",
          amount_cents: 1500
        }
      ])

    assert List.last(json_response(applied, 200)["results"]) == %{
             "operation_id" => "apply-credit",
             "status" => "applied",
             "group_id" => "credit-use",
             "amount_cents" => 1500,
             "outstanding_deposit_cents" => 2500,
             "revision" => 2
           }

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2026-12-01")
           |> json_response(200)
           |> get_in(["data", "lots"]) == [
             %{
               "source_operation_id" => "cancel-late",
               "remaining_cents" => 700,
               "expires_on" => "2027-11-02"
             }
           ]

    assert get(build_conn(), "/api/v1/ledger?on=2026-12-01")
           |> json_response(200)
           |> get_in(["data", "credit_liability_cents"]) == 2200

    cancelled =
      post_batch(conn, [
        %{
          operation_id: "cancel-use",
          type: "cancel_group",
          occurred_on: "2027-01-01",
          group_id: "credit-use"
        }
      ])

    assert List.last(json_response(cancelled, 200)["results"]) == %{
             "operation_id" => "cancel-use",
             "status" => "applied",
             "group_id" => "credit-use",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-01-01")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 2200
  end

  test "rejects hotel credit for non-refundable cancellations and consumes credit otherwise", %{
    conn: conn
  } do
    assert post_batch(conn, [
             open_operation("op-source", %{arrival_on: "2026-12-20", departure_on: "2026-12-22"}),
             %{
               operation_id: "op-source-payment",
               type: "record_cash_payment",
               occurred_on: "2026-10-04",
               group_id: "group-81",
               amount_cents: 1000
             },
             %{
               operation_id: "op-source-cancel",
               type: "cancel_group",
               occurred_on: "2026-10-01",
               group_id: "group-81",
               refund_method: "hotel_credit"
             }
           ])
           |> json_response(200)

    response =
      post_batch(conn, [
        open_operation("op-use", %{
          group_id: "group-use",
          occurred_on: "2027-01-01",
          arrival_on: "2027-03-20",
          departure_on: "2027-03-22"
        }),
        %{
          operation_id: "op-apply",
          type: "apply_hotel_credit",
          occurred_on: "2027-01-02",
          group_id: "group-use",
          amount_cents: 500
        },
        %{
          operation_id: "op-not-available",
          type: "cancel_group",
          occurred_on: "2027-02-19",
          group_id: "group-use",
          refund_method: "hotel_credit"
        },
        %{
          operation_id: "op-cancel",
          type: "cancel_group",
          occurred_on: "2027-02-19",
          group_id: "group-use"
        }
      ])

    assert Enum.at(json_response(response, 200)["results"], 2) == %{
             "operation_id" => "op-not-available",
             "status" => "rejected",
             "code" => "refund_method_not_available",
             "group_id" => "group-use"
           }

    assert List.last(json_response(response, 200)["results"]) == %{
             "operation_id" => "op-cancel",
             "status" => "applied",
             "group_id" => "group-use",
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "credit_issued_cents" => 0,
             "revision" => 3
           }

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2027-02-19")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 600

    assert get(build_conn(), "/api/v1/groups/group-use")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 3
  end

  test "rejected credit attempts preserve the revision and stale checks run first", %{conn: conn} do
    assert post_batch(conn, [open_operation("op-open")]) |> json_response(200)

    response =
      post_batch(conn, [
        %{
          operation_id: "op-stale",
          type: "apply_hotel_credit",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          expected_revision: 0,
          amount_cents: -1
        },
        %{
          operation_id: "op-insufficient",
          type: "apply_hotel_credit",
          occurred_on: "2026-10-04",
          group_id: "group-81",
          expected_revision: 1,
          amount_cents: 1
        }
      ])

    assert json_response(response, 200)["results"] == [
             %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 0,
               "actual_revision" => 1
             },
             %{
               "operation_id" => "op-insufficient",
               "status" => "rejected",
               "code" => "insufficient_credit",
               "group_id" => "group-81"
             }
           ]

    assert get(build_conn(), "/api/v1/groups/group-81")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 1
  end
end
