defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.{CreditLotEntitlement, Repo}

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp open_operation(group_id, guest_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-01",
        "departure_on" => "2027-03-02",
        "rate_plan" => "advance_purchase",
        "rooms" => [
          %{"room_id" => "#{group_id}-first", "nightly_rate_cents" => 100},
          %{"room_id" => "#{group_id}-second", "nightly_rate_cents" => 100}
        ]
      },
      Map.merge(overrides, %{"group_id" => group_id, "guest_id" => guest_id})
    )
  end

  defp operation(type, operation_id, attrs) do
    Map.merge(%{"operation_id" => operation_id, "type" => type}, attrs)
  end

  test "moves mixed funding in reverse source order and destination room order", %{conn: conn} do
    issuer = [
      open_operation("issuer", "guest-transfer", %{
        "operation_id" => "open-issuer",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "issuer-room", "nightly_rate_cents" => 500}]
      }),
      operation("record_cash_payment", "issuer-payment", %{
        "occurred_on" => "2027-01-01",
        "group_id" => "issuer",
        "amount_cents" => 100
      }),
      operation("cancel_group", "issuer-cancel", %{
        "occurred_on" => "2027-01-01",
        "group_id" => "issuer",
        "refund_method" => "hotel_credit"
      })
    ]

    assert Enum.all?(
             get_in(submit(conn, issuer) |> json_response(200), ["results"]),
             &(&1["status"] == "applied")
           )

    assert Enum.all?(
             submit(conn, [
               open_operation("source", "guest-transfer"),
               operation("record_cash_payment", "source-payment", %{
                 "occurred_on" => "2027-01-01",
                 "group_id" => "source",
                 "amount_cents" => 100
               }),
               operation("apply_hotel_credit", "source-credit", %{
                 "occurred_on" => "2027-01-02",
                 "group_id" => "source",
                 "amount_cents" => 100
               }),
               open_operation("destination", "guest-transfer")
             ])
             |> json_response(200)
             |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    transfer =
      operation("transfer_deposit", "transfer-1", %{
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 150,
        "expected_revision" => 3,
        "destination_expected_revision" => 1
      })

    result = submit(conn, [transfer]) |> json_response(200) |> get_in(["results", Access.at(0)])

    assert result == %{
             "operation_id" => "transfer-1",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 150,
             "source_outstanding_deposit_cents" => 150,
             "destination_outstanding_deposit_cents" => 50,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert get(conn, "/api/v1/groups/source")
           |> json_response(200)
           |> get_in(["data", "rooms"]) == [
             %{
               "room_id" => "source-first",
               "nightly_rate_cents" => 100,
               "status" => "active",
               "deposit_due_cents" => 100,
               "cash_paid_cents" => 50,
               "credit_paid_cents" => 0
             },
             %{
               "room_id" => "source-second",
               "nightly_rate_cents" => 100,
               "status" => "active",
               "deposit_due_cents" => 100,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }
           ]

    assert get(conn, "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data", "rooms"]) == [
             %{
               "room_id" => "destination-first",
               "nightly_rate_cents" => 100,
               "status" => "active",
               "deposit_due_cents" => 100,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 100
             },
             %{
               "room_id" => "destination-second",
               "nightly_rate_cents" => 100,
               "status" => "active",
               "deposit_due_cents" => 100,
               "cash_paid_cents" => 50,
               "credit_paid_cents" => 0
             }
           ]

    assert get(conn, "/api/v1/payments/source-payment")
           |> json_response(200)
           |> get_in(["data"]) == %{
             "payment_operation_id" => "source-payment",
             "original_group_id" => "source",
             "recorded_cents" => 100,
             "held_cents" => 100,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0,
             "held_by_group" => [
               %{"group_id" => "destination", "amount_cents" => 50},
               %{"group_id" => "source", "amount_cents" => 50}
             ]
           }

    assert get(conn, "/api/v1/ledger")
           |> json_response(200)
           |> get_in(["data"]) == %{
             "cash_held_cents" => 100,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0,
             "cash_converted_to_credit_cents" => 100,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0,
             "credit_liability_cents" => 110,
             "credit_shortfall_cents" => 0
           }

    assert submit(conn, [transfer]) |> json_response(200) == %{"results" => [result]}
  end

  test "reductions and chargebacks follow transferred cash across groups", %{conn: conn} do
    assert Enum.all?(
             submit(conn, [
               open_operation("source", "guest-revisions", %{
                 "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 100}]
               }),
               operation("record_cash_payment", "payment", %{
                 "occurred_on" => "2027-01-01",
                 "group_id" => "source",
                 "amount_cents" => 100
               }),
               open_operation("destination", "guest-revisions", %{
                 "rooms" => [%{"room_id" => "destination-room", "nightly_rate_cents" => 100}]
               }),
               operation("transfer_deposit", "transfer", %{
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 100,
                 "expected_revision" => 2,
                 "destination_expected_revision" => 1
               })
             ])
             |> json_response(200)
             |> get_in(["results"]),
             &(&1["status"] == "applied")
           )

    reduction =
      operation("reduce_cash_payment", "reduction", %{
        "payment_operation_id" => "payment",
        "amount_cents" => 40,
        "expected_revision" => 3
      })

    assert get_in(submit(conn, [reduction]) |> json_response(200), ["results", Access.at(0)]) ==
             %{
               "operation_id" => "reduction",
               "status" => "applied",
               "payment_operation_id" => "payment",
               "group_id" => "source",
               "amount_cents" => 40,
               "outstanding_deposit_cents" => 100,
               "revision" => 4
             }

    assert get(conn, "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 3

    chargeback =
      operation("charge_back_payment", "chargeback", %{
        "payment_operation_id" => "payment",
        "expected_revision" => 4
      })

    assert get_in(submit(conn, [chargeback]) |> json_response(200), ["results", Access.at(0)]) ==
             %{
               "operation_id" => "chargeback",
               "status" => "applied",
               "payment_operation_id" => "payment",
               "group_id" => "source",
               "charged_back_cents" => 60,
               "outstanding_deposit_cents" => 100,
               "revision" => 5
             }

    assert get(conn, "/api/v1/payments/payment")
           |> json_response(200)
           |> get_in(["data", "held_by_group"]) == []

    assert get(conn, "/api/v1/groups/destination")
           |> json_response(200)
           |> get_in(["data", "revision"]) == 4
  end

  test "resolves both groups and revisions before transfer validation", %{conn: conn} do
    assert submit(conn, [
             open_operation("source", "guest-errors", %{
               "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 100}]
             }),
             open_operation("other", "other-guest", %{
               "rooms" => [%{"room_id" => "other-room", "nightly_rate_cents" => 100}]
             })
           ])
           |> json_response(200)

    missing_destination =
      operation("transfer_deposit", "missing-destination", %{
        "source_group_id" => "source",
        "destination_group_id" => "missing",
        "amount_cents" => 1,
        "expected_revision" => 0
      })

    assert get_in(submit(conn, [missing_destination]) |> json_response(200), [
             "results",
             Access.at(0)
           ]) == %{
             "operation_id" => "missing-destination",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "missing"
           }

    stale_destination =
      operation("transfer_deposit", "stale-destination", %{
        "source_group_id" => "source",
        "destination_group_id" => "other",
        "amount_cents" => 0,
        "expected_revision" => 1,
        "destination_expected_revision" => 0
      })

    assert get_in(submit(conn, [stale_destination]) |> json_response(200), [
             "results",
             Access.at(0)
           ]) == %{
             "operation_id" => "stale-destination",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "other",
             "expected_revision" => 0,
             "actual_revision" => 1
           }

    invalid_guest =
      operation("transfer_deposit", "invalid-guest", %{
        "source_group_id" => "source",
        "destination_group_id" => "other",
        "amount_cents" => 1
      })

    assert get_in(submit(conn, [invalid_guest]) |> json_response(200), ["results", Access.at(0)]) ==
             %{
               "operation_id" => "invalid-guest",
               "status" => "rejected",
               "code" => "invalid_transfer"
             }
  end

  test "restores transferred credit to its original lot without a bonus", %{conn: conn} do
    operations = [
      open_operation("issuer", "guest-credit-transfer", %{
        "operation_id" => "open-issuer",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "issuer-room", "nightly_rate_cents" => 500}]
      }),
      operation("record_cash_payment", "issuer-payment", %{
        "occurred_on" => "2027-01-01",
        "group_id" => "issuer",
        "amount_cents" => 100
      }),
      operation("cancel_group", "issuer-cancel", %{
        "occurred_on" => "2027-01-01",
        "group_id" => "issuer",
        "refund_method" => "hotel_credit"
      }),
      open_operation("source", "guest-credit-transfer", %{
        "operation_id" => "open-source",
        "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 100}]
      }),
      operation("apply_hotel_credit", "source-credit", %{
        "occurred_on" => "2027-01-02",
        "group_id" => "source",
        "amount_cents" => 100
      }),
      open_operation("destination", "guest-credit-transfer", %{
        "operation_id" => "open-destination",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "destination-room", "nightly_rate_cents" => 500}]
      }),
      operation("transfer_deposit", "credit-transfer", %{
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 100,
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      }),
      operation("cancel_group", "destination-cancel", %{
        "occurred_on" => "2027-01-02",
        "group_id" => "destination"
      })
    ]

    assert Enum.all?(
             get_in(submit(conn, operations) |> json_response(200), ["results"]),
             &(&1["status"] == "applied")
           )

    assert get(conn, "/api/v1/guests/guest-credit-transfer/credit?on=2027-01-02")
           |> json_response(200)
           |> get_in(["data", "available_cents"]) == 110
  end

  test "uses transfer draw order when assigning credit entitlements", %{conn: conn} do
    operations = [
      open_operation("source", "guest-entitlements", %{
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 500}]
      }),
      operation("record_cash_payment", "payment-a", %{
        "occurred_on" => "2027-01-01",
        "group_id" => "source",
        "amount_cents" => 5
      }),
      operation("record_cash_payment", "payment-b", %{
        "occurred_on" => "2027-01-01",
        "group_id" => "source",
        "amount_cents" => 5
      }),
      open_operation("destination", "guest-entitlements", %{
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "destination-room", "nightly_rate_cents" => 500}]
      }),
      operation("transfer_deposit", "entitlement-transfer", %{
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 10,
        "expected_revision" => 3,
        "destination_expected_revision" => 1
      }),
      operation("cancel_group", "destination-cancel", %{
        "occurred_on" => "2027-01-01",
        "group_id" => "destination",
        "refund_method" => "hotel_credit"
      })
    ]

    assert Enum.all?(
             get_in(submit(conn, operations) |> json_response(200), ["results"]),
             &(&1["status"] == "applied")
           )

    assert Repo.all(
             from entitlement in CreditLotEntitlement,
               select: {entitlement.payment_operation_id, entitlement.amount_cents}
           )
           |> Map.new() == %{"payment-a" => 5, "payment-b" => 6}
  end
end
