defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashAllocation,
    CreditLot,
    Group,
    RoomCreditAllocation
  }

  defp open_operation(group_id) do
    open_operation(
      group_id,
      [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => 1_000}],
      %{}
    )
  end

  defp open_operation(group_id, rooms) do
    open_operation(group_id, rooms, %{})
  end

  defp open_operation(group_id, rooms, overrides) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-01-01",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-03-01",
        "departure_on" => "2026-03-02",
        "rate_plan" => "flexible",
        "rooms" => rooms
      },
      overrides
    )
  end

  defp cash_payment(operation_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-01-02",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp transfer(
         operation_id,
         source_group_id,
         destination_group_id,
         amount_cents,
         overrides \\ %{}
       ) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "transfer_deposit",
        "source_group_id" => source_group_id,
        "destination_group_id" => destination_group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  test "moves mixed funding newest first while retaining cash and credit provenance", %{
    conn: conn
  } do
    response =
      submit(conn, [
        open_operation("credit-issuer"),
        cash_payment("issuer-cash", "credit-issuer", 200),
        %{
          "operation_id" => "issue-credit",
          "type" => "cancel_group",
          "occurred_on" => "2026-01-03",
          "group_id" => "credit-issuer",
          "refund_method" => "hotel_credit"
        },
        open_operation("source", [
          %{"room_id" => "source-one", "nightly_rate_cents" => 1_000},
          %{"room_id" => "source-two", "nightly_rate_cents" => 1_000}
        ]),
        cash_payment("source-cash", "source", 200),
        %{
          "operation_id" => "source-credit",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-01-04",
          "group_id" => "source",
          "amount_cents" => 200
        },
        open_operation("destination", [
          %{"room_id" => "destination-one", "nightly_rate_cents" => 1_000},
          %{"room_id" => "destination-two", "nightly_rate_cents" => 1_000}
        ]),
        transfer("mixed-transfer", "source", "destination", 300)
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 7) == %{
             "operation_id" => "mixed-transfer",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 300,
             "source_outstanding_deposit_cents" => 300,
             "destination_outstanding_deposit_cents" => 100,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert get(build_conn(), "/api/v1/groups/source")
           |> json_response(200)
           |> get_in(["data", "rooms"]) == [
             %{
               "room_id" => "source-one",
               "nightly_rate_cents" => 1_000,
               "status" => "active",
               "lodging_total_cents" => 1_000,
               "deposit_due_cents" => 200,
               "cash_paid_cents" => 100,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "source-two",
               "nightly_rate_cents" => 1_000,
               "status" => "active",
               "lodging_total_cents" => 1_000,
               "deposit_due_cents" => 200,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }
           ]

    assert get(build_conn(), "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data", "rooms"]) == [
             %{
               "room_id" => "destination-one",
               "nightly_rate_cents" => 1_000,
               "status" => "active",
               "lodging_total_cents" => 1_000,
               "deposit_due_cents" => 200,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 200
             },
             %{
               "room_id" => "destination-two",
               "nightly_rate_cents" => 1_000,
               "status" => "active",
               "lodging_total_cents" => 1_000,
               "deposit_due_cents" => 200,
               "cash_paid_cents" => 100,
               "credit_paid_cents" => 0
             }
           ]

    source = Repo.get_by!(Group, group_id: "source")
    destination = Repo.get_by!(Group, group_id: "destination")

    assert Repo.all(
             from allocation in CashAllocation,
               where: allocation.payment_operation_id == "source-cash",
               order_by: allocation.group_db_id,
               select: {allocation.group_db_id, allocation.amount_cents}
           ) == Enum.sort([{destination.id, 100}, {source.id, 100}])

    credit_lot = Repo.get_by!(CreditLot, source_operation_id: "issue-credit")

    assert Repo.all(
             from allocation in RoomCreditAllocation,
               where: allocation.group_db_id == ^destination.id,
               select: allocation.credit_lot_id
           ) == [credit_lot.id]

    assert get(build_conn(), "/api/v1/payments/source-cash") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "source-cash",
               "original_group_id" => "source",
               "recorded_cents" => 200,
               "held_cents" => 200,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "destination", "amount_cents" => 100},
                 %{"group_id" => "source", "amount_cents" => 100}
               ]
             }
           }

    assert get(build_conn(), "/api/v1/ledger") |> json_response(200) |> get_in(["data"]) == %{
             "cash_held_cents" => 200,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 200,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 220,
             "credit_shortfall_cents" => 0
           }
  end

  test "reductions and chargebacks follow transferred cash and revise every changed group", %{
    conn: conn
  } do
    response =
      submit(conn, [
        open_operation("source"),
        cash_payment("source-cash", "source", 200),
        open_operation("destination"),
        transfer("move-all-cash", "source", "destination", 200),
        %{
          "operation_id" => "reduce-transferred-cash",
          "type" => "reduce_cash_payment",
          "payment_operation_id" => "source-cash",
          "amount_cents" => 100,
          "expected_revision" => 3
        },
        %{
          "operation_id" => "chargeback-transferred-cash",
          "type" => "charge_back_payment",
          "payment_operation_id" => "source-cash",
          "expected_revision" => 4
        }
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 4) == %{
             "operation_id" => "reduce-transferred-cash",
             "status" => "applied",
             "payment_operation_id" => "source-cash",
             "group_id" => "source",
             "amount_cents" => 100,
             "outstanding_deposit_cents" => 200,
             "revision" => 4
           }

    assert Enum.at(response["results"], 5) == %{
             "operation_id" => "chargeback-transferred-cash",
             "status" => "applied",
             "payment_operation_id" => "source-cash",
             "group_id" => "source",
             "charged_back_cents" => 100,
             "outstanding_deposit_cents" => 200,
             "revision" => 5
           }

    assert get(build_conn(), "/api/v1/groups/source")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 5

    assert get(build_conn(), "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 4

    assert get(build_conn(), "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data", "outstanding_deposit_cents"]) == 200

    assert get(build_conn(), "/api/v1/payments/source-cash") |> json_response(200) == %{
             "data" => %{
               "payment_operation_id" => "source-cash",
               "original_group_id" => "source",
               "recorded_cents" => 200,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 100,
               "charged_back_cents" => 100,
               "held_by_group" => []
             }
           }

    assert get(build_conn(), "/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data", "cash_reduced_cents"]) == 100

    assert get(build_conn(), "/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data", "cash_charged_back_cents"]) == 100
  end

  test "replays transfers exactly and makes both revisions visible to later batch operations", %{
    conn: conn
  } do
    transfer_operation =
      transfer("durable-transfer", "source", "destination", 50, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    response =
      submit(conn, [
        open_operation("source"),
        cash_payment("source-cash", "source", 200),
        open_operation("destination"),
        transfer_operation,
        cash_payment("destination-cash", "destination", 50, %{"expected_revision" => 2})
      ])
      |> json_response(200)

    transfer_result = Enum.at(response["results"], 3)

    assert transfer_result == %{
             "operation_id" => "durable-transfer",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 50,
             "source_outstanding_deposit_cents" => 50,
             "destination_outstanding_deposit_cents" => 150,
             "source_revision" => 3,
             "destination_revision" => 2
           }

    assert Enum.at(response["results"], 4)["status"] == "applied"

    assert submit(build_conn(), [transfer_operation]) |> json_response(200) == %{
             "results" => [transfer_result]
           }

    assert submit(build_conn(), [Map.put(transfer_operation, "amount_cents", 40)])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "durable-transfer",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
           }

    assert get(build_conn(), "/api/v1/groups/source")
           |> json_response(200)
           |> get_in(["data", "deposit_paid_cents"]) == 150

    assert get(build_conn(), "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data", "deposit_paid_cents"]) == 100
  end

  test "settles transferred cash under the destination policy and restores transferred credit", %{
    conn: conn
  } do
    submit(conn, [
      open_operation("cash-source"),
      cash_payment("cash-source-payment", "cash-source", 200),
      open_operation(
        "cash-destination",
        [%{"room_id" => "cash-destination-room", "nightly_rate_cents" => 1_000}],
        %{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02"
        }
      ),
      transfer("cash-transfer", "cash-source", "cash-destination", 200),
      %{
        "operation_id" => "cash-destination-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-15",
        "group_id" => "cash-destination",
        "refund_method" => "hotel_credit"
      },
      open_operation("credit-issuer"),
      cash_payment("credit-issuer-payment", "credit-issuer", 200),
      %{
        "operation_id" => "credit-issuer-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-03",
        "group_id" => "credit-issuer",
        "refund_method" => "hotel_credit"
      },
      open_operation("credit-source"),
      %{
        "operation_id" => "apply-credit-to-source",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-01-04",
        "group_id" => "credit-source",
        "amount_cents" => 200
      },
      open_operation("credit-destination"),
      transfer("credit-transfer", "credit-source", "credit-destination", 200),
      %{
        "operation_id" => "credit-destination-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-05",
        "group_id" => "credit-destination"
      }
    ])
    |> json_response(200)

    assert get(build_conn(), "/api/v1/payments/cash-source-payment")
           |> json_response(200)
           |> get_in(["data"]) == %{
             "payment_operation_id" => "cash-source-payment",
             "original_group_id" => "cash-source",
             "recorded_cents" => 200,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 200,
             "reduced_cents" => 0,
             "charged_back_cents" => 0,
             "held_by_group" => []
           }

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2026-01-05")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 440

    assert submit(build_conn(), [
             %{
               "operation_id" => "chargeback-settled-transfer",
               "type" => "charge_back_payment",
               "payment_operation_id" => "cash-source-payment",
               "expected_revision" => 3
             }
           ])
           |> json_response(200)
           |> get_in(["results", Access.at(0)]) == %{
             "operation_id" => "chargeback-settled-transfer",
             "status" => "applied",
             "payment_operation_id" => "cash-source-payment",
             "group_id" => "cash-source",
             "charged_back_cents" => 200,
             "outstanding_deposit_cents" => 200,
             "revision" => 4
           }

    assert get(build_conn(), "/api/v1/groups/cash-destination")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 4

    assert get(build_conn(), "/api/v1/payments/cash-source-payment")
           |> json_response(200)
           |> get_in(["data", "charged_back_cents"]) == 200

    assert get(build_conn(), "/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data", "cash_converted_to_credit_cents"]) == 200

    assert get(build_conn(), "/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data", "cash_charged_back_cents"]) == 200
  end

  test "validates transfer groups and revision guards in the documented order", %{conn: conn} do
    response =
      submit(conn, [
        open_operation("source"),
        cash_payment("source-cash", "source", 100),
        open_operation("destination"),
        open_operation("other", [%{"room_id" => "other-room", "nightly_rate_cents" => 1_000}], %{
          "guest_id" => "another-guest"
        }),
        transfer("same-group", "source", "source", 1),
        transfer("different-guest", "source", "other", 1),
        transfer("missing-source", "missing", "destination", 1),
        transfer("missing-destination", "source", "missing", 1),
        transfer("stale-source", "source", "destination", 1, %{
          "expected_revision" => 1,
          "destination_expected_revision" => 0
        }),
        transfer("stale-destination", "source", "destination", 1, %{
          "expected_revision" => 2,
          "destination_expected_revision" => 0
        }),
        transfer("invalid-amount", "source", "destination", 0),
        transfer("exceeds-held", "source", "destination", 101),
        cash_payment("destination-cash", "destination", 200),
        transfer("exceeds-outstanding", "source", "destination", 100),
        open_operation("inactive-source"),
        %{
          "operation_id" => "cancel-inactive-source",
          "type" => "cancel_group",
          "occurred_on" => "2026-01-03",
          "group_id" => "inactive-source"
        },
        transfer("inactive-source-transfer", "inactive-source", "source", 1),
        open_operation("inactive-destination"),
        %{
          "operation_id" => "cancel-inactive-destination",
          "type" => "cancel_group",
          "occurred_on" => "2026-01-03",
          "group_id" => "inactive-destination"
        },
        transfer("inactive-destination-transfer", "source", "inactive-destination", 1)
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 4)["code"] == "invalid_transfer"
    assert Enum.at(response["results"], 5)["code"] == "invalid_transfer"

    assert Enum.at(response["results"], 6) == %{
             "operation_id" => "missing-source",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "missing"
           }

    assert Enum.at(response["results"], 7) == %{
             "operation_id" => "missing-destination",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "missing"
           }

    assert Enum.at(response["results"], 8) == %{
             "operation_id" => "stale-source",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "source",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    assert Enum.at(response["results"], 9) == %{
             "operation_id" => "stale-destination",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "destination",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    assert Enum.map(response["results"], &Map.get(&1, "code")) |> Enum.slice(10, 3) == [
             "invalid_amount",
             "transfer_exceeds_held_funding",
             nil
           ]

    assert Enum.at(response["results"], 13)["code"] == "transfer_exceeds_outstanding"

    assert submit(build_conn(), [transfer("exceeds-held", "source", "destination", 101)])
           |> json_response(200) == %{"results" => [Enum.at(response["results"], 11)]}

    assert Enum.at(response["results"], 16) == %{
             "operation_id" => "inactive-source-transfer",
             "status" => "rejected",
             "code" => "group_not_active",
             "group_id" => "inactive-source"
           }

    assert Enum.at(response["results"], 19) == %{
             "operation_id" => "inactive-destination-transfer",
             "status" => "rejected",
             "code" => "group_not_active",
             "group_id" => "inactive-destination"
           }
  end
end
